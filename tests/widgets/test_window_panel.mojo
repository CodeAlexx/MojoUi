"""Smoke tests for `mojoui/widgets/window_panel.mojo` — M2 chunk 30.

Run: `pixi run test-window-panel`

Exercises `begin_window` / `end_window` end-to-end through Context →
LayoutStack → ControlState → CommandBuffer. Tests:
  1. Compile + import sanity.
  2. begin/end pair balances id_stack + layout depth.
  3. begin emits 1 CMD_JUMP + 1+ CMD_RECT (bg / title bar / 4 border edges).
  4. end patches the JUMP from -1 to a valid forward offset.
  5. Walker follows the patched JUMP without infinite-looping AND without
     skipping the rest of the buffer's commands (single-window M2 no-op
     self-skip semantic — JUMP dst == jump_off + CMD_JUMP_SIZE).
  6. Drag: title bar CTRL_ACTIVE + mouse_delta (5, 3) advances rect by
     (5, 3) (mutates caller's `rect`).

Pattern reused from `test_scroll_area.mojo` (c28) — `begin_frame_no_input`
to bypass FFI poll, patch `ctx.input.mouse_delta` directly to simulate
mouse motion (per MOJO_NOTES.md c22 finding).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP,
    CMD_RECT,
    CMD_JUMP_SIZE,
    HEADER_SIZE,
)
from mojoui.widgets.window_panel import begin_window, end_window


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------


def _make_ctx(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
    mouse_delta_x: Float32,
    mouse_delta_y: Float32,
) raises:
    """Push a frame at 800x600 with the requested mouse state + delta.

    `begin_frame_no_input` does NOT call `poll()`, so `ctx.input.mouse_delta`
    stays at its zero default until we patch it here. Same fixture pattern
    as `test_scroll_area.mojo` (c28) and `test_drag_value.mojo` (c22).
    """
    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released
    )
    ctx.input.mouse_delta = Vec2(mouse_delta_x, mouse_delta_y)


def _count_kind(ctx: Context, target_kind: Int32) -> Int32:
    """Count commands of `target_kind` in the buffer by walking
    `kind_at` / `size_at`. Stops on a non-positive step size for safety."""
    var n: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == target_kind:
            n = n + 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off = off + step
    return n


def _find_first_jump_offset(ctx: Context) -> Int32:
    """Linear scan for the FIRST CMD_JUMP in the buffer. Returns -1 if
    none found."""
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == CMD_JUMP:
            return off
        var step = ctx.commands.size_at(off)
        if step <= 0:
            return -1
        off = off + step
    return -1


def _walk_following_jumps(ctx: Context) -> Int32:
    """Walk the entire buffer, FOLLOWING CMD_JUMP `dst_offset` rather than
    blindly advancing by `size_at` over JUMPs. Returns the count of
    commands visited (incl. JUMPs themselves). Detects infinite loops by
    capping iterations at 1024.

    M2 invariant: the begin_window JUMP is patched to the no-op self-skip
    (`dst = off + CMD_JUMP_SIZE`), so following the JUMP advances by
    exactly one command size — equivalent to walking past it linearly.
    The walker MUST NOT infinite-loop and MUST visit every command after
    the JUMP (i.e. NOT skip the title bar / border / etc.).
    """
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    var visited: Int32 = 0
    var iters: Int32 = 0
    while off < total:
        iters = iters + 1
        if iters > 1024:
            return -1  # infinite loop guard
        visited = visited + 1
        var k = ctx.commands.kind_at(off)
        if k == CMD_JUMP:
            # Follow the JUMP destination instead of size_at.
            var dst = ctx.commands.read_jump_dst(off)
            if dst <= off:
                return -2  # backward / self-loop JUMP
            off = dst
        else:
            var step = ctx.commands.size_at(off)
            if step <= 0:
                return -3
            off = off + step
    return visited


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_balance() raises:
    """Test 1+2: module imports cleanly AND begin/end balance id_stack +
    layout depth.

    `begin_frame_no_input` pushes the root layout frame (depth 1) and
    leaves the id_stack empty. `begin_window` pushes one id (depth 1)
    and one inner layout frame (depth 2). `end_window` pops both.
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0, 0.0)
    var layout_before = Int(ctx.layout.depth())
    var ids_before = len(ctx.id_stack)
    var rect = Rect(40.0, 60.0, 280.0, 200.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    var layout_inside = Int(ctx.layout.depth())
    var ids_inside = len(ctx.id_stack)
    end_window(ctx)
    var layout_after = Int(ctx.layout.depth())
    var ids_after = len(ctx.id_stack)
    if layout_inside != layout_before + 1:
        _fail("begin_window should push exactly one layout frame")
    if ids_inside != ids_before + 1:
        _fail("begin_window should push exactly one id_stack entry")
    if layout_after != layout_before:
        _fail("end_window should pop the layout frame back to original depth")
    if ids_after != ids_before:
        _fail("end_window should pop the id_stack back to original size")
    ctx.end_frame()


def test_emits_jump_and_rects() raises:
    """Test 3: begin emits exactly 1 CMD_JUMP plus >=1 CMD_RECT (window bg
    + title bar + 4 border edges = 6 rects minimum; we just assert >=2 to
    be robust if the helper border code changes thickness etc.)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0, 0.0)
    var jumps_before = _count_kind(ctx, CMD_JUMP)
    var rects_before = _count_kind(ctx, CMD_RECT)
    var rect = Rect(40.0, 60.0, 280.0, 200.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    var jumps_mid = _count_kind(ctx, CMD_JUMP)
    var rects_mid = _count_kind(ctx, CMD_RECT)
    end_window(ctx)
    if (jumps_mid - jumps_before) != 1:
        _fail("begin_window should emit exactly 1 CMD_JUMP")
    if (rects_mid - rects_before) < 2:
        _fail(
            "begin_window should emit at least 2 CMD_RECT (bg + title +"
            " border edges)"
        )
    ctx.end_frame()


def test_end_patches_jump_to_valid_offset() raises:
    """Test 4: `end_window` patches the JUMP's dst_offset from the initial
    -1 sentinel to a valid forward offset (== jump_off + CMD_JUMP_SIZE for
    the M2 no-op self-skip semantic)."""
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0, 0.0)
    var rect = Rect(40.0, 60.0, 280.0, 200.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    # Before end_window, the JUMP's dst is still -1 (the sentinel
    # `emit_jump(-1)` wrote). The Context slot exposes the offset.
    var jump_off = ctx._container_jump_offset
    if jump_off < 0:
        _fail("begin_window should record the JUMP offset in Context slot")
    var dst_before = ctx.commands.read_jump_dst(jump_off)
    if dst_before != -1:
        _fail(
            "before end_window the JUMP dst should still be the -1 sentinel"
        )
    end_window(ctx)
    var dst_after = ctx.commands.read_jump_dst(jump_off)
    if dst_after == -1:
        _fail("end_window should patch the JUMP away from the -1 sentinel")
    # M2 no-op self-skip semantic: dst == jump_off + CMD_JUMP_SIZE.
    if dst_after != jump_off + CMD_JUMP_SIZE:
        _fail("M2 JUMP semantic: dst should equal jump_off + CMD_JUMP_SIZE")
    # And the slot should be reset back to -1 for the next window.
    if ctx._container_jump_offset != -1:
        _fail("end_window should reset _container_jump_offset to -1")
    ctx.end_frame()


def test_walker_does_not_loop_or_skip() raises:
    """Test 5: a walker that follows CMD_JUMP `dst_offset` (rather than
    advancing by `size_at`) MUST visit every command in the buffer
    without infinite-looping. M2 no-op self-skip semantic: the JUMP
    points one command size forward, so following it == walking past it
    linearly. Verifies the walker visits >= 6 commands (1 JUMP + 1 body
    bg + 1 title bar + 4 border edges).
    """
    var ctx = Context()
    _make_ctx(ctx, Vec2(500.0, 500.0), False, False, 0.0, 0.0)
    var rect = Rect(40.0, 60.0, 280.0, 200.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    end_window(ctx)
    var visited = _walk_following_jumps(ctx)
    if visited == -1:
        _fail("walker hit infinite-loop guard (JUMP not advancing forward?)")
    if visited == -2:
        _fail("walker saw a backward / self-loop JUMP — patch is wrong")
    if visited == -3:
        _fail("walker saw a zero-or-negative command size — buffer corrupt")
    if visited < 6:
        _fail(
            "walker should visit at least 6 commands (JUMP + bg + title +"
            " 4 border edges) — fewer means JUMP skipped real content"
        )
    ctx.end_frame()


def test_drag_moves_rect() raises:
    """Test 6: simulate a press on the title bar + non-zero mouse_delta.
    `rect.x` / `rect.y` should advance by the delta (mutated through the
    `mut rect: Rect` parameter).

    Two-frame setup is needed because `update_control` only sets
    CTRL_ACTIVE on the SAME frame the mouse is pressed inside the rect
    (or persists across frames once active is claimed). Frame 1: press
    inside the title bar at (50, 65) with no delta → claims active.
    Frame 2: hold (NOT released) at (55, 68) with delta (5, 3) → the
    behavior step advances rect by (5, 3).
    """
    var ctx = Context()
    var rect = Rect(40.0, 60.0, 280.0, 200.0)

    # Frame 1: press inside title bar — claims active for the title id.
    _make_ctx(ctx, Vec2(50.0, 65.0), True, False, 0.0, 0.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    end_window(ctx)
    ctx.end_frame()

    if rect.x != 40.0 or rect.y != 60.0:
        _fail("frame 1 (press, zero delta) should NOT move the rect")

    # Frame 2: hold (active stays claimed) with delta (5, 3) — drag.
    _make_ctx(ctx, Vec2(55.0, 68.0), False, False, 5.0, 3.0)
    _ = begin_window(ctx, String("settings"), String("Settings"), rect)
    end_window(ctx)
    ctx.end_frame()

    if rect.x != 45.0:
        _fail("drag with mouse_delta.x=5 should advance rect.x by 5")
    if rect.y != 63.0:
        _fail("drag with mouse_delta.y=3 should advance rect.y by 3")


def main() raises:
    test_compile_and_balance()
    test_emits_jump_and_rects()
    test_end_patches_jump_to_valid_offset()
    test_walker_does_not_loop_or_skip()
    test_drag_moves_rect()
    print("PASS: window_panel widget smoke tests (5 tests)")
