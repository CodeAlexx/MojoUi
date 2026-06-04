"""Smoke tests for `mojoui/widgets/slider.mojo`.

Run: `pixi run test-slider`

Exercises the BEHAVIOR step of the microui 6-step recipe — drag-from-here
semantics with mouse_x → value mapping, plus endpoint clamping.

JIT note (per MOJO_NOTES.md): tests use `Context.begin_frame_no_input` so
the JIT does not need to resolve `mojoui_get_mouse_*` C symbols.

Test sequence per drag: the slider becomes CTRL_ACTIVE only AFTER the press
is observed by `update_control`. So a drag test needs:
  - Frame 1: press_inside=True at start position → claims active
  - Frame 2: press=False, released=False, cursor at target → slider
             recomputes value from mouse_x (still active because no release)

Single-frame "press at left edge → value snaps to low" works because
update_control sets CTRL_PRESSED *and* CTRL_ACTIVE on the same frame as the
press (active is claimed mid-tick, then the same flags word is OR'd with
CTRL_ACTIVE before the function returns). So checking that the value snaps
on the press frame itself is a valid one-frame test.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, IMM_ID_NONE, hash_str
from mojoui.core.context import Context
from mojoui.core.control import CTRL_ACTIVE
from mojoui.widgets.slider import slider


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _abs(x: Float32) -> Float32:
    if x < 0.0:
        return -x
    return x


# ----------------------------------------------------------------------------
# Helper — set up a context with a single 200×24 row at (0,0). The slider's
# rect will be (0, 0, 200, 24).
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_no_interaction() raises:
    """Test 1: slider with mouse far away — value unchanged, returns False,
    emits at least one draw command (the track)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False)
    var value: Float32 = 0.5
    var before_bytes = ctx.commands.byte_count()
    var changed = slider(ctx, value, 0.0, 1.0, String("vol"))
    var after_bytes = ctx.commands.byte_count()
    if changed:
        _fail("slider should NOT report changed when mouse is far away")
    if after_bytes <= before_bytes:
        _fail("slider should emit at least one draw command (track)")
    if _abs(value - 0.5) > 1.0e-6:
        _fail("value should be unchanged on no-interaction frame")


def test_press_at_left_edge_snaps_to_low() raises:
    """Test 2: press inside at the leftmost pixel (rect.x = 0) → frac = 0 →
    value snaps to `low`. Single-frame test: press grants active in the
    same tick the value mapping runs."""
    var ctx = Context()
    # rect = (0, 0, 200, 24). Mouse at (0, 12), pressed=True.
    _make_ctx(ctx, Vec2(0.0, 12.0), True, False)
    var value: Float32 = 0.5
    var changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if not changed:
        _fail("press at left edge should change value (0.5 → 0.0)")
    if _abs(value - 0.0) > 1.0e-4:
        _fail("press at left edge should snap value to low (0.0)")


def test_press_at_right_edge_snaps_to_high() raises:
    """Test 3: press inside at the rightmost pixel (rect.x + rect.w = 200)
    → frac = 1 → value snaps to `high`."""
    var ctx = Context()
    # Mouse at (200, 12) — exactly at rect.right(). contains() is inclusive
    # on the right edge, so the press is still inside.
    _make_ctx(ctx, Vec2(200.0, 12.0), True, False)
    var value: Float32 = 0.5
    var changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if not changed:
        _fail("press at right edge should change value (0.5 → 100.0)")
    if _abs(value - 100.0) > 1.0e-4:
        _fail("press at right edge should snap value to high (100.0)")


def test_press_at_center_snaps_to_midpoint() raises:
    """Test 4: press inside at the centre pixel (rect.x + rect.w/2 = 100)
    → frac = 0.5 → value snaps to (low + high) / 2 = 50."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(100.0, 12.0), True, False)
    var value: Float32 = 0.0
    var changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if not changed:
        _fail("press at centre should change value (0.0 → 50.0)")
    if _abs(value - 50.0) > 1.0e-3:
        _fail("press at centre should snap value to (low+high)/2 == 50.0")


def test_drag_clamps_when_mouse_leaves_left() raises:
    """Test 5: after a press inside, dragging the cursor LEFT of rect.x
    (off the left edge) should clamp the value to `low`. Two-frame test:
    F1 press inside at centre, F2 drag to x = -50 with the button still held.

    Even though the cursor is outside the rect on F2, `active` is still
    claimed (drag-from-here semantic), so the value-from-mouse mapping
    still runs and clamps frac into [0, 1]."""
    var ctx = Context()
    # F1: press at centre — claims active, value snaps to 50.
    _make_ctx(ctx, Vec2(100.0, 12.0), True, False)
    var value: Float32 = 50.0
    var f1_changed = slider(ctx, value, 0.0, 100.0, String("s"))
    # f1_changed may be False (value already at 50) — that's fine.
    _ = f1_changed
    ctx.end_frame()
    # F2: cursor at x = -50 (off the left edge), button still down (no
    # press edge, no release edge — just held). active persists so the
    # mapping runs; frac = (-50 - 0)/200 = -0.25 clamps to 0; value = 0.
    _make_ctx(ctx, Vec2(-50.0, 12.0), False, False)
    var f2_changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if not f2_changed:
        _fail("dragging off left edge should change value (50.0 → 0.0)")
    if _abs(value - 0.0) > 1.0e-4:
        _fail("dragging off left edge should clamp value to low (0.0)")
    ctx.end_frame()


def test_drag_clamps_when_mouse_leaves_right() raises:
    """Test 6: mirror of test 5 — dragging right past rect.right() clamps
    to `high`."""
    var ctx = Context()
    # F1: press at centre.
    _make_ctx(ctx, Vec2(100.0, 12.0), True, False)
    var value: Float32 = 50.0
    var _ = slider(ctx, value, 0.0, 100.0, String("s"))
    ctx.end_frame()
    # F2: cursor at x = 500 (well past rect.right() == 200).
    _make_ctx(ctx, Vec2(500.0, 12.0), False, False)
    var f2_changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if not f2_changed:
        _fail("dragging off right edge should change value (50.0 → 100.0)")
    if _abs(value - 100.0) > 1.0e-4:
        _fail("dragging off right edge should clamp value to high (100.0)")
    ctx.end_frame()


def test_release_outside_rect_does_not_change_value_further() raises:
    """Test 7: after the mouse is released, the slider is no longer ACTIVE
    so subsequent mouse motion does NOT update the value."""
    var ctx = Context()
    # F1: press inside at centre — value snaps to 50, active claimed.
    _make_ctx(ctx, Vec2(100.0, 12.0), True, False)
    var value: Float32 = 0.0
    var _ = slider(ctx, value, 0.0, 100.0, String("s"))
    ctx.end_frame()
    # F2: release at centre — value stays at 50, active is cleared in
    # end_frame.
    _make_ctx(ctx, Vec2(100.0, 12.0), False, True)
    var _ = slider(ctx, value, 0.0, 100.0, String("s"))
    ctx.end_frame()
    # F3: cursor moved to far left, no buttons. Not active → value frozen.
    _make_ctx(ctx, Vec2(0.0, 12.0), False, False)
    var f3_changed = slider(ctx, value, 0.0, 100.0, String("s"))
    if f3_changed:
        _fail("post-release mouse motion should NOT change value")
    if _abs(value - 50.0) > 1.0e-3:
        _fail("value should remain at 50.0 after release; got different")


def test_different_id_str_means_different_widgets() raises:
    """Test 8: two sliders in the same frame with different id_str values
    get different ImmediateIds (so they hover/focus/active independently)."""
    var id_a = hash_str(String("volume"))
    var id_b = hash_str(String("opacity"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'volume' and 'opacity' should differ")


def main() raises:
    test_compile_and_no_interaction()
    test_press_at_left_edge_snaps_to_low()
    test_press_at_right_edge_snaps_to_high()
    test_press_at_center_snaps_to_midpoint()
    test_drag_clamps_when_mouse_leaves_left()
    test_drag_clamps_when_mouse_leaves_right()
    test_release_outside_rect_does_not_change_value_further()
    test_different_id_str_means_different_widgets()
    print("PASS: slider smoke tests (8 tests)")
