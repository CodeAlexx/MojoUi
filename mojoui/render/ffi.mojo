"""Mojo FFI declarations for the MojoUI C floor.

Source of truth: the MojoUI repo/c_floor/mojoui_shim.h
Every public function exported by libmojoui_floor.so is bound here.

Usage:
    from mojoui.render.ffi import init_window, run_blocking, render_init, ...

At runtime, libmojoui_floor.so must be findable by the dynamic linker.
Pixi tasks in the project root prepend LD_LIBRARY_PATH=. so `pixi run hello`
and `pixi run test-ffi` work from the MojoUI repo.

Conventions (matching c_floor/mojoui_shim.h):
  * Integer pixel coords (Int32 at the FFI boundary).
  * 0-255 RGBA components.
  * Opaque UInt32 texture/font handles (0 = error / built-in).
  * Strings cross via String.unsafe_ptr() (UnsafePointer[UInt8]) PLUS an
    explicit byte length. Mojo's String is NOT reliably NUL-terminated at
    unsafe_ptr() in current beta, so any C function that consumes a string
    takes a length param and must be bounded by it (never scan for '\0').
    Relying on NUL termination caused stale-glyph text bleed (fixed 2026-05-28).
  * mojoui_run_blocking takes a fn() -> None Mojo callback that sokol_app
    invokes once per frame; this is the known-fragile function-pointer FFI
    case flagged in Mojo implementation notes ("Open questions").
"""

from std.ffi import external_call
from std.memory import UnsafePointer
from std.builtin.type_aliases import MutAnyOrigin


# ============================================================
# MOJOUI_KEY_* constants — mirror c_floor/mojoui_shim.h enum
# Values verified against the C enum exactly. UNKNOWN=0, RETURN=3,
# A=23..Z=48, 0=49..9=58, F1=59..F12=70, COUNT=96.
# ============================================================

comptime MOJOUI_KEY_UNKNOWN: Int32 = 0
comptime MOJOUI_KEY_BACKSPACE: Int32 = 1
comptime MOJOUI_KEY_DELETE: Int32 = 2
comptime MOJOUI_KEY_RETURN: Int32 = 3
comptime MOJOUI_KEY_TAB: Int32 = 4
comptime MOJOUI_KEY_ESCAPE: Int32 = 5
comptime MOJOUI_KEY_SPACE: Int32 = 6
comptime MOJOUI_KEY_LEFT: Int32 = 7
comptime MOJOUI_KEY_RIGHT: Int32 = 8
comptime MOJOUI_KEY_UP: Int32 = 9
comptime MOJOUI_KEY_DOWN: Int32 = 10
comptime MOJOUI_KEY_HOME: Int32 = 11
comptime MOJOUI_KEY_END: Int32 = 12
comptime MOJOUI_KEY_PAGE_UP: Int32 = 13
comptime MOJOUI_KEY_PAGE_DOWN: Int32 = 14
comptime MOJOUI_KEY_LSHIFT: Int32 = 15
comptime MOJOUI_KEY_RSHIFT: Int32 = 16
comptime MOJOUI_KEY_LCTRL: Int32 = 17
comptime MOJOUI_KEY_RCTRL: Int32 = 18
comptime MOJOUI_KEY_LALT: Int32 = 19
comptime MOJOUI_KEY_RALT: Int32 = 20
comptime MOJOUI_KEY_LSUPER: Int32 = 21
comptime MOJOUI_KEY_RSUPER: Int32 = 22

# Letters A..Z occupy 23..48 (sequential after RSUPER=22).
comptime MOJOUI_KEY_A: Int32 = 23
comptime MOJOUI_KEY_B: Int32 = 24
comptime MOJOUI_KEY_C: Int32 = 25
comptime MOJOUI_KEY_D: Int32 = 26
comptime MOJOUI_KEY_E: Int32 = 27
comptime MOJOUI_KEY_F: Int32 = 28
comptime MOJOUI_KEY_G: Int32 = 29
comptime MOJOUI_KEY_H: Int32 = 30
comptime MOJOUI_KEY_I: Int32 = 31
comptime MOJOUI_KEY_J: Int32 = 32
comptime MOJOUI_KEY_K: Int32 = 33
comptime MOJOUI_KEY_L: Int32 = 34
comptime MOJOUI_KEY_M: Int32 = 35
comptime MOJOUI_KEY_N: Int32 = 36
comptime MOJOUI_KEY_O: Int32 = 37
comptime MOJOUI_KEY_P: Int32 = 38
comptime MOJOUI_KEY_Q: Int32 = 39
comptime MOJOUI_KEY_R: Int32 = 40
comptime MOJOUI_KEY_S: Int32 = 41
comptime MOJOUI_KEY_T: Int32 = 42
comptime MOJOUI_KEY_U: Int32 = 43
comptime MOJOUI_KEY_V: Int32 = 44
comptime MOJOUI_KEY_W: Int32 = 45
comptime MOJOUI_KEY_X: Int32 = 46
comptime MOJOUI_KEY_Y: Int32 = 47
comptime MOJOUI_KEY_Z: Int32 = 48

# Digits 0..9 explicitly start at 49 in the C enum.
comptime MOJOUI_KEY_0: Int32 = 49
comptime MOJOUI_KEY_1: Int32 = 50
comptime MOJOUI_KEY_2: Int32 = 51
comptime MOJOUI_KEY_3: Int32 = 52
comptime MOJOUI_KEY_4: Int32 = 53
comptime MOJOUI_KEY_5: Int32 = 54
comptime MOJOUI_KEY_6: Int32 = 55
comptime MOJOUI_KEY_7: Int32 = 56
comptime MOJOUI_KEY_8: Int32 = 57
comptime MOJOUI_KEY_9: Int32 = 58

# Function keys F1..F12 explicitly start at 59 in the C enum.
comptime MOJOUI_KEY_F1: Int32 = 59
comptime MOJOUI_KEY_F2: Int32 = 60
comptime MOJOUI_KEY_F3: Int32 = 61
comptime MOJOUI_KEY_F4: Int32 = 62
comptime MOJOUI_KEY_F5: Int32 = 63
comptime MOJOUI_KEY_F6: Int32 = 64
comptime MOJOUI_KEY_F7: Int32 = 65
comptime MOJOUI_KEY_F8: Int32 = 66
comptime MOJOUI_KEY_F9: Int32 = 67
comptime MOJOUI_KEY_F10: Int32 = 68
comptime MOJOUI_KEY_F11: Int32 = 69
comptime MOJOUI_KEY_F12: Int32 = 70

comptime MOJOUI_KEY_COUNT: Int32 = 96

# Mouse-button indices for mojoui_get_mouse_button.
comptime MOJOUI_BTN_LEFT: Int32 = 0
comptime MOJOUI_BTN_RIGHT: Int32 = 1
comptime MOJOUI_BTN_MIDDLE: Int32 = 2


# ============================================================
# Section 1 — Window + Input (14 fns, c_floor/mojoui_platform.c)
# ============================================================

def init_window(width: Int32, height: Int32, title: String) -> Int32:
    """mojoui_init_window(w, h, title) -> int. Returns 0 on success.

    Fills the static sapp_desc but does NOT run the sapp loop — call
    run_blocking() afterward to enter the frame loop. `title` must
    remain valid only for the duration of this call; the C side copies
    the string into its sapp_desc.window_title.
    """
    return external_call["mojoui_init_window", Int32](
        width, height, title.unsafe_ptr()
    )


def run_blocking[CbType: AnyType, //](frame_fn: CbType):
    """mojoui_run_blocking(frame_fn). Calls sapp_run; sokol invokes
    frame_fn once per frame. Blocks until the window closes.

    `frame_fn` must be a Mojo `def () -> None` (zero args, no return).
    The CbType type parameter is inferred from the call site; we cannot
    use a concrete `def () -> None` parameter type because the current
    Mojo beta marks every top-level `def` as `capturing`, so a literal
    name doesn't unify with the non-capturing function-pointer type
    spelled in the parameter list (the error swap: declare `capturing`
    and the noop is "not capturing", drop it and the noop is "capturing").
    Parametric `CbType: AnyType` lets external_call accept any function
    reference and pass it through verbatim — the C ABI does the rest.
    Documented in Mojo implementation notes ("Living additions").
    """
    external_call["mojoui_run_blocking", NoneType](frame_fn)


def request_close():
    """mojoui_request_close(). Safe before sapp_run (sets a flag);
    after, calls sapp_request_quit."""
    external_call["mojoui_request_close", NoneType]()


def should_close() -> Int32:
    """mojoui_should_close() -> int. 1 if user clicked X or
    request_close() was called, else 0."""
    return external_call["mojoui_should_close", Int32]()


def poll_events():
    """mojoui_poll_events(). No-op for ABI symmetry; sapp's own pump
    drains events. Exposed so future backends without sapp can plug in."""
    external_call["mojoui_poll_events", NoneType]()


def get_window_width() -> Int32:
    """mojoui_get_window_width() -> int. Current backbuffer width in px."""
    return external_call["mojoui_get_window_width", Int32]()


def get_window_height() -> Int32:
    """mojoui_get_window_height() -> int. Current backbuffer height in px."""
    return external_call["mojoui_get_window_height", Int32]()


def get_mouse_x() -> Int32:
    """mojoui_get_mouse_x() -> int. Mouse X (pixels, from window top-left)."""
    return external_call["mojoui_get_mouse_x", Int32]()


def get_mouse_y() -> Int32:
    """mojoui_get_mouse_y() -> int. Mouse Y."""
    return external_call["mojoui_get_mouse_y", Int32]()


def get_mouse_button(button: Int32) -> Int32:
    """mojoui_get_mouse_button(button) -> int. 1 if pressed.
    `button` is one of MOJOUI_BTN_LEFT/RIGHT/MIDDLE."""
    return external_call["mojoui_get_mouse_button", Int32](button)


def get_key(mojoui_key: Int32) -> Int32:
    """mojoui_get_key(mojoui_key) -> int. 1 if pressed.
    `mojoui_key` is one of the MOJOUI_KEY_* constants (NOT a raw sapp code)."""
    return external_call["mojoui_get_key", Int32](mojoui_key)


def get_input_text() -> UnsafePointer[Int8, MutAnyOrigin]:
    """mojoui_get_input_text() -> const char*. NUL-terminated UTF-8 buffer
    of chars typed this frame. The pointer aliases C-side static storage —
    do not free; copy out before calling clear_input_text()."""
    return external_call[
        "mojoui_get_input_text", UnsafePointer[Int8, MutAnyOrigin]
    ]()


def input_text_length() -> Int32:
    """mojoui_input_text_length() -> int. Byte length of input text buffer."""
    return external_call["mojoui_input_text_length", Int32]()


def clear_input_text():
    """mojoui_clear_input_text(). Drain after consumption."""
    external_call["mojoui_clear_input_text", NoneType]()


def set_user_data(ptr: UnsafePointer[NoneType, MutAnyOrigin]):
    """mojoui_set_user_data(ptr). Stash an opaque pointer in a C-side static
    slot so a no-arg sokol_app frame callback can recover per-frame state.

    Solves the c10/c18 "module-level state for frame callbacks" wall: current
    beta Mojo rejects module-level `var` AND cannot materialise capturing
    closures as runtime function pointers, so the only way to thread mutable
    state from `main()` into the no-arg `void (*frame_fn)(void)` invoked by
    sapp_run is through this 2-symbol C extension. The pointer's lifetime is
    the CALLER's responsibility — typically a stack-allocated `AppState`
    struct in `main()` lives for the entire `Backend.run_blocking` window.
    NULL is a valid stored value (initial state, and the "no state attached"
    sentinel).

    Prefer the typed wrapper `mojoui.app.state.store_user_state[T](ptr)` over
    direct calls — it bit-casts a typed `UnsafePointer[T, MutAnyOrigin]` into
    the opaque pointer expected by this FFI without manual `.bitcast`.
    """
    external_call["mojoui_set_user_data", NoneType](ptr)


def get_user_data() -> UnsafePointer[NoneType, MutAnyOrigin]:
    """mojoui_get_user_data() -> void*. Recover the previously-stored opaque
    pointer (NULL if `set_user_data` was never called).

    Prefer the typed wrapper `mojoui.app.state.retrieve_user_state[T]()` over
    direct calls — it bit-casts the returned opaque pointer back to
    `UnsafePointer[T, MutAnyOrigin]` for ergonomic typed deref.
    """
    return external_call[
        "mojoui_get_user_data", UnsafePointer[NoneType, MutAnyOrigin]
    ]()


# ============================================================
# Section 2 — GPU 2D Rendering (7 fns, c_floor/mojoui_render.c)
# ============================================================

def render_init() -> Int32:
    """mojoui_render_init() -> int. sg_setup, default pipeline, 1×1 white
    fallback texture (id=0), dynamic vertex+index buffers (stream usage).
    Returns 0 on success."""
    return external_call["mojoui_render_init", Int32]()


def render_shutdown():
    """mojoui_render_shutdown(). Tears down sg + caches."""
    external_call["mojoui_render_shutdown", NoneType]()


def frame_begin(clear_r: Int32, clear_g: Int32, clear_b: Int32, clear_a: Int32):
    """mojoui_frame_begin(r, g, b, a). Begins default pass with clear color
    (0-255). Applies u_screen_size uniform."""
    external_call["mojoui_frame_begin", NoneType](
        clear_r, clear_g, clear_b, clear_a
    )


def frame_end():
    """mojoui_frame_end(). sg_end_pass + sg_commit (present)."""
    external_call["mojoui_frame_end", NoneType]()


def draw_batch(
    verts: UnsafePointer[Float32, MutAnyOrigin],
    n_verts: Int32,
    indices: UnsafePointer[UInt16, MutAnyOrigin],
    n_indices: Int32,
    texture_id: UInt32,
):
    """mojoui_draw_batch(verts, n_verts, indices, n_indices, texture_id).

    Vertex stride: 20 bytes = 5 floats per vertex (x, y, u, v, color_bits).
    The 5th "float" is a 0xAABBGGRR uint32 bit-reinterpreted (memcpy
    trick); the sokol pipeline reads attribute 2 at offset 16 as
    SG_VERTEXFORMAT_UBYTE4N. texture_id=0 → built-in 1×1 white texture
    (for untextured colored geometry)."""
    external_call["mojoui_draw_batch", NoneType](
        verts, n_verts, indices, n_indices, texture_id
    )


def make_texture(
    width: Int32, height: Int32, rgba_pixels: UnsafePointer[UInt8, MutAnyOrigin]
) -> UInt32:
    """mojoui_make_texture(w, h, rgba) -> uint32. Returns sg_image id as
    plain uint32. ID 0 is reserved for the built-in white texture."""
    return external_call["mojoui_make_texture", UInt32](
        width, height, rgba_pixels
    )


def destroy_texture(texture_id: UInt32):
    """mojoui_destroy_texture(texture_id)."""
    external_call["mojoui_destroy_texture", NoneType](texture_id)


# ============================================================
# Section 3 — Font Atlas + Text (5 fns, c_floor/mojoui_fonts.c)
# ============================================================

def load_font(path: String) -> UInt32:
    """mojoui_load_font(path) -> uint32_t font_id. Returns ≥1 on success,
    0 on error. Empty string ("") triggers default search through
    Inter / JetBrainsMono / Roboto / SF Pro / DejaVu / Liberation paths.

    Note: the C ABI accepts NULL for default search; Mojo's String type
    cannot directly produce a NULL char*, so we pass an empty string and
    rely on the C side treating both NULL and "" as the default-search
    trigger (mojoui_fonts.c does exactly that)."""
    return external_call["mojoui_load_font", UInt32](path.unsafe_ptr())


def destroy_font(font_id: UInt32):
    """mojoui_destroy_font(font_id). Frees TTF buffer + GPU atlas textures."""
    external_call["mojoui_destroy_font", NoneType](font_id)


def text_width(font_id: UInt32, size_pt: Int32, text: String) -> Int32:
    """mojoui_text_width(font_id, size_pt, text, text_len) -> int. Pixel
    width. ASCII only (bytes 32..126); others silently skipped. `text_len`
    is passed explicitly — Mojo's String is not reliably NUL-terminated at
    unsafe_ptr(), so the C side must be told the byte count."""
    return external_call["mojoui_text_width", Int32](
        font_id, size_pt, text.unsafe_ptr(), Int32(text.byte_length())
    )


def text_height(font_id: UInt32, size_pt: Int32) -> Int32:
    """mojoui_text_height(font_id, size_pt) -> int. Line height =
    scale * (ascent - descent + line_gap)."""
    return external_call["mojoui_text_height", Int32](font_id, size_pt)


def draw_text(
    font_id: UInt32,
    size_pt: Int32,
    text: String,
    x: Int32,
    y: Int32,
    r: Int32,
    g: Int32,
    b: Int32,
    a: Int32,
) -> Int32:
    """mojoui_draw_text(font_id, size_pt, text, text_len, x, y, r, g, b, a)
    -> int.

    Position (x, y) = baseline-left. Emits one mojoui_draw_batch per call
    (≤1024 chars). \\n advances pen.y, resets pen.x. Returns 1 on success.
    `text_len` is passed explicitly — Mojo's String is not reliably
    NUL-terminated at unsafe_ptr(), so the C side is bounded by byte count
    (fixes stale-glyph text bleed)."""
    return external_call["mojoui_draw_text", Int32](
        font_id, size_pt, text.unsafe_ptr(), Int32(text.byte_length()),
        x, y, r, g, b, a
    )
