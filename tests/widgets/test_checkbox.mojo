"""Smoke tests for `mojoui/widgets/checkbox.mojo`.

Run: `pixi run test-checkbox`

Exercises the boolean-toggle checkbox widget end-to-end through Context →
LayoutStack → ControlState → CommandBuffer. Mirrors the c17 test_basic.mojo
patterns: `begin_frame_no_input` to bypass FFI poll (JIT-safe), a single
row of fixed width as the layout slot, and `.copy()` discipline at every
Vec2/Rect read.

Test matrix:
  1. checkbox reserves a layout slot + emits draw commands.
  2. value=False + no click → returns False, value still False.
  3. press+release inside (2-frame sequence) flips False → True, returns True.
  4. press+release inside flips True → False, returns True.
  5. two checkboxes with different labels get different IDs (independent
     toggle state through `mut value` refs).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, IMM_ID_NONE, hash_str
from mojoui.core.context import Context
from mojoui.widgets.checkbox import checkbox


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — same shape as tests/widgets/test_basic.mojo::_make_ctx.
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Begin a frame with a 1-column row of width 200, height 24.

    After this call the next `layout_next()` returns Rect(0, 0, 200, 24).
    The checkbox 16×16 box lives at x=padding (6), y=4, so any mouse position
    inside the 200×24 rect counts as "inside the click target".
    """
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def _make_ctx_two_cols(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Two-column row of width 200 each."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_checkbox_reserves_slot_and_emits_commands() raises:
    """Test 1: checkbox("Enabled", False) with mouse far away — advances
    layout cursor and emits draw commands (box bg + 4 border rects + label).
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var before_bytes = ctx.commands.byte_count()
    var value: Bool = False
    var changed = checkbox(ctx, String("Enabled"), value)
    var after_bytes = ctx.commands.byte_count()
    if changed:
        _fail("checkbox should NOT report change when mouse is far away")
    if value:
        _fail("value should remain False when no click happened")
    if after_bytes <= before_bytes:
        _fail("checkbox should emit at least one draw command")
    # Layout advanced past slot height.
    if Int(ctx.layout.frames[0].max_y) < 24:
        _fail("checkbox should bump layout max_y past 24 (slot height)")


def test_checkbox_value_false_no_click_no_change() raises:
    """Test 2: value=False, mouse OUTSIDE the rect, no press/release —
    returns False, value stays False."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var value: Bool = False
    var changed = checkbox(ctx, String("Opt"), value)
    if changed:
        _fail("no interaction should not report changed")
    if value:
        _fail("no interaction should leave value untouched")


def test_checkbox_false_to_true_on_click() raises:
    """Test 3: simulate the click sequence across two frames.

    Frame 1 — press-inside (control claims active, value still False).
    Frame 2 — release-inside (value flips False → True, returns True).
    """
    var ctx = Context()
    var value: Bool = False
    # Frame 1: mouse-down inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var f1_changed = checkbox(ctx, String("Toggle"), value)
    if f1_changed:
        _fail("frame 1 (press only) should not report changed")
    if value:
        _fail("frame 1 (press only) should not yet flip value")
    ctx.end_frame()
    # Frame 2: mouse-up inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2_changed = checkbox(ctx, String("Toggle"), value)
    if not f2_changed:
        _fail("frame 2 (release-inside) should report changed == True")
    if not value:
        _fail("frame 2 (release-inside) should flip value False → True")
    ctx.end_frame()


def test_checkbox_true_to_false_on_click() raises:
    """Test 4: same sequence but starting from value=True — click flips
    True → False, returns True."""
    var ctx = Context()
    var value: Bool = True
    # Frame 1: press inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False)
    var f1_changed = checkbox(ctx, String("Toggle"), value)
    if f1_changed:
        _fail("frame 1 (press only) should not report changed")
    if not value:
        _fail("frame 1 (press only) should leave value True")
    ctx.end_frame()
    # Frame 2: release inside.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True)
    var f2_changed = checkbox(ctx, String("Toggle"), value)
    if not f2_changed:
        _fail("frame 2 (release-inside) should report changed == True")
    if value:
        _fail("frame 2 (release-inside) should flip value True → False")
    ctx.end_frame()


def test_two_checkboxes_have_different_ids() raises:
    """Test 5: checkbox(ctx, "A", a) and checkbox(ctx, "B", b) in the same
    frame get different ImmediateIds, so they hover/focus/active and toggle
    independently.

    Setup: 2-column row of (200, 200), mouse over the FIRST checkbox's
    rect. Click sequence flips ONLY the first checkbox's value.
    """
    var ctx = Context()
    var a: Bool = False
    var b: Bool = False
    # Frame 1: press inside A (mouse at (10,10), inside first column).
    _make_ctx_two_cols(ctx, Vec2(10.0, 10.0), True, False)
    var _f1a = checkbox(ctx, String("A"), a)
    var _f1b = checkbox(ctx, String("B"), b)
    ctx.end_frame()
    # Frame 2: release inside A.
    _make_ctx_two_cols(ctx, Vec2(10.0, 10.0), False, True)
    var f2a = checkbox(ctx, String("A"), a)
    var f2b = checkbox(ctx, String("B"), b)
    ctx.end_frame()
    # A should have toggled; B should not.
    if not f2a:
        _fail("checkbox A should report changed on click")
    if f2b:
        _fail("checkbox B should NOT report changed (mouse not in B)")
    if not a:
        _fail("checkbox A's value should flip False → True")
    if b:
        _fail("checkbox B's value should remain False (independent state)")
    # Sanity: their IDs differ.
    var id_a = hash_str(String("A"))
    var id_b = hash_str(String("B"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'A' and 'B' should hash to different IDs")


def main() raises:
    test_checkbox_reserves_slot_and_emits_commands()
    test_checkbox_value_false_no_click_no_change()
    test_checkbox_false_to_true_on_click()
    test_checkbox_true_to_false_on_click()
    test_two_checkboxes_have_different_ids()
    print("PASS: checkbox widget smoke tests (5 tests)")
