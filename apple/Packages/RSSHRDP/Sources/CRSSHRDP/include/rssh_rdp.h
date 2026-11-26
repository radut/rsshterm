// A small C face over libfreerdp3 for Swift: plain types only, no FreeRDP headers.
#ifndef RSSH_RDP_H
#define RSSH_RDP_H
#include <stdint.h>

typedef struct rssh_rdp rssh_rdp;

typedef struct {
    void *ctx;
    /// The server's TLS certificate; return 1 to accept, 0 to refuse (the connection then fails).
    int (*certificate)(void *ctx, const char *fingerprint, const char *subject, const char *issuer);
    /// Logged in and drawing: the desktop size.
    void (*connected)(void *ctx, uint32_t width, uint32_t height);
    /// A painted rectangle of the framebuffer.
    void (*frame)(void *ctx, int32_t x, int32_t y, int32_t width, int32_t height);
    /// The server's clipboard text (UTF-8), when clipboard sharing is on.
    void (*remote_text)(void *ctx, const char *utf8);
} rssh_rdp_callbacks;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;   // NULL: log in on the remote logon screen
    const char *domain;     // NULL: none
    const char *password;   // NULL: none
    uint32_t width, height;
    int clipboard;          // 1: text clipboard both ways (cliprdr)
} rssh_rdp_config;

rssh_rdp *rssh_rdp_new(const rssh_rdp_config *config, rssh_rdp_callbacks callbacks);
/// Connects and runs until the session ends or rssh_rdp_stop. Returns 0, or the FreeRDP error code.
uint32_t rssh_rdp_run(rssh_rdp *rdp);
/// From any thread.
void rssh_rdp_stop(rssh_rdp *rdp);
void rssh_rdp_free(rssh_rdp *rdp);

const char *rssh_rdp_error_string(uint32_t code);
/// 1 when `code` means wrong user or password.
int rssh_rdp_is_auth_error(uint32_t code);

/// The framebuffer (BGRX, 32 bits per pixel) under the frame lock; NULL before connected.
const uint8_t *rssh_rdp_lock_buffer(rssh_rdp *rdp, uint32_t *width, uint32_t *height, uint32_t *stride);
void rssh_rdp_unlock_buffer(rssh_rdp *rdp);

/// Input, from any thread: queued and sent by the session's own thread.
void rssh_rdp_mouse(rssh_rdp *rdp, uint16_t flags, uint16_t x, uint16_t y);
void rssh_rdp_scancode(rssh_rdp *rdp, uint16_t scancode, int extended, int down);
void rssh_rdp_unicode(rssh_rdp *rdp, uint16_t utf16, int down);
/// Offers this device's clipboard text to the server (clipboard sharing on).
void rssh_rdp_set_local_text(rssh_rdp *rdp, const char *utf8);

#endif
