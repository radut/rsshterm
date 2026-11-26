// The C layer between libfreerdp3 and Swift (rssh_rdp.h). One thread runs a session: rssh_rdp_run connects and
// pumps FreeRDP's event handles; input and clipboard offers from other threads are queued and sent from it.
// Proven first in RSSHRemoteDesktop/spikes/freerdp-grab.
#include "rssh_rdp.h"
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/event.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>
#include <freerdp/error.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define QUEUE_CAP 2048

typedef enum { EV_MOUSE, EV_SCANCODE, EV_UNICODE, EV_OFFER_TEXT } event_kind;

typedef struct {
    event_kind kind;
    uint16_t a, b, c;
} queued_event;

struct rssh_rdp {
    freerdp *instance;
    rssh_rdp_callbacks cb;
    char *host, *username, *domain, *password;
    uint16_t port;
    uint32_t width, height;
    int clipboard;

    HANDLE wake;
    pthread_mutex_t queue_lock;
    queued_event queue[QUEUE_CAP];
    size_t queue_len;
    char *local_text;   // under queue_lock

    pthread_mutex_t frame_lock;
    volatile int stop;
    int reported_connected;
    CliprdrClientContext *cliprdr;
};

typedef struct {
    rdpContext base;
    rssh_rdp *owner;
} rssh_context;

static rssh_rdp *owner_of(rdpContext *context) { return ((rssh_context *)context)->owner; }

static char *dup_or_null(const char *s) { return s ? strdup(s) : NULL; }

static void wipe_free(char *s) {
    if (!s) return;
    memset(s, 0, strlen(s));
    free(s);
}

// MARK: queue

static void enqueue(rssh_rdp *rdp, queued_event ev) {
    pthread_mutex_lock(&rdp->queue_lock);
    if (rdp->queue_len < QUEUE_CAP) rdp->queue[rdp->queue_len++] = ev;
    pthread_mutex_unlock(&rdp->queue_lock);
    SetEvent(rdp->wake);
}

static void send_format_list(rssh_rdp *rdp);

static void drain(rssh_rdp *rdp) {
    queued_event local[QUEUE_CAP];
    size_t n;
    pthread_mutex_lock(&rdp->queue_lock);
    n = rdp->queue_len;
    memcpy(local, rdp->queue, n * sizeof(queued_event));
    rdp->queue_len = 0;
    ResetEvent(rdp->wake);
    pthread_mutex_unlock(&rdp->queue_lock);

    rdpInput *input = rdp->instance->context->input;
    for (size_t i = 0; i < n; i++) {
        queued_event ev = local[i];
        switch (ev.kind) {
        case EV_MOUSE:
            (void)freerdp_input_send_mouse_event(input, ev.a, ev.b, ev.c);
            break;
        case EV_SCANCODE: {
            UINT16 flags = (ev.c ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE) | (ev.b ? KBD_FLAGS_EXTENDED : 0);
            (void)freerdp_input_send_keyboard_event(input, flags, (UINT8)ev.a);
            break;
        }
        case EV_UNICODE:
            (void)freerdp_input_send_unicode_keyboard_event(input, ev.c ? 0 : KBD_FLAGS_RELEASE, ev.a);
            break;
        case EV_OFFER_TEXT:
            send_format_list(rdp);
            break;
        }
    }
}

// MARK: clipboard (text only, CF_UNICODETEXT)

static void send_format_list(rssh_rdp *rdp) {
    if (!rdp->cliprdr) return;
    pthread_mutex_lock(&rdp->queue_lock);
    int has_text = rdp->local_text != NULL;
    pthread_mutex_unlock(&rdp->queue_lock);
    CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT, .formatName = NULL };
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.numFormats = has_text ? 1 : 0;
    list.formats = has_text ? &format : NULL;
    (void)rdp->cliprdr->ClientFormatList(rdp->cliprdr, &list);
}

static UINT on_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    rssh_rdp *rdp = cliprdr->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
    if (rc != CHANNEL_RC_OK) return rc;
    send_format_list(rdp);
    return CHANNEL_RC_OK;
}

static UINT on_server_capabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *caps) {
    (void)cliprdr; (void)caps;
    return CHANNEL_RC_OK;
}

static UINT on_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    if (rc != CHANNEL_RC_OK) return rc;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.requestedFormatId = CF_UNICODETEXT;
            return cliprdr->ClientFormatDataRequest(cliprdr, &request);
        }
    }
    return CHANNEL_RC_OK;
}

static UINT on_server_format_list_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *r) {
    (void)cliprdr; (void)r;
    return CHANNEL_RC_OK;
}

static UINT on_server_format_data_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *r) {
    rssh_rdp *rdp = cliprdr->custom;
    if (!(r->common.msgFlags & CB_RESPONSE_OK) || !r->requestedFormatData || r->common.dataLen < 2) {
        return CHANNEL_RC_OK;
    }
    size_t utf8_len = 0;
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)r->requestedFormatData, r->common.dataLen / 2, &utf8_len);
    if (utf8) {
        if (rdp->cb.remote_text) rdp->cb.remote_text(rdp->cb.ctx, utf8);
        free(utf8);
    }
    return CHANNEL_RC_OK;
}

static UINT on_server_format_data_request(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *r) {
    rssh_rdp *rdp = cliprdr->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    WCHAR *wide = NULL;
    size_t wide_len = 0;
    pthread_mutex_lock(&rdp->queue_lock);
    if (r->requestedFormatId == CF_UNICODETEXT && rdp->local_text) {
        wide = ConvertUtf8ToWCharAlloc(rdp->local_text, &wide_len);
    }
    pthread_mutex_unlock(&rdp->queue_lock);
    if (wide) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)((wide_len + 1) * sizeof(WCHAR));   // with the terminating NUL
        response.requestedFormatData = (const BYTE *)wide;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(wide);
    return rc;
}

/// Takes over the cliprdr channel: from its ChannelConnected event, or (when that came first) looked up in
/// PostConnect. The server's MonitorReady then starts the exchange.
static void attach_cliprdr(rssh_rdp *rdp, rdpContext *context, CliprdrClientContext *cliprdr) {
    if (!cliprdr) {
        cliprdr = (CliprdrClientContext *)freerdp_channels_get_static_channel_interface(context->channels,
                                                                                        CLIPRDR_SVC_CHANNEL_NAME);
    }
    if (!cliprdr) return;
    cliprdr->custom = rdp;
    cliprdr->MonitorReady = on_monitor_ready;
    cliprdr->ServerCapabilities = on_server_capabilities;
    cliprdr->ServerFormatList = on_server_format_list;
    cliprdr->ServerFormatListResponse = on_server_format_list_response;
    cliprdr->ServerFormatDataRequest = on_server_format_data_request;
    cliprdr->ServerFormatDataResponse = on_server_format_data_response;
    rdp->cliprdr = cliprdr;
}

// MARK: FreeRDP callbacks

static BOOL begin_paint(rdpContext *context) {
    rssh_rdp *rdp = owner_of(context);
    pthread_mutex_lock(&rdp->frame_lock);
    rdpGdi *gdi = context->gdi;
    gdi->primary->hdc->hwnd->invalid->null = TRUE;
    gdi->primary->hdc->hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    rssh_rdp *rdp = owner_of(context);
    rdpGdi *gdi = context->gdi;
    HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
    int has = !invalid->null;
    INT32 x = invalid->x, y = invalid->y, w = invalid->w, h = invalid->h;
    UINT32 width = gdi->width, height = gdi->height;
    pthread_mutex_unlock(&rdp->frame_lock);
    if (!rdp->reported_connected) {
        rdp->reported_connected = 1;
        if (rdp->cb.connected) rdp->cb.connected(rdp->cb.ctx, width, height);
    }
    if (has && rdp->cb.frame) rdp->cb.frame(rdp->cb.ctx, x, y, w, h);
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    rssh_rdp *rdp = owner_of(context);
    rdpSettings *s = context->settings;
    pthread_mutex_lock(&rdp->frame_lock);
    BOOL ok = gdi_resize(context->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                         freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));
    pthread_mutex_unlock(&rdp->frame_lock);
    rdp->reported_connected = 0;   // the next paint reports the new size
    return ok;
}

static void on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rssh_rdp *rdp = owner_of((rdpContext *)context);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) != 0 || rdp->cliprdr) return;
    attach_cliprdr(rdp, (rdpContext *)context, (CliprdrClientContext *)e->pInterface);
}

static void on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rssh_rdp *rdp = owner_of((rdpContext *)context);
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) rdp->cliprdr = NULL;
}

static BOOL pre_connect(freerdp *instance) {
    rssh_rdp *rdp = owner_of(instance->context);
    if (rdp->clipboard) {
        PubSub_SubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
    }
    return TRUE;
}

// FreeRDP 3 asks for the channel configuration here (also again after a redirection). The channels are built into
// libfreerdp-client3: register that provider first, as the FreeRDP clients do, or cliprdr fails to load.
static BOOL load_channels(freerdp *instance) {
    rssh_rdp *rdp = owner_of(instance->context);
    if (!rdp->clipboard) return TRUE;
    if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) != CHANNEL_RC_OK) return FALSE;
    return freerdp_client_load_addins(instance->context->channels, instance->context->settings);
}

static BOOL post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    rssh_rdp *rdp = owner_of(instance->context);
    if (rdp->clipboard && !rdp->cliprdr) attach_cliprdr(rdp, instance->context, NULL);
    instance->context->update->BeginPaint = begin_paint;
    instance->context->update->EndPaint = end_paint;
    instance->context->update->DesktopResize = desktop_resize;
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    rssh_rdp *rdp = owner_of(instance->context);
    pthread_mutex_lock(&rdp->frame_lock);
    gdi_free(instance);
    pthread_mutex_unlock(&rdp->frame_lock);
}

// The vault pins the certificate (RDPCertificatePolicy); FreeRDP's own known_hosts file is never written (2 =
// accept for this session only).
static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    (void)host; (void)port; (void)common_name; (void)flags;
    rssh_rdp *rdp = owner_of(instance->context);
    if (!rdp->cb.certificate) return 0;
    return rdp->cb.certificate(rdp->cb.ctx, fingerprint ? fingerprint : "", subject ? subject : "",
                               issuer ? issuer : "") ? 2 : 0;
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                        const char *subject, const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer, const char *old_fingerprint,
                                        DWORD flags) {
    (void)old_subject; (void)old_issuer; (void)old_fingerprint;
    return verify_certificate(instance, host, port, common_name, subject, issuer, fingerprint, flags);
}

// Never prompts: what the vault (or the sheet) gave is all there is; with nothing, the remote logon screen asks.
static BOOL authenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    (void)instance; (void)username; (void)password; (void)domain; (void)reason;
    return TRUE;
}

// MARK: API

rssh_rdp *rssh_rdp_new(const rssh_rdp_config *config, rssh_rdp_callbacks callbacks) {
    rssh_rdp *rdp = calloc(1, sizeof(rssh_rdp));
    if (!rdp) return NULL;
    rdp->cb = callbacks;
    rdp->host = dup_or_null(config->host);
    rdp->username = dup_or_null(config->username);
    rdp->domain = dup_or_null(config->domain);
    rdp->password = dup_or_null(config->password);
    rdp->port = config->port;
    rdp->width = config->width ? config->width : 1280;
    rdp->height = config->height ? config->height : 800;
    rdp->clipboard = config->clipboard;
    pthread_mutex_init(&rdp->queue_lock, NULL);
    pthread_mutex_init(&rdp->frame_lock, NULL);
    rdp->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    return rdp;
}

static BOOL apply_settings(rssh_rdp *rdp, rdpSettings *s) {
    BOOL ok = TRUE;
    ok &= freerdp_settings_set_string(s, FreeRDP_ServerHostname, rdp->host);
    ok &= freerdp_settings_set_uint32(s, FreeRDP_ServerPort, rdp->port);
    if (rdp->username) ok &= freerdp_settings_set_string(s, FreeRDP_Username, rdp->username);
    if (rdp->domain) ok &= freerdp_settings_set_string(s, FreeRDP_Domain, rdp->domain);
    if (rdp->password) ok &= freerdp_settings_set_string(s, FreeRDP_Password, rdp->password);
    ok &= freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, rdp->width);
    ok &= freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, rdp->height);
    ok &= freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    ok &= freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);
    ok &= freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, FALSE);
    // ServerHostname is 127.0.0.1 (the tunnel), never the certificate's name: the vault pin decides instead.
    ok &= freerdp_settings_set_bool(s, FreeRDP_AutoAcceptCertificate, FALSE);
    ok &= freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, rdp->clipboard ? TRUE : FALSE);
    return ok;
}

uint32_t rssh_rdp_run(rssh_rdp *rdp) {
    freerdp *instance = freerdp_new();
    if (!instance) return FREERDP_ERROR_CONNECT_FAILED;
    rdp->instance = instance;
    instance->ContextSize = sizeof(rssh_context);
    instance->PreConnect = pre_connect;
    instance->LoadChannels = load_channels;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;
    instance->AuthenticateEx = authenticate;
    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        rdp->instance = NULL;
        return FREERDP_ERROR_CONNECT_FAILED;
    }
    ((rssh_context *)instance->context)->owner = rdp;
    // The password lives in FreeRDP's settings from here on; this copy is wiped.
    BOOL ok = apply_settings(rdp, instance->context->settings);
    wipe_free(rdp->password);
    rdp->password = NULL;

    uint32_t result = 0;
    if (!ok) {
        result = FREERDP_ERROR_CONNECT_FAILED;
    } else if (rdp->stop || !freerdp_connect(instance)) {
        result = freerdp_get_last_error(instance->context);
        if (result == 0) result = rdp->stop ? 0 : FREERDP_ERROR_CONNECT_FAILED;
    } else {
        while (!rdp->stop && !freerdp_shall_disconnect_context(instance->context)) {
            HANDLE handles[MAXIMUM_WAIT_OBJECTS];
            DWORD n = freerdp_get_event_handles(instance->context, handles, MAXIMUM_WAIT_OBJECTS - 1);
            if (n == 0) break;
            handles[n++] = rdp->wake;
            (void)WaitForMultipleObjects(n, handles, FALSE, 250);
            drain(rdp);
            if (!freerdp_check_event_handles(instance->context)) {
                result = freerdp_get_last_error(instance->context);
                break;
            }
        }
        freerdp_disconnect(instance);
    }
    rdp->cliprdr = NULL;
    freerdp_context_free(instance);
    freerdp_free(instance);
    rdp->instance = NULL;
    return result;
}

void rssh_rdp_stop(rssh_rdp *rdp) {
    rdp->stop = 1;
    SetEvent(rdp->wake);
    freerdp *instance = rdp->instance;
    if (instance && instance->context) (void)freerdp_abort_connect_context(instance->context);
}

void rssh_rdp_free(rssh_rdp *rdp) {
    if (!rdp) return;
    free(rdp->host);
    free(rdp->username);
    free(rdp->domain);
    wipe_free(rdp->password);
    wipe_free(rdp->local_text);
    CloseHandle(rdp->wake);
    pthread_mutex_destroy(&rdp->queue_lock);
    pthread_mutex_destroy(&rdp->frame_lock);
    free(rdp);
}

const char *rssh_rdp_error_string(uint32_t code) { return freerdp_get_last_error_string(code); }

int rssh_rdp_is_auth_error(uint32_t code) {
    return code == FREERDP_ERROR_AUTHENTICATION_FAILED || code == FREERDP_ERROR_CONNECT_LOGON_FAILURE ||
           code == FREERDP_ERROR_CONNECT_WRONG_PASSWORD || code == FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED ||
           code == FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION || code == FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT ||
           code == FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED || code == FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED ||
           code == FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE || code == FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS;
}

const uint8_t *rssh_rdp_lock_buffer(rssh_rdp *rdp, uint32_t *width, uint32_t *height, uint32_t *stride) {
    pthread_mutex_lock(&rdp->frame_lock);
    freerdp *instance = rdp->instance;
    rdpGdi *gdi = instance && instance->context ? instance->context->gdi : NULL;
    if (!gdi || !gdi->primary_buffer) {
        *width = *height = *stride = 0;
        return NULL;
    }
    *width = gdi->width;
    *height = gdi->height;
    *stride = gdi->stride;
    return gdi->primary_buffer;
}

void rssh_rdp_unlock_buffer(rssh_rdp *rdp) { pthread_mutex_unlock(&rdp->frame_lock); }

void rssh_rdp_mouse(rssh_rdp *rdp, uint16_t flags, uint16_t x, uint16_t y) {
    enqueue(rdp, (queued_event){ EV_MOUSE, flags, x, y });
}

void rssh_rdp_scancode(rssh_rdp *rdp, uint16_t scancode, int extended, int down) {
    enqueue(rdp, (queued_event){ EV_SCANCODE, scancode, (uint16_t)(extended != 0), (uint16_t)(down != 0) });
}

void rssh_rdp_unicode(rssh_rdp *rdp, uint16_t utf16, int down) {
    enqueue(rdp, (queued_event){ EV_UNICODE, utf16, 0, (uint16_t)(down != 0) });
}

void rssh_rdp_set_local_text(rssh_rdp *rdp, const char *utf8) {
    pthread_mutex_lock(&rdp->queue_lock);
    wipe_free(rdp->local_text);
    rdp->local_text = dup_or_null(utf8);
    pthread_mutex_unlock(&rdp->queue_lock);
    enqueue(rdp, (queued_event){ EV_OFFER_TEXT, 0, 0, 0 });
}
