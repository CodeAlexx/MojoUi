"""Smoke tests for `mojoui/widgets/scroll_area.mojo` — M2 chunk 28.

Run: `pixi run test-scroll-area`

Exercises `begin_scroll_area` / `end_scroll_area` end-to-end through Context
→ LayoutStack → ControlState → CommandBuffer. Mirrors the c22 (drag_value)
mouse_delta-patching test pattern — `begin_frame_no_input` to bypass FFI
poll, then we patch `ctx.input.mouse_delta` directly to simulate one frame's
worth of mouse motion.

Test matrix:
  1. Compile + import sanity.
  2. begin/end pair balances layout depth (depth before == depth after).
  3. begin emits 1 CMD_CLIP; end emits 1 more (total 2).
  4. scroll_y starts at 0, no drag → unchanged, returns False.
  5. Press inside + mouse_delta.y = +10 → scroll_y becomes -10 → clamps to 0.
  6. Press inside + mouse_delta.y = -5 → scroll_y becomes +5 (drag UP =
     content moves DOWN by 5 px = visible viewport moves DOWN — same as the
     widely-used "click+drag inside the area" convention).
  7. Inside the scroll area, `layout_next` returns a rect with y offset by
     `-scroll_y` (the inner frame is pushed at viewport.y - scroll_y).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_CLIP
from mojoui.widgets.scroll_area import begin_scroll_area, end_scroll_area


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helper — begin a frame with a single 200×60 layout row at (0,0), then patch
# in the requested mouse_delta. After this call, `layout_next()` returns
# Rect(0, 0, 200, 60) — enough room to hold a scroll area of area_height=60.
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
    mouse_delta_y: Float32,
) raises:
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    # Patch in the simulated vertical mouse motion. `begin_frame_no_input`
    # does NOT call `poll()`, so `ctx.input.mouse_delta` keeps its zero
    # default until we set it here. Per Mojo implementation notes c22 finding.
    ctx.input.mouse_delta = Vec2(0.0, mouse_delta_y)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 60)


def _count_cmd_clip(ctx: Context) -> Int32:
    """Count the number of CMD_CLIP commands in the buffer by walking
    `kind_at` / `size_at`."""
    var n: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == CMD_CLIP:
            n = n + 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off = off + step
    return n


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_balance() raises:
    """Test 1+2: module imports cleanly AND begin/end balance layout depth.

    `begin_frame_no_input` pushes the root frame (depth becomes 1), so the
    depth after `layout_row` is 1. `begin_scroll_area` pushes one more
    frame (depth 2), `end_scroll_area` pops it back (depth 1).
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0)
    var depth_before = Int(ctx.layout.depth())
    var scroll_y: Float32 = 0.0
    _ = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    var depth_inside = Int(ctx.layout.depth())
    end_scroll_area(ctx)
    var depth_after = Int(ctx.layout.depth())
    if depth_inside != depth_before + 1:
        _fail("begin_scroll_area should push one layout frame")
    if depth_after != depth_before:
        _fail("end_scroll_area should pop back to original depth")
    ctx.end_frame()


def test_emits_two_cmd_clip() raises:
    """Test 3: begin emits ONE CMD_CLIP (the viewport rect), end emits ONE
    more CMD_CLIP (restoring the window-rect). Total: 2 CMD_CLIP commands."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0)
    var scroll_y: Float32 = 0.0
    var before = _count_cmd_clip(ctx)
    _ = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    var mid = _count_cmd_clip(ctx)
    end_scroll_area(ctx)
    var after = _count_cmd_clip(ctx)
    if (mid - before) != 1:
        _fail("begin_scroll_area should emit exactly 1 CMD_CLIP")
    if (after - mid) != 1:
        _fail("end_scroll_area should emit exactly 1 CMD_CLIP")
    if (after - before) != 2:
        _fail("begin+end pair should emit exactly 2 CMD_CLIP commands")
    ctx.end_frame()


def test_no_drag_no_change() raises:
    """Test 4: scroll_y starts at 0, no press, no delta. `changed` is False;
    `scroll_y` remains 0."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0)
    var scroll_y: Float32 = 0.0
    var changed = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    end_scroll_area(ctx)
    if changed:
        _fail("no-drag should return False")
    if scroll_y != 0.0:
        _fail("no-drag should leave scroll_y unchanged at 0")
    ctx.end_frame()


def test_press_with_positive_delta_clamps_to_zero() raises:
    """Test 5: press inside + mouse_delta.y = +10. The behavior accumulates
    `scroll_y = scroll_y - delta.y = 0 - 10 = -10`, then the lower clamp
    snaps it back to 0. `changed` is True (scroll_y was MODIFIED by the
    drag — the clamp is a subsequent correction, not a "no-op")."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, 10.0)
    var scroll_y: Float32 = 0.0
    var changed = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    end_scroll_area(ctx)
    if not changed:
        _fail("press+delta should report changed=True")
    if scroll_y != 0.0:
        _fail("positive delta from scroll_y=0 should clamp to 0")
    ctx.end_frame()


def test_press_with_negative_delta_increases_scroll() raises:
    """Test 6: press inside + mouse_delta.y = -5. The behavior accumulates
    `scroll_y = scroll_y - delta.y = 0 - (-5) = +5`. No clamp since 5 > 0.
    `changed` is True. Drag UP (delta.y < 0) moves the visible viewport
    DOWN, which means content scrolls to show LATER rows.
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, -5.0)
    var scroll_y: Float32 = 0.0
    var changed = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    end_scroll_area(ctx)
    if not changed:
        _fail("press+delta should report changed=True")
    if scroll_y != 5.0:
        _fail("negative delta should accumulate into scroll_y as +abs(delta)")
    ctx.end_frame()


def test_inner_layout_offset_by_scroll_y() raises:
    """Test 7: inside the scroll area, the next `layout_next()` returns a
    Rect whose y is offset by `-scroll_y` relative to the viewport's y.

    With viewport at (0, 0, 200, 60) and scroll_y=5.0, the inner layout
    frame starts at (0, 0 - 5.0) = (0, -5). The next `layout_next()` (with
    no row set up — falls back to default col width / row height inside
    the inner frame) should report y = -5.
    """
    var ctx = Context()
    # Press inside + delta.y = -5 to set scroll_y to 5.0 by the same
    # mechanism as test 6. We then probe `layout_next()` BEFORE
    # `end_scroll_area`, while the inner layout frame is still on top.
    _make_ctx(ctx, Vec2(10.0, 10.0), True, False, -5.0)
    var scroll_y: Float32 = 0.0
    _ = begin_scroll_area(ctx, String("log_view"), 60, scroll_y)
    if scroll_y != 5.0:
        _fail("test 7 precondition: scroll_y should be 5.0 after drag")
    # Inside the inner frame: probe the next slot. Inner frame's body is
    # (0, -5, 200, 240). With no explicit row set up, the default first
    # slot is at the body's top-left (cursor starts at body.x, body.y).
    var slot = ctx.layout_next()
    if slot.y != -5.0:
        _fail("inner layout slot y should be -scroll_y = -5")
    if slot.x != 0.0:
        _fail("inner layout slot x should match viewport.x = 0")
    end_scroll_area(ctx)
    ctx.end_frame()


def main() raises:
    test_compile_and_balance()
    test_emits_two_cmd_clip()
    test_no_drag_no_change()
    test_press_with_positive_delta_clamps_to_zero()
    test_press_with_negative_delta_increases_scroll()
    test_inner_layout_offset_by_scroll_y()
    print("PASS: scroll_area widget smoke tests (6 tests)")
