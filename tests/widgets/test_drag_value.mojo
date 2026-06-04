"""Smoke tests for `mojoui/widgets/drag_value.mojo`.

Run: `pixi run test-drag-value`

Verifies the egui-style DragValue widget (M2 c22):
  - No drag: value unchanged, returns False.
  - Press + mouse_delta.x = +5.0, speed=1.0: value += 5.0, returns True.
  - Press + mouse_delta.x = -3.0, speed=2.0: value -= 6.0, returns True.
  - Release: drag stops, next frame's value is stable (no delta consumed).

JIT note (same as `tests/widgets/test_basic.mojo`): we use
`Context.begin_frame_no_input(window_size, mouse_pos, pressed, released)` to
bypass the FFI input poll (`mojo run` does not auto-dlopen
`libmojoui_floor.so` — see Mojo implementation notes "mojo run (JIT) does NOT dlopen the
shared library"). `mouse_delta` is normally set by `InputState.poll()` as
`mouse_pos - prev_mouse_pos`; in tests we set it directly on
`ctx.input.mouse_delta` AFTER `begin_frame_no_input` returns, simulating one
frame's worth of mouse motion.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, IMM_ID_NONE, hash_str
from mojoui.core.context import Context
from mojoui.core.control import CTRL_ACTIVE
from mojoui.widgets.drag_value import drag_value


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _abs(x: Float32) -> Float32:
    """Manual abs for Float32 epsilon checks (Mojo stdlib's `abs` is not
    free-function-importable in current beta — same helper pattern as
    `tests/widgets/test_slider.mojo::_abs`)."""
    if x < 0.0:
        return -x
    return x


def _approx_eq(a: Float32, b: Float32) -> Bool:
    """Epsilon-based Float32 equality (replaces exact `!=` checks per M2-bugfix
    2026-05-28 FRAGILE #5 — brittle to ULP-scale rounding from future
    intermediate computations). 1e-5 tolerance is plenty for the integer-
    arithmetic values used in these tests."""
    return _abs(a - b) <= 1.0e-5


# ----------------------------------------------------------------------------
# Helper — begin a frame with a single 200×24 layout row at (0,0), then patch
# in the requested mouse_delta (simulating one frame's worth of motion).
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
    mouse_delta_x: Float32,
) raises:
    """Begin a frame on `ctx`: 800×600 window, single 200-wide × 24-tall row
    at the top-left, mouse at `mouse_pos`, LMB edges as given, mouse_delta.x
    set to `mouse_delta_x` (and delta.y to 0). After this call, the next
    `layout_next()` returns Rect(0, 0, 200, 24)."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    # Patch in the simulated mouse motion. `begin_frame_no_input` does not
    # touch `ctx.input.mouse_delta` (only `begin_frame` does, via `poll()`).
    ctx.input.mouse_delta = Vec2(mouse_delta_x, 0.0)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_no_drag_no_change() raises:
    """Test 1: mouse far away from the widget, no edges, no delta.
    Expect: value unchanged, returns False."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0)
    var v: Float32 = 42.0
    var changed = drag_value(ctx, v, String("x"), 1.0)
    if changed:
        _fail("no-drag should return False")
    if not _approx_eq(v, 42.0):
        _fail("no-drag should leave value unchanged")


def test_hover_only_no_change() raises:
    """Test 2: mouse INSIDE the rect but no press, no delta.
    Expect: value unchanged, returns False. Hover does not scrub."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), False, False, 5.0)
    var v: Float32 = 10.0
    var changed = drag_value(ctx, v, String("y"), 1.0)
    if changed:
        _fail("hover-only (no press) should not scrub")
    if not _approx_eq(v, 10.0):
        _fail("hover-only should leave value unchanged")


def test_drag_positive_speed_1() raises:
    """Test 3: press-inside + mouse_delta.x = +5.0, speed = 1.0.
    Expect: value += 5.0, returns True. The press frame's `update_control`
    sets CTRL_ACTIVE (press grants active), so the active-gated behavior
    branch fires on this same frame."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, 5.0)
    var v: Float32 = 100.0
    var changed = drag_value(ctx, v, String("z"), 1.0)
    if not changed:
        _fail("press + non-zero delta should return True")
    if not _approx_eq(v, 105.0):
        _fail("press + delta=5.0, speed=1.0 should set value to 105.0")


def test_drag_negative_speed_2() raises:
    """Test 4: press-inside + mouse_delta.x = -3.0, speed = 2.0.
    Expect: value -= 6.0 (== -3 * 2), returns True."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, -3.0)
    var v: Float32 = 50.0
    var changed = drag_value(ctx, v, String("w"), 2.0)
    if not changed:
        _fail("press + non-zero delta should return True")
    if not _approx_eq(v, 44.0):
        _fail("press + delta=-3.0, speed=2.0 should set value to 44.0 (got something else)")


def test_release_stops_drag() raises:
    """Test 5: three-frame sequence proving drag stops after release.
    Frame 1 — press-inside + delta=+2.0 → value += 2.0, returns True (active claimed).
    Frame 2 — release-inside + delta=+1.0 → CTRL_ACTIVE is STILL set in this
              same tick (control SM clears active in `end_frame`, NOT in
              `update_control` — release-inside-active emits CTRL_RELEASED
              alongside CTRL_ACTIVE this frame), so this last-tick delta is
              still consumed. value += 1.0, returns True.
    Frame 3 — post-release + delta=+99.0 → end_frame on frame 2 cleared
              active, so this frame sees no CTRL_ACTIVE → delta discarded,
              value stable, returns False. This is the "drag really is over"
              invariant — once the mouse button is up, the next frame's
              motion does NOT scrub."""
    var ctx = Context()
    # Frame 1 — press grants active, delta consumed.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, 2.0)
    var v: Float32 = 0.0
    var f1_changed = drag_value(ctx, v, String("k"), 1.0)
    if not f1_changed:
        _fail("frame 1 (press + delta) should return True")
    if not _approx_eq(v, 2.0):
        _fail("frame 1: value should be 2.0 after delta=+2.0")
    ctx.end_frame()
    # Frame 2 — release-inside. `update_control` reports CTRL_ACTIVE this
    # tick (active still == id; the SM clears active in `end_frame`), so
    # the +1.0 delta IS consumed. CTRL_RELEASED is also set this frame.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, True, 1.0)
    var f2_changed = drag_value(ctx, v, String("k"), 1.0)
    if not f2_changed:
        _fail("frame 2 (release-inside-active) should still consume final delta")
    if not _approx_eq(v, 3.0):
        _fail("frame 2: value should be 3.0 after final +1.0 delta")
    ctx.end_frame()
    # Frame 3 — drag is fully over. `end_frame` on frame 2 cleared active;
    # this frame's update_control reports neither CTRL_ACTIVE nor
    # CTRL_PRESSED, so the huge delta is discarded.
    _make_ctx(ctx, Vec2(10.0, 10.0), False, False, 99.0)
    var f3_changed = drag_value(ctx, v, String("k"), 1.0)
    if f3_changed:
        _fail("frame 3 (post-release) should NOT scrub — drag is over")
    if not _approx_eq(v, 3.0):
        _fail("frame 3: value should remain 3.0 (drag fully stopped)")
    ctx.end_frame()


def test_id_is_stable_per_id_str() raises:
    """Test 6: two drag_value calls with different id_str get different IDs
    (so they hover/focus/active independently). Smoke check the same way
    test_basic.py does it for button."""
    var ctx = Context()
    # 2-column row of 200 each; mouse over the FIRST column.
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), Vec2(10.0, 10.0), False, False)
    ctx.input.mouse_delta = Vec2(0.0, 0.0)
    var widths = List[Int32]()
    widths.append(200)
    widths.append(200)
    ctx.layout_row(widths^, 24)
    var v1: Float32 = 1.0
    var v2: Float32 = 2.0
    var _ = drag_value(ctx, v1, String("a"), 1.0)
    var _ = drag_value(ctx, v2, String("b"), 1.0)
    var id_a = hash_str(String("a"))
    var id_b = hash_str(String("b"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'a' and 'b' should hash to different IDs")
    if UInt32(ctx.control.hover) != UInt32(id_a):
        _fail("hover should be 'a' (mouse is in a's rect)")


def test_drag_emits_draw_commands() raises:
    """Test 7: drag_value emits at least one draw command (bg rect + value
    text) per call. Bumps the command buffer size and advances layout."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0)
    var before_bytes = ctx.commands.byte_count()
    var before_max_y = Int(ctx.layout.frames[0].max_y)
    var v: Float32 = 3.14
    var _ = drag_value(ctx, v, String("pi"), 0.01)
    var after_bytes = ctx.commands.byte_count()
    var after_max_y = Int(ctx.layout.frames[0].max_y)
    if after_bytes <= before_bytes:
        _fail("drag_value should emit at least one draw command")
    if after_max_y <= before_max_y:
        _fail("drag_value should advance layout max_y past row height")


def main() raises:
    test_no_drag_no_change()
    test_hover_only_no_change()
    test_drag_positive_speed_1()
    test_drag_negative_speed_2()
    test_release_stops_drag()
    test_id_is_stable_per_id_str()
    test_drag_emits_draw_commands()
    print("PASS: drag_value smoke tests (7 tests)")
