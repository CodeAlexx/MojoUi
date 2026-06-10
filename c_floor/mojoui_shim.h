#ifndef MOJOUI_SHIM_H
#define MOJOUI_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================
 * MojoUI public C ABI — consumed by Mojo via FFI.
 *
 * Convention: integer pixel coords, 0-255 RGBA components,
 * opaque uint32 texture/font handles (0 = error / built-in).
 *
 * Vertex format for mojoui_draw_batch: 5 floats per vertex =
 * (x_pos, y_pos, u, v, color_bits) stride 20 bytes. The 5th
 * "float" is a uint32 packed as 0xAABBGGRR bit-reinterpreted
 * (memcpy(&fbits, &u32, 4)). The sokol_gfx pipeline reads
 * attribute 2 at offset 16 as SG_VERTEXFORMAT_UBYTE4N.
 * (ImDrawVert-style; do NOT treat the 5th value as a real float.)
 *
 * Built-in texture_id=0 is a 1x1 white texture for untextured
 * colored geometry.
 *
 * See:
 *   project map          — wayfinding
 *   public ABI notes             — full per-function notes
 *   public ABI notes         — vertex / color / coord
 * ============================================================ */


/* ----- MOJOUI_KEY_* enum (sokol-agnostic) ----------------- */

typedef enum {
    MOJOUI_KEY_UNKNOWN = 0,
    MOJOUI_KEY_BACKSPACE,
    MOJOUI_KEY_DELETE,
    MOJOUI_KEY_RETURN,
    MOJOUI_KEY_TAB,
    MOJOUI_KEY_ESCAPE,
    MOJOUI_KEY_SPACE,
    MOJOUI_KEY_LEFT,
    MOJOUI_KEY_RIGHT,
    MOJOUI_KEY_UP,
    MOJOUI_KEY_DOWN,
    MOJOUI_KEY_HOME,
    MOJOUI_KEY_END,
    MOJOUI_KEY_PAGE_UP,
    MOJOUI_KEY_PAGE_DOWN,
    MOJOUI_KEY_LSHIFT,
    MOJOUI_KEY_RSHIFT,
    MOJOUI_KEY_LCTRL,
    MOJOUI_KEY_RCTRL,
    MOJOUI_KEY_LALT,
    MOJOUI_KEY_RALT,
    MOJOUI_KEY_LSUPER,
    MOJOUI_KEY_RSUPER,
    MOJOUI_KEY_A, MOJOUI_KEY_B, MOJOUI_KEY_C, MOJOUI_KEY_D, MOJOUI_KEY_E,
    MOJOUI_KEY_F, MOJOUI_KEY_G, MOJOUI_KEY_H, MOJOUI_KEY_I, MOJOUI_KEY_J,
    MOJOUI_KEY_K, MOJOUI_KEY_L, MOJOUI_KEY_M, MOJOUI_KEY_N, MOJOUI_KEY_O,
    MOJOUI_KEY_P, MOJOUI_KEY_Q, MOJOUI_KEY_R, MOJOUI_KEY_S, MOJOUI_KEY_T,
    MOJOUI_KEY_U, MOJOUI_KEY_V, MOJOUI_KEY_W, MOJOUI_KEY_X, MOJOUI_KEY_Y, MOJOUI_KEY_Z,
    MOJOUI_KEY_0 = 49, MOJOUI_KEY_1, MOJOUI_KEY_2, MOJOUI_KEY_3, MOJOUI_KEY_4,
    MOJOUI_KEY_5, MOJOUI_KEY_6, MOJOUI_KEY_7, MOJOUI_KEY_8, MOJOUI_KEY_9,
    MOJOUI_KEY_F1 = 59, MOJOUI_KEY_F2, MOJOUI_KEY_F3, MOJOUI_KEY_F4,
    MOJOUI_KEY_F5, MOJOUI_KEY_F6, MOJOUI_KEY_F7, MOJOUI_KEY_F8,
    MOJOUI_KEY_F9, MOJOUI_KEY_F10, MOJOUI_KEY_F11, MOJOUI_KEY_F12,
    MOJOUI_KEY_COUNT = 96
} mojoui_key_t;

/* Mouse button indices for mojoui_get_mouse_button */
#define MOJOUI_BTN_LEFT   0
#define MOJOUI_BTN_RIGHT  1
#define MOJOUI_BTN_MIDDLE 2


/* ============================================================
 * Section 1 — Window + Input (chunk 3, mojoui_platform.c)
 * ============================================================ */

int   mojoui_init_window(int width, int height, const char* title);
int   mojoui_init_window_len(int width, int height, const char* title, int title_len);
void  mojoui_run_blocking(void (*frame_fn)(void));
void  mojoui_request_close(void);
int   mojoui_should_close(void);
void  mojoui_poll_events(void);
int   mojoui_get_window_width(void);
int   mojoui_get_window_height(void);
int   mojoui_get_display_width(void);
int   mojoui_get_display_height(void);
int   mojoui_get_mouse_x(void);
int   mojoui_get_mouse_y(void);
int   mojoui_get_mouse_button(int button);  /* button: MOJOUI_BTN_* */
float mojoui_get_scroll_x(void);
float mojoui_get_scroll_y(void);
void  mojoui_clear_scroll(void);
int   mojoui_get_key(int mojoui_key);       /* mojoui_key: MOJOUI_KEY_* */
const char* mojoui_get_input_text(void);
int   mojoui_input_text_length(void);
void  mojoui_clear_input_text(void);

/* User-data slot for the no-arg sokol_app frame callback (c50). Stashes a
 * caller-owned opaque pointer in a static module-level slot so a Mojo demo
 * can recover its per-frame mutable state from inside `frame_fn`. Backed by
 * a separate `static void*` in mojoui_platform.c (NOT sapp_userdata, which
 * is only settable at init time). NULL is a valid stored value. */
void  mojoui_set_user_data(void* ptr);
void* mojoui_get_user_data(void);


/* ============================================================
 * Section 2 — GPU 2D Rendering (chunk 4, mojoui_render.c)
 * ============================================================ */

int      mojoui_render_init(void);
void     mojoui_render_shutdown(void);
void     mojoui_frame_begin(int clear_r, int clear_g, int clear_b, int clear_a);
void     mojoui_frame_end(void);
void     mojoui_draw_batch(const float* verts, int n_verts,
                           const uint16_t* indices, int n_indices,
                           uint32_t texture_id);
int      mojoui_draw_batch_checked(const float* verts, int n_verts,
                                   const uint16_t* indices, int n_indices,
                                   uint32_t texture_id);
void     mojoui_set_clip_rect(int x, int y, int width, int height);
void     mojoui_reset_clip_rect(void);
int      mojoui_max_batch_verts(void);
int      mojoui_max_batch_indices(void);
uint32_t mojoui_make_texture(int width, int height, const uint8_t* rgba_pixels);
void     mojoui_destroy_texture(uint32_t texture_id);
uint32_t mojoui_load_texture_file_len(const char* path, int path_len,
                                      int max_width, int max_height,
                                      int* out_width, int* out_height);
int      mojoui_is_video_file_len(const char* path, int path_len);
uint32_t mojoui_load_video_thumbnail_len(const char* path, int path_len,
                                         int max_width, int max_height,
                                         int* out_width, int* out_height);
int      mojoui_open_video_file_len(const char* path, int path_len);
void     mojoui_media_scan_clear(void);
int      mojoui_media_scan_dir_len(const char* path, int path_len,
                                   int recursive, int max_items);
int      mojoui_media_scan_count(void);
const char* mojoui_media_scan_path(int index);
int      mojoui_media_scan_path_len(int index);
int      mojoui_media_scan_is_video(int index);


/* ============================================================
 * Section 2b — Host/GPU Metrics (headless-safe helpers)
 * ============================================================ */

int      mojoui_refresh_system_metrics(void);
const char* mojoui_system_gpu_name(void);
int      mojoui_system_gpu_name_len(void);
const char* mojoui_system_gpu_driver(void);
int      mojoui_system_gpu_driver_len(void);
int      mojoui_system_gpu_memory_total_mb(void);
int      mojoui_system_gpu_memory_used_mb(void);
int      mojoui_system_gpu_util_percent(void);
int      mojoui_system_gpu_temperature_c(void);
const char* mojoui_system_cpu_name(void);
int      mojoui_system_cpu_name_len(void);
int      mojoui_system_cpu_util_percent(void);
int      mojoui_system_ram_total_mb(void);
int      mojoui_system_ram_used_mb(void);


/* ============================================================
 * Section 3 — Font Atlas + Text (chunk 5, mojoui_fonts.c)
 * ============================================================ */

uint32_t mojoui_load_font(const char* path);  /* NULL/"" -> default search */
uint32_t mojoui_load_font_len(const char* path, int path_len);
void     mojoui_destroy_font(uint32_t font_id);
void     mojoui_destroy_all_fonts(void);
int      mojoui_text_width(uint32_t font_id, int size_pt, const char* text, int text_len);
int      mojoui_text_height(uint32_t font_id, int size_pt);
int      mojoui_draw_text(uint32_t font_id, int size_pt, const char* text, int text_len,
                          int x, int y, int r, int g, int b, int a);


/* ============================================================
 * Section 4 — Audio playback (ALSA, mojoui_audio.c)
 * ============================================================ */

int  mojoui_audio_init(int rate, int channels);              /* 0 ok, <0 ALSA error */
int  mojoui_audio_is_open(void);
int  mojoui_audio_write(const float* samples, int nframes);  /* interleaved f32; blocking */
void mojoui_audio_drain(void);                               /* block until queued audio done */
void mojoui_audio_shutdown(void);


#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* MOJOUI_SHIM_H */
