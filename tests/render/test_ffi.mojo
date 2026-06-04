"""FFI smoke test for mojoui.render.ffi.

Verifies (statically, without opening a window — GPU may be busy):
  1) MOJOUI_KEY_* / MOJOUI_BTN_* constants match the C enum values exactly.
  2) Every wrapper function symbol imports successfully (catches typos in
     the external_call name and signature mismatches at module-load time).
  3) The function-pointer FFI for run_blocking accepts a Mojo `fn() -> None`
     parameter type — compile-only proof; we do NOT actually invoke it
     since that would block on sapp_run.

Run: cd /home/alex/MojoUI && LD_LIBRARY_PATH=. pixi run mojo run -I . tests/render/test_ffi.mojo
"""

from mojoui.render.ffi import (
    MOJOUI_KEY_UNKNOWN,
    MOJOUI_KEY_BACKSPACE,
    MOJOUI_KEY_RETURN,
    MOJOUI_KEY_ESCAPE,
    MOJOUI_KEY_SPACE,
    MOJOUI_KEY_RSUPER,
    MOJOUI_KEY_A,
    MOJOUI_KEY_Z,
    MOJOUI_KEY_0,
    MOJOUI_KEY_9,
    MOJOUI_KEY_F1,
    MOJOUI_KEY_F12,
    MOJOUI_KEY_COUNT,
    MOJOUI_BTN_LEFT,
    MOJOUI_BTN_RIGHT,
    MOJOUI_BTN_MIDDLE,
    # Section 1 — Window + Input
    init_window,
    run_blocking,
    request_close,
    should_close,
    poll_events,
    get_window_width,
    get_window_height,
    get_mouse_x,
    get_mouse_y,
    get_mouse_button,
    get_key,
    get_input_text,
    input_text_length,
    clear_input_text,
    # Section 2 — GPU 2D Rendering
    render_init,
    render_shutdown,
    frame_begin,
    frame_end,
    draw_batch,
    make_texture,
    destroy_texture,
    # Section 3 — Font Atlas + Text
    load_font,
    destroy_font,
    text_width,
    text_height,
    draw_text,
)


def _expect_eq(name: String, got: Int32, want: Int32) raises:
    if got != want:
        print("FAIL:", name, "expected", want, "got", got)
        raise Error("constant mismatch")


def test_key_constants() raises:
    _expect_eq("MOJOUI_KEY_UNKNOWN", MOJOUI_KEY_UNKNOWN, 0)
    _expect_eq("MOJOUI_KEY_BACKSPACE", MOJOUI_KEY_BACKSPACE, 1)
    _expect_eq("MOJOUI_KEY_RETURN", MOJOUI_KEY_RETURN, 3)
    _expect_eq("MOJOUI_KEY_ESCAPE", MOJOUI_KEY_ESCAPE, 5)
    _expect_eq("MOJOUI_KEY_SPACE", MOJOUI_KEY_SPACE, 6)
    _expect_eq("MOJOUI_KEY_RSUPER", MOJOUI_KEY_RSUPER, 22)
    _expect_eq("MOJOUI_KEY_A", MOJOUI_KEY_A, 23)
    _expect_eq("MOJOUI_KEY_Z", MOJOUI_KEY_Z, 48)
    _expect_eq("MOJOUI_KEY_0", MOJOUI_KEY_0, 49)
    _expect_eq("MOJOUI_KEY_9", MOJOUI_KEY_9, 58)
    _expect_eq("MOJOUI_KEY_F1", MOJOUI_KEY_F1, 59)
    _expect_eq("MOJOUI_KEY_F12", MOJOUI_KEY_F12, 70)
    _expect_eq("MOJOUI_KEY_COUNT", MOJOUI_KEY_COUNT, 96)


def test_btn_constants() raises:
    _expect_eq("MOJOUI_BTN_LEFT", MOJOUI_BTN_LEFT, 0)
    _expect_eq("MOJOUI_BTN_RIGHT", MOJOUI_BTN_RIGHT, 1)
    _expect_eq("MOJOUI_BTN_MIDDLE", MOJOUI_BTN_MIDDLE, 2)


def _frame_noop():
    """Trivial Mojo callback used to prove fn() -> None type-checks as a
    valid argument to run_blocking. NOT actually invoked here — that would
    require opening a window and entering the sapp loop."""
    pass


def test_callback_type():
    """Compile-only proof: passing a Mojo callback to run_blocking
    type-checks. We do NOT actually call sapp_run — the call below is
    gated by a runtime False (escaped past Mojo's always-False folding
    via a never-zero arg) so the type checker still sees the call but
    sapp_run is never entered."""
    var never = Int(MOJOUI_KEY_COUNT) - 96  # always 0, but not literal-False
    if never != 0:
        run_blocking(_frame_noop)


def main() raises:
    test_key_constants()
    test_btn_constants()
    test_callback_type()
    print("PASS: ffi smoke (constants + import resolution + callback type)")
