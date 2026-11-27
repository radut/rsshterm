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
    /// The pointer shape: kind 0 = `rgba` (width x height, straight alpha, top-down) with its hotspot, 1 = hidden,
    /// 2 = the system default arrow (rgba NULL for 1 and 2).
    void (*cursor)(void *ctx, int kind, const uint8_t *rgba, uint32_t width, uint32_t height, uint32_t hot_x,
                   uint32_t hot_y);
} rssh_rdp_callbacks;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;   // NULL: log in on the remote logon screen
    const char *domain;     // NULL: none
    const char *password;   // NULL: none
    uint32_t width, height;
    int clipboard;          // 1: text clipboard both ways (cliprdr)
    // Quality (RDPQualityProfile): 0 leaves FreeRDP's defaults.
    uint32_t color_depth;   // 16 or 32
    uint32_t connection_type;   // CONNECTION_TYPE_* (7 = auto-detect)
    int network_autodetect, remote_fx, wallpaper, themes, menu_anims, full_window_drag, font_smoothing,
        composition, compression;
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
/// 1 when the server opened display control: rssh_rdp_resize then resizes the running desktop.
int rssh_rdp_can_resize(rssh_rdp *rdp);
/// Asks the server for a desktop of width x height (even, 200...8192); it answers with a desktop resize (the next
/// `connected` callback reports the new size). Ignored without display control.
void rssh_rdp_resize(rssh_rdp *rdp, uint32_t width, uint32_t height);
/// The codec of the last screen update: 0 none yet, 1 bitmap updates, 2 RemoteFX, 3 NSCodec, 4 other surface bits.
int rssh_rdp_codec(rssh_rdp *rdp);

/// An RDP pointer's XOR/AND masks (bottom-up, word-padded, as on the wire) to `width * height * 4` bytes of RGBA,
/// top-down, straight alpha. `xor_bpp` 1, 16, 24 or 32 (8 needs the session's palette). Returns 1 on success.
int rssh_rdp_pointer_rgba(uint8_t *dst, uint32_t width, uint32_t height, uint32_t xor_bpp, const uint8_t *xor_mask,
                          uint32_t xor_length, const uint8_t *and_mask, uint32_t and_length);
/// Offers this device's clipboard text to the server (clipboard sharing on).
void rssh_rdp_set_local_text(rssh_rdp *rdp, const char *utf8);

#endif
