/*
 * FreeRDP 3 spike: connect to an RDP server, log in, wait for frames and write the screen as a PPM.
 * Proves libfreerdp3 (Apache-2.0) + its software GDI give the app a BGRX framebuffer it can draw, the way
 * RoyalVNCKit does for VNC. Run against the local end of the SSH tunnel (LocalPortForwarder).
 *
 *   grab <host> <port> <user> <out.ppm>       password from $RDP_PASSWORD (never on the command line)
 *
 * Exit 0 when at least one frame arrived and the picture is not one flat colour.
 */
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int frames = 0;

static BOOL end_paint(rdpContext* context) {
    (void)context;
    frames++;
    return TRUE;
}

static BOOL post_connect(freerdp* instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    instance->context->update->EndPaint = end_paint;
    return TRUE;
}

static void post_disconnect(freerdp* instance) {
    gdi_free(instance);
}

/* The spike trusts the test server's self-signed certificate for this session only (2). The app instead pins
 * the fingerprint in the vault, like SSH host keys. */
static DWORD accept_cert(freerdp* instance, const char* host, UINT16 port, const char* common_name,
                         const char* subject, const char* issuer, const char* fingerprint, DWORD flags) {
    (void)instance; (void)port; (void)common_name; (void)subject; (void)issuer; (void)flags;
    fprintf(stderr, "certificate of %s: %s\n", host, fingerprint);
    return 2;
}

static int write_ppm(rdpGdi* gdi, const char* path) {
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%u %u\n255\n", gdi->width, gdi->height);
    for (UINT32 y = 0; y < gdi->height; y++) {
        const BYTE* row = gdi->primary_buffer + (size_t)y * gdi->stride;
        for (UINT32 x = 0; x < gdi->width; x++) {
            const BYTE* p = row + x * 4;   /* B G R X */
            BYTE rgb[3] = { p[2], p[1], p[0] };
            fwrite(rgb, 1, 3, f);
        }
    }
    return fclose(f);
}

static int distinct_colours(rdpGdi* gdi) {
    UINT32 first = *(UINT32*)gdi->primary_buffer;
    for (UINT32 y = 0; y < gdi->height; y++) {
        const UINT32* row = (const UINT32*)(gdi->primary_buffer + (size_t)y * gdi->stride);
        for (UINT32 x = 0; x < gdi->width; x++)
            if ((row[x] & 0xffffff) != (first & 0xffffff)) return 2;
    }
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: grab <host> <port> <user> <out.ppm>  (password in $RDP_PASSWORD)\n");
        return 2;
    }
    const char* password = getenv("RDP_PASSWORD");
    freerdp* instance = freerdp_new();
    if (!instance) { fprintf(stderr, "freerdp_new failed\n"); return 1; }
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->VerifyCertificateEx = accept_cert;
    if (!freerdp_context_new(instance)) { fprintf(stderr, "freerdp_context_new failed (is $HOME set?)\n"); return 1; }
    rdpSettings* s = instance->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, argv[1]);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)atoi(argv[2]));
    freerdp_settings_set_string(s, FreeRDP_Username, argv[3]);
    if (password) freerdp_settings_set_string(s, FreeRDP_Password, password);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1024);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 768);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);
    /* The ServerHostname is 127.0.0.1 (the tunnel), never the certificate's name. */
    freerdp_settings_set_bool(s, FreeRDP_AutoAcceptCertificate, FALSE);

    if (!freerdp_connect(instance)) {
        fprintf(stderr, "connect failed: %s\n", freerdp_get_last_error_string(freerdp_get_last_error(instance->context)));
        return 1;
    }
    time_t start = time(NULL);
    int last = -1, quiet = 0;
    /* Wait for the first frames, then until painting has been quiet for ~1.5 s (the session has drawn). */
    while (!freerdp_shall_disconnect_context(instance->context) && time(NULL) - start < 30) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD n = freerdp_get_event_handles(instance->context, handles, MAXIMUM_WAIT_OBJECTS);
        if (n == 0) break;
        WaitForMultipleObjects(n, handles, FALSE, 100);
        if (!freerdp_check_event_handles(instance->context)) break;
        if (frames > 0 && frames == last) { if (++quiet >= 15) break; } else quiet = 0;
        last = frames;
    }
    rdpGdi* gdi = instance->context->gdi;
    int ok = frames > 0 && gdi && gdi->primary_buffer;
    int colours = ok ? distinct_colours(gdi) : 0;
    if (ok) write_ppm(gdi, argv[4]);
    printf("frames=%d size=%ux%u colours=%s\n", frames, gdi ? gdi->width : 0, gdi ? gdi->height : 0,
           colours > 1 ? "many" : "flat");
    freerdp_disconnect(instance);
    freerdp_context_free(instance);
    freerdp_free(instance);
    return ok && colours > 1 ? 0 : 1;
}
