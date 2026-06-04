/* mojoui_platform.c - MojoUI platform shim over sokol_app (M0 chunk 3)
 *
 * Flat, POD-only C ABI: Mojo never sees a sokol struct.
 *
 * sokol_app loop model: sapp_run() takes over control - creates the OS
 * window, blocks until close, calls .frame_cb / .event_cb. No "pump one
 * frame and return" mode. To fit a Mojo `fn main()` we split the entry:
 *
 *   mojoui_init_window(w,h,title)  - fills a static sapp_desc, returns now.
 *   mojoui_run_blocking(frame_fn)  - stashes frame_fn, calls sapp_run; our
 *                                    frame_cb invokes frame_fn each frame.
 *                                    Returns when the window closes.
 *
 * Passing a Mojo `fn() -> None` as a C function pointer through FFI mirrors
 * how Zig/Odin/Rust sokol bindings handle the loop-inversion problem.
 * mojoui_poll_events() is a no-op kept for ABI symmetry with the audit. */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#if defined(__linux__)
#include <X11/Xlib.h>
#endif

/* Build flags from the Makefile: -DSOKOL_GLCORE -DSOKOL_NO_ENTRY.
 * sokol_gfx and stb_truetype live in their own TUs (chunks 4, 5). */
#define SOKOL_IMPL
#include "sokol_app.h"

/* Consolidated public C ABI — MOJOUI_KEY_* enum + every mojoui_* prototype.
 * Chunk 6 hoisted the enum and prototypes out of this TU and into the
 * canonical header so Mojo FFI (chunk 7) and other TUs see exactly one
 * source of truth. */
#include "mojoui_shim.h"

/* --- Internal state ----------------------------------------------------- */
#define MOJOUI_INPUT_TEXT_CAP 256
#define MOJOUI_WINDOW_TITLE_CAP 256

static sapp_desc g_desc;
static void (*g_frame_fn)(void) = NULL;
/* Opaque user-data slot used by Mojo demos to thread per-frame state through
 * the no-arg sokol_app frame callback. Module-level `var` is rejected in
 * current-beta Mojo (c10 finding), and capturing closures cannot materialise
 * as runtime function pointers (c7's "capturing error-swap"). The canonical
 * fix (c50) is this 2-symbol set/get pair backed by a separate static slot —
 * NOT sapp_userdata, because sapp_desc.user_data is only settable at init
 * time and we want it mutable later. See Mojo implementation notes
 * "Module-level state for frame callbacks". */
static void* g_user_data = NULL;
static int  g_window_width  = 0;
static int  g_window_height = 0;
static int  g_should_close  = 0;
static int  g_mouse_x = 0;
static int  g_mouse_y = 0;
static int  g_mouse_buttons[3] = {0, 0, 0};   /* LEFT, RIGHT, MIDDLE */
static unsigned char g_keys[MOJOUI_KEY_COUNT];
static char g_input_text_buf[MOJOUI_INPUT_TEXT_CAP];
static int  g_input_text_len = 0;
static char g_window_title_buf[MOJOUI_WINDOW_TITLE_CAP];

/* --- sokol keycode -> MOJOUI_KEY_* ------------------------------------- */
static int translate_keycode(sapp_keycode k) {
    switch (k) {
        case SAPP_KEYCODE_BACKSPACE:     return MOJOUI_KEY_BACKSPACE;
        case SAPP_KEYCODE_DELETE:        return MOJOUI_KEY_DELETE;
        case SAPP_KEYCODE_ENTER:
        case SAPP_KEYCODE_KP_ENTER:      return MOJOUI_KEY_RETURN;
        case SAPP_KEYCODE_TAB:           return MOJOUI_KEY_TAB;
        case SAPP_KEYCODE_ESCAPE:        return MOJOUI_KEY_ESCAPE;
        case SAPP_KEYCODE_SPACE:         return MOJOUI_KEY_SPACE;
        case SAPP_KEYCODE_LEFT:          return MOJOUI_KEY_LEFT;
        case SAPP_KEYCODE_RIGHT:         return MOJOUI_KEY_RIGHT;
        case SAPP_KEYCODE_UP:            return MOJOUI_KEY_UP;
        case SAPP_KEYCODE_DOWN:          return MOJOUI_KEY_DOWN;
        case SAPP_KEYCODE_HOME:          return MOJOUI_KEY_HOME;
        case SAPP_KEYCODE_END:           return MOJOUI_KEY_END;
        case SAPP_KEYCODE_PAGE_UP:       return MOJOUI_KEY_PAGE_UP;
        case SAPP_KEYCODE_PAGE_DOWN:     return MOJOUI_KEY_PAGE_DOWN;
        case SAPP_KEYCODE_LEFT_SHIFT:    return MOJOUI_KEY_LSHIFT;
        case SAPP_KEYCODE_RIGHT_SHIFT:   return MOJOUI_KEY_RSHIFT;
        case SAPP_KEYCODE_LEFT_CONTROL:  return MOJOUI_KEY_LCTRL;
        case SAPP_KEYCODE_RIGHT_CONTROL: return MOJOUI_KEY_RCTRL;
        case SAPP_KEYCODE_LEFT_ALT:      return MOJOUI_KEY_LALT;
        case SAPP_KEYCODE_RIGHT_ALT:     return MOJOUI_KEY_RALT;
        case SAPP_KEYCODE_LEFT_SUPER:    return MOJOUI_KEY_LSUPER;
        case SAPP_KEYCODE_RIGHT_SUPER:   return MOJOUI_KEY_RSUPER;
        default:                         break;
    }
    if (k >= SAPP_KEYCODE_A && k <= SAPP_KEYCODE_Z)
        return MOJOUI_KEY_A + ((int)k - SAPP_KEYCODE_A);
    if (k >= SAPP_KEYCODE_0 && k <= SAPP_KEYCODE_9)
        return MOJOUI_KEY_0 + ((int)k - SAPP_KEYCODE_0);
    if (k >= SAPP_KEYCODE_F1 && k <= SAPP_KEYCODE_F12)
        return MOJOUI_KEY_F1 + ((int)k - SAPP_KEYCODE_F1);
    return MOJOUI_KEY_UNKNOWN;
}

/* Encode one UTF-32 code point into g_input_text_buf as UTF-8. */
static void input_text_append_utf8(uint32_t cp) {
    char out[4]; int n = 0;
    if (cp < 0x80) { out[0] = (char)cp; n = 1; }
    else if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F)); n = 2;
    } else if (cp < 0x10000) {
        out[0] = (char)(0xE0 |  (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 |  (cp       & 0x3F)); n = 3;
    } else if (cp < 0x110000) {
        out[0] = (char)(0xF0 |  (cp >> 18));
        out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[2] = (char)(0x80 | ((cp >> 6)  & 0x3F));
        out[3] = (char)(0x80 |  (cp        & 0x3F)); n = 4;
    } else return;
    if (g_input_text_len + n >= MOJOUI_INPUT_TEXT_CAP) return; /* drop on overflow */
    memcpy(g_input_text_buf + g_input_text_len, out, (size_t)n);
    g_input_text_len += n;
    g_input_text_buf[g_input_text_len] = '\0';
}

/* --- sokol_app callbacks ----------------------------------------------- */
static void platform_init_cb(void) {
    g_window_width = sapp_width(); g_window_height = sapp_height();
    /* sg_setup needs sglue_environment() which requires a live GL context;
     * the context exists only after sapp creates the window, i.e. NOW (inside
     * sapp's init callback). Calling mojoui_render_init() from Mojo BEFORE
     * mojoui_run_blocking would fail silently — there is no GL context yet.
     * So the C floor self-initializes the render subsystem here. Documented
     * in Mojo implementation notes ("render_init timing"). */
    (void)mojoui_render_init();
}
static void platform_frame_cb(void) {
    g_window_width = sapp_width(); g_window_height = sapp_height();
    if (g_frame_fn) g_frame_fn();
}
static void platform_cleanup_cb(void) {
    mojoui_destroy_all_fonts();
    mojoui_render_shutdown();
    g_frame_fn = NULL;
    g_user_data = NULL;
}

static void platform_event_cb(const sapp_event* ev) {
    switch (ev->type) {
        case SAPP_EVENTTYPE_KEY_DOWN: {
            int mk = translate_keycode(ev->key_code);
            if (mk != MOJOUI_KEY_UNKNOWN && mk < MOJOUI_KEY_COUNT) g_keys[mk] = 1;
        } break;
        case SAPP_EVENTTYPE_KEY_UP: {
            int mk = translate_keycode(ev->key_code);
            if (mk != MOJOUI_KEY_UNKNOWN && mk < MOJOUI_KEY_COUNT) g_keys[mk] = 0;
        } break;
        case SAPP_EVENTTYPE_CHAR:
            input_text_append_utf8(ev->char_code);
            break;
        case SAPP_EVENTTYPE_MOUSE_DOWN: {
            int b = (int)ev->mouse_button;
            if (b >= 0 && b < 3) g_mouse_buttons[b] = 1;
        } break;
        case SAPP_EVENTTYPE_MOUSE_UP: {
            int b = (int)ev->mouse_button;
            if (b >= 0 && b < 3) g_mouse_buttons[b] = 0;
        } break;
        case SAPP_EVENTTYPE_MOUSE_MOVE:
            g_mouse_x = (int)ev->mouse_x;
            g_mouse_y = (int)ev->mouse_y;
            break;
        case SAPP_EVENTTYPE_RESIZED:
            g_window_width  = ev->window_width;
            g_window_height = ev->window_height;
            break;
        case SAPP_EVENTTYPE_QUIT_REQUESTED:
            g_should_close = 1;
            break;
        default: break;
    }
}

static const char* copy_window_title(const char* title, int title_len) {
    if (title == NULL || title_len <= 0) {
        memcpy(g_window_title_buf, "MojoUI", 7);
        return g_window_title_buf;
    }
    int n = title_len;
    if (n >= MOJOUI_WINDOW_TITLE_CAP) {
        n = MOJOUI_WINDOW_TITLE_CAP - 1;
    }
    memcpy(g_window_title_buf, title, (size_t)n);
    g_window_title_buf[n] = '\0';
    return g_window_title_buf;
}

/* --- Public ABI implementation ----------------------------------------- */
int mojoui_init_window_len(int width, int height, const char* title, int title_len) {
    memset(&g_desc, 0, sizeof(g_desc));
    g_desc.init_cb      = platform_init_cb;
    g_desc.frame_cb     = platform_frame_cb;
    g_desc.cleanup_cb   = platform_cleanup_cb;
    g_desc.event_cb     = platform_event_cb;
    g_desc.width        = width  > 0 ? width  : 800;
    g_desc.height       = height > 0 ? height : 600;
    g_desc.window_title = copy_window_title(title, title_len);
    /* high_dpi=true caused widgets-tiny + clicks-miss on 4K — sapp_width()
     * returns framebuffer pixels (huge) but mouse_x comes in scaled pixels,
     * so widget rects and click hit-tests live in different coordinate
     * systems. Flip to false: same units everywhere, blurrier text on
     * Retina/4K but functionally correct. Proper fix = uniform DPI scaling
     * applied to both layout and mouse. */
    g_desc.high_dpi     = false;
    g_desc.sample_count = 1;

    g_window_width  = g_desc.width;
    g_window_height = g_desc.height;
    g_should_close  = 0;
    g_mouse_x = g_mouse_y = 0;
    memset(g_mouse_buttons, 0, sizeof(g_mouse_buttons));
    memset(g_keys, 0, sizeof(g_keys));
    g_input_text_len    = 0;
    g_input_text_buf[0] = '\0';
    return 0;
}

int mojoui_init_window(int width, int height, const char* title) {
    int title_len = title ? (int)strlen(title) : 0;
    return mojoui_init_window_len(width, height, title, title_len);
}

void mojoui_run_blocking(void (*frame_fn)(void)) {
    g_frame_fn = frame_fn;
    sapp_run(&g_desc);
    g_frame_fn = NULL;
    g_user_data = NULL;
}

void mojoui_request_close(void) {
    g_should_close = 1;
    if (sapp_isvalid()) sapp_request_quit();
}

int  mojoui_should_close(void)      { return g_should_close;  }
void mojoui_poll_events(void)       { /* sokol pumps inside sapp_run */ }
int  mojoui_get_window_width(void)  { return g_window_width;  }
int  mojoui_get_window_height(void) { return g_window_height; }

static int query_x11_display_dim(int want_width) {
#if defined(__linux__)
    Display* dpy = XOpenDisplay(NULL);
    if (dpy == NULL) {
        return 0;
    }
    int screen = DefaultScreen(dpy);
    int value = want_width ? DisplayWidth(dpy, screen) : DisplayHeight(dpy, screen);
    XCloseDisplay(dpy);
    return value;
#else
    (void)want_width;
    return 0;
#endif
}

int mojoui_get_display_width(void) {
    int w = query_x11_display_dim(1);
    return w > 0 ? w : g_window_width;
}

int mojoui_get_display_height(void) {
    int h = query_x11_display_dim(0);
    return h > 0 ? h : g_window_height;
}

int  mojoui_get_mouse_x(void)       { return g_mouse_x; }
int  mojoui_get_mouse_y(void)       { return g_mouse_y; }

int mojoui_get_mouse_button(int button) {
    if (button < 0 || button >= 3) return 0;
    return g_mouse_buttons[button];
}

int mojoui_get_key(int mojoui_key) {
    if (mojoui_key <= 0 || mojoui_key >= MOJOUI_KEY_COUNT) return 0;
    return (int)g_keys[mojoui_key];
}

const char* mojoui_get_input_text(void)   { return g_input_text_buf; }
int         mojoui_input_text_length(void){ return g_input_text_len; }

void mojoui_clear_input_text(void) {
    g_input_text_len    = 0;
    g_input_text_buf[0] = '\0';
}

/* --- User-data slot (c50) ----------------------------------------------
 * Backing for the canonical "module-level state for frame callbacks" fix:
 * Mojo demos heap- or stack-allocate an AppState struct in main(), then
 * mojoui_set_user_data(&state) before mojoui_run_blocking; the no-arg
 * frame callback recovers the typed pointer via mojoui_get_user_data().
 * The pointer's lifetime is owned by the Mojo caller — the C side just
 * stashes/returns the bits and never dereferences. NULL is a valid value
 * (the initial state, and a valid "no state attached" sentinel). */
void mojoui_set_user_data(void* ptr) {
    g_user_data = ptr;
}

void* mojoui_get_user_data(void) {
    return g_user_data;
}
