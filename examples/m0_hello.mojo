"""MojoUI M0 demo - 800x600 window with centered rect + 'Hello, MojoUI'.

Run via:
    cd /home/alex/MojoUI && pixi run hello
or
    cd /home/alex/MojoUI && LD_LIBRARY_PATH=. pixi run mojo run -I . examples/m0_hello.mojo

M0 gate (runtime verification, currently deferred — GPU is busy):
  * Window opens at 800x600 titled 'MojoUI M0 Hello'.
  * Background = RGB(24, 24, 28) dark gray.
  * Centered 320x140 purple-ish rectangle visible.
  * 'Hello, MojoUI' text rendered at 24pt centered on top of the rect.
  * 60fps for 10s on Linux+OpenGL (GLCORE backend).
  * Closes cleanly on window-X click (no leaks).

Static gate (covered by `pixi run mojo build --emit object` + the regression
tests `test-types`, `test-ffi`, `test-backend`): the file compiles cleanly,
uses only the Backend API (no direct `external_call` to mojoui_*), and the
frame callback respects sokol_app's `void (*)(void)` contract.

Two integration notes (both documented at length in
/home/alex/mojoui-audit/MOJO_NOTES.md):

1. render_init timing (case B fix): `mojoui_render_init` needs a live GL
   context via `sglue_environment()`, which only exists after sokol_app
   creates the window inside its own init callback. The fix (applied in
   chunk 10) is that `platform_init_cb` in `c_floor/mojoui_platform.c`
   calls `mojoui_render_init()` itself, so `Backend.init` only fills the
   sapp_desc and the render subsystem comes up automatically the moment
   `run_blocking` enters `sapp_run`.

2. font_id without module-level var: the skeleton uses
   `var g_font_id` at module scope to share state between `main()` and
   the no-arg `_frame()` callback, but current Mojo beta REJECTS
   module-level `var`. Workaround: the first successful
   `mojoui_load_font(NULL_or_empty)` ALWAYS returns slot 0 + 1 = 1 (see
   `c_floor/mojoui_fonts.c:248` onward), so the demo uses a
   `comptime FONT_ID = 1` constant. main() asserts the load returned
   that exact id before entering run_blocking.
"""

from mojoui.render.backend import Backend
from mojoui.core.types import Vec2, Rect, Color


# Window + theme constants (compile-time, no module-level var allowed).
comptime WINDOW_W: Int32 = 800
comptime WINDOW_H: Int32 = 600
comptime FONT_SIZE: Int32 = 24

# Deterministic from the C-floor font registry: the first successful
# `mojoui_load_font("")` always returns slot 0 + 1 = 1. main() asserts the
# load succeeded before run_blocking; the frame callback can reference this
# constant directly. See the module docstring "font_id without module-level
# var" note for the full reasoning.
comptime FONT_ID: UInt32 = 1


def _frame():
    """Per-frame callback invoked by sokol_app via Backend.run_blocking.

    Must be a zero-arg, non-raising `def` — sokol's `void (*)(void)` contract.
    State (font_id, window size, theme constants) comes from `comptime`
    constants or per-frame Backend queries; module-level `var` is not
    available in current beta Mojo (see module docstring).
    """
    # 1. Background clear (dark gray = RGB 24,24,28).
    var bg = Color(UInt8(24), UInt8(24), UInt8(28), UInt8(255))
    Backend.frame_begin(bg)

    # 2. Centered accent rectangle (320x140, purple-ish, slightly translucent).
    var rect_w: Float32 = 320.0
    var rect_h: Float32 = 140.0
    var win = Backend.window_size()
    var rx = (win.x - rect_w) * 0.5
    var ry = (win.y - rect_h) * 0.5
    var rect = Rect(rx, ry, rect_w, rect_h)
    var rect_color = Color(UInt8(60), UInt8(50), UInt8(110), UInt8(230))
    Backend.draw_rect(rect, rect_color)

    # 3. Centered "Hello, MojoUI" text at 24pt, light foreground on top of
    #    the rect. Backend.text_width/text_height return Int32 pixels;
    #    convert via Int64 then Float32 for the Vec2 (Backend.draw_text
    #    truncates back to Int32 internally for the pixel-perfect baseline).
    var label = String("Hello, MojoUI")
    var tw = Backend.text_width(FONT_ID, FONT_SIZE, label)
    var th = Backend.text_height(FONT_ID, FONT_SIZE)
    # Baseline-Y is conventionally the LOWER edge of the glyph cap-height
    # row, so centering vertically means y = (win.y + th) / 2  (push the
    # baseline below the centerline by half the ascent).
    var tx = (Int32(Int(win.x)) - tw) // Int32(2)
    var ty = (Int32(Int(win.y)) + th) // Int32(2)
    var text_color = Color(UInt8(225), UInt8(225), UInt8(235), UInt8(255))
    var pos = Vec2(Float32(Int(tx)), Float32(Int(ty)))
    _ = Backend.draw_text(FONT_ID, FONT_SIZE, label, pos, text_color)

    # 4. Commit the frame (sg_end_pass + sg_commit).
    Backend.frame_end()


def main() raises:
    """Open the window, load the font, enter the blocking event loop.

    Flow:
        1. Backend.init  - fills sapp_desc; returns 0 on success.
        2. Backend.load_font("")  - default search (DejaVu/Inter/...); returns
           font_id >= 1, MUST equal FONT_ID=1 because the registry is empty
           at this point.
        3. Backend.run_blocking(_frame)  - enters sapp_run, which:
             (a) creates GL context,
             (b) invokes platform_init_cb -> mojoui_render_init (sg_setup),
             (c) loops: invokes platform_frame_cb -> _frame() per frame,
             (d) on close, invokes platform_cleanup_cb and returns.
        4. Backend.destroy_font + shutdown for tidy teardown.

    The runtime gate (window opens, 60fps for 10s, AA Hello visible, clean
    close, no leaks) is DEFERRED to the user — GPU is busy in this build
    environment. Static gates (compile clean, no direct FFI, all regression
    tests still pass) cover what can be verified without a display.
    """
    var rc = Backend.init(WINDOW_W, WINDOW_H, String("MojoUI M0 Hello"))
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    var fid = Backend.load_font(String(""))
    if fid == 0:
        print("FAIL: Backend.load_font returned 0 (no fallback font found)")
        raise Error("font load failed")
    if fid != FONT_ID:
        # Should never happen on a fresh C-floor: empty registry guarantees
        # slot 0 + 1 = 1. If we get here, somebody else loaded a font first
        # (impossible in this demo) or the registry contract changed.
        print(
            "FAIL: expected first font_id == ", FONT_ID, "got", fid,
            " — registry contract violated.",
        )
        raise Error("font_id mismatch")

    # Blocks until the user closes the window (or _frame calls
    # Backend.request_close, which this demo never does).
    Backend.run_blocking(_frame)

    # Teardown — sapp has already torn the window down by the time we
    # reach here; just release Mojo-side resources.
    Backend.destroy_font(FONT_ID)
    Backend.shutdown()
    print("PASS: m0_hello exited cleanly")
