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
 *   /home/alex/MojoUI/MAP.md          — wayfinding
 *   docs/MOJOUI_KERNELS.md             — full per-function notes
 *   docs/MOJOUI_CONVENTIONS.md         — vertex / color / coord
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
void  mojoui_run_blocking(void (*frame_fn)(void));
void  mojoui_request_close(void);
int   mojoui_should_close(void);
void  mojoui_poll_events(void);
int   mojoui_get_window_width(void);
int   mojoui_get_window_height(void);
int   mojoui_get_mouse_x(void);
int   mojoui_get_mouse_y(void);
int   mojoui_get_mouse_button(int button);  /* button: MOJOUI_BTN_* */
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
uint32_t mojoui_make_texture(int width, int height, const uint8_t* rgba_pixels);
void     mojoui_destroy_texture(uint32_t texture_id);


/* ============================================================
 * Section 3 — Font Atlas + Text (chunk 5, mojoui_fonts.c)
 * ============================================================ */

uint32_t mojoui_load_font(const char* path);  /* NULL/"" -> default search */
void     mojoui_destroy_font(uint32_t font_id);
int      mojoui_text_width(uint32_t font_id, int size_pt, const char* text, int text_len);
int      mojoui_text_height(uint32_t font_id, int size_pt);
int      mojoui_draw_text(uint32_t font_id, int size_pt, const char* text, int text_len,
                          int x, int y, int r, int g, int b, int a);


#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* MOJOUI_SHIM_H */
