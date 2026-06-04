"""Smoke tests for `mojoui/widgets/basic.mojo`.

Run: `pixi run test-basic`

These tests exercise the FIRST real widget — the stub button — end-to-end
through Context → LayoutStack → ControlState → CommandBuffer. They also
verify `label` and `separator` reserve layout slots without claiming hover,
plus that two different buttons get different IDs (contextual hashing).

JIT note: same constraint as `tests/core/test_context.mojo` — we use
`Context.begin_frame_no_input(window_size, mouse_pos, pressed, released)`
to bypass the FFI poll (the JIT does not auto-dlopen `libmojoui_floor.so`).
Production widget calls (where `Backend.run_blocking` is in the call graph)
use the full `begin_frame` polling path; tests inject mouse state directly.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, IMM_ID_NONE, hash_str
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_FOCUSED, CTRL_ACTIVE
from mojoui.core.commands import CMD_TEXT, read_cmd_text
from mojoui.widgets.basic import button, label, separator


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — set up a context with a single 200×24 row at the top of an
# 800×600 window, so the first widget rect is (0,0,200,24).
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Begin a frame on `ctx` with a single 1-column row of width 200, height 24.

    After this call, the next `layout_next()` (which the widget will call
    internally) returns Rect(0, 0, 200, 24).

    Sets a non-zero font_id so widgets that draw text (button, label) emit
    CMD_TEXT — the FRAGILE #5 fix skips text draws when font_id == 0.
    """
    ctx.set_default_font(UInt32(1))
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_button_reserves_slot_and_emits_commands() raises:
    """Test 1: button("OK") with mouse far away — advances layout col_index
    and emits draw commands (background rect + 4 border rects + text)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var before_bytes = ctx.commands.byte_count()
    var clicked = button(ctx, String("OK"))
    var after_bytes = ctx.commands.byte_count()
    if clicked:
        _fail("button should NOT report click when mouse is far away")
    if after_bytes <= before_bytes:
        _fail("button should emit at least one draw command")
    # After the button, the layout should have advanced (a 1-col row of
    # width 200 wraps after the first slot, so col_index resets to 0; we
    # verify the wrap by checking that the row's max_y bumped past 24).
    # Direct frame[0].max_y read — Int32 is ImplicitlyCopyable, no .copy().
    if Int(ctx.layout.frames[0].max_y) < 24:
        _fail("button should bump layout max_y past 24 (slot height)")


def test_button_returns_false_when_no_mouse_interaction() raises:
    """Test 2: button with mouse OUTSIDE its rect, no press/release — False."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var clicked = button(ctx, String("Cancel"))
    if clicked:
        _fail("button without mouse-over should not click")


def test_button_returns_false_when_pressed_but_not_released() raises:
    """Test 3: mouse INSIDE the rect, pressed=True but released=False —
    button claims active/focus but does NOT report a click yet."""
    var ctx = Context()
    # Mouse at (10, 10) — well inside the 200×24 rect at (0,0).
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var clicked = button(ctx, String("Submit"))
    if clicked:
        _fail("button on press-only frame should not report click yet")
    # State sanity: control.active should be the button's id (press claimed it).
    var expected_id = hash_str(String("Submit"))
    if UInt32(ctx.control.active) != UInt32(expected_id):
        _fail("press-inside should grant active slot to the button")


def test_button_returns_true_on_release_frame() raises:
    """Test 4: simulate the click sequence across two frames.

    Frame 1 — press-inside (active gets claimed).
    Frame 2 — release-inside (button returns True).
    """
    var ctx = Context()
    # Frame 1: mouse-down inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var f1_clicked = button(ctx, String("Go"))
    if f1_clicked:
        _fail("frame 1 (press) should not report click")
    ctx.end_frame()
    # Frame 2: mouse-up inside. The control's `active` slot persisted from
    # frame 1 (end_frame did NOT clear it because no release happened);
    # release-while-active-and-still-over fires CTRL_RELEASED.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2_clicked = button(ctx, String("Go"))
    if not f2_clicked:
        _fail("frame 2 (release-inside) should report click == True")
    ctx.end_frame()


def test_two_buttons_get_different_ids() raises:
    """Test 5: button(ctx,"A") and button(ctx,"B") in the same frame get
    different ImmediateIds, so they hover/focus/active independently.

    Setup: 2-column row of (200, 200), mouse over the FIRST button.
    Expect: ctx.control.hover == hash_str("A"), NOT hash_str("B").
    """
    var ctx = Context()
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(10.0, 10.0), False, False)
    var widths = List[Int32]()
    widths.append(200)
    widths.append(200)
    ctx.layout_row(widths^, 24)
    var _ = button(ctx, String("A"))
    var _ = button(ctx, String("B"))
    var id_a = hash_str(String("A"))
    var id_b = hash_str(String("B"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'A' and 'B' should hash to different IDs")
    if UInt32(ctx.control.hover) != UInt32(id_a):
        _fail("hover should be A (mouse is in A's rect, not B's)")
    if UInt32(ctx.control.hover) == UInt32(id_b):
        _fail("hover should NOT be B")


def test_label_emits_command_but_no_interaction() raises:
    """Test 6: label("hi") emits a draw command but does NOT claim hover
    even with the cursor directly on top of it.

    A label has no `update_control` call — it can never grab hover.
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), False, False)
    var before = ctx.commands.byte_count()
    label(ctx, String("hi"))
    var after = ctx.commands.byte_count()
    if after <= before:
        _fail("label should emit a draw command")
    # hover was cleared by begin_frame_no_input → ControlState.begin_frame;
    # label does NOT call update_control, so hover must still be NONE.
    if UInt32(ctx.control.hover) != UInt32(IMM_ID_NONE):
        _fail("label should NEVER claim hover")
    if UInt32(ctx.control.focus) != UInt32(IMM_ID_NONE):
        _fail("label should NEVER claim focus")


def test_separator_emits_command_and_advances_layout() raises:
    """Test 7: separator emits a draw command and advances the layout
    cursor (so the next widget flows past it)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var before_bytes = ctx.commands.byte_count()
    var before_max_y = Int(ctx.layout.frames[0].max_y)
    separator(ctx)
    var after_bytes = ctx.commands.byte_count()
    var after_max_y = Int(ctx.layout.frames[0].max_y)
    if after_bytes <= before_bytes:
        _fail("separator should emit a draw command")
    if after_max_y <= before_max_y:
        _fail("separator should advance layout max_y")
    # Like label, separator should not claim hover even if cursor is in
    # the row's rect — we placed the mouse outside (500,500) just to be
    # symmetric with other tests.
    if UInt32(ctx.control.hover) != UInt32(IMM_ID_NONE):
        _fail("separator should NEVER claim hover")


def test_hover_only_no_click() raises:
    """Test 8: mouse INSIDE the rect, no press/release — button does NOT
    click but state.hover gets claimed."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), False, False)
    var clicked = button(ctx, String("Hover"))
    if clicked:
        _fail("hover-only (no press) should not click")
    var expected_id = hash_str(String("Hover"))
    if UInt32(ctx.control.hover) != UInt32(expected_id):
        _fail("hover-only should claim hover slot")
    # Focus and active should not have been granted.
    if UInt32(ctx.control.active) == UInt32(expected_id):
        _fail("hover-only should NOT claim active")


def test_bright_button_uses_dark_label_text() raises:
    """Test 9: bright primary fills must not draw unreadable white labels."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    ctx.theme.primary = Color(248, 255, 127, 255)
    var _ = button(ctx, String("Generate"))
    var off: Int32 = 0
    var found = False
    var total = Int32(ctx.commands.byte_count())
    while off < total:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_TEXT):
            var cmd = read_cmd_text(ctx.commands, off)
            if cmd.text == String("Generate"):
                found = True
                var yiq = Int(cmd.color.r) * 299 + Int(cmd.color.g) * 587 \
                    + Int(cmd.color.b) * 114
                if yiq >= 80000:
                    _fail("bright button label text should be dark")
        var step = ctx.commands.size_at(off)
        if step <= 0:
            _fail("command buffer walk saw non-positive command size")
        off = off + step
    if not found:
        _fail("button should emit Generate text command")


def main() raises:
    test_button_reserves_slot_and_emits_commands()
    test_button_returns_false_when_no_mouse_interaction()
    test_button_returns_false_when_pressed_but_not_released()
    test_button_returns_true_on_release_frame()
    test_two_buttons_get_different_ids()
    test_label_emits_command_but_no_interaction()
    test_separator_emits_command_and_advances_layout()
    test_hover_only_no_click()
    test_bright_button_uses_dark_label_text()
    print("PASS: basic widget smoke tests (9 tests)")
