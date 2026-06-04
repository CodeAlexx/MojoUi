"""Tests for per-node execution progress — events, fold, and badge overlay.

Run: `pixi run test-progress`

Pure `mojo run` (no FFI): ProgressState is plain data; the overlay only
calls `ctx.draw_rect`. Frame setup via `begin_frame_no_input`.

Covers:
  1. Empty state reads PROG_IDLE for any node.
  2. drain folds START/STEP/DONE/ERROR into the right status and empties
     the event queue.
  3. set_status / get round-trip; reset clears.
  4. draw_progress_overlay draws one badge per non-idle node and returns
     that count (idle nodes skipped).
  5. Badge colors are distinct per status.
"""

from mojoui.core.types import Vec2, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_RECT
from mojoui.nodes.graph import Graph
from mojoui.nodes.canvas import CanvasState
from mojoui.nodes.progress import (
    ProgressEvent,
    ProgressState,
    progress_badge_color,
    draw_progress_overlay,
    PROG_IDLE,
    PROG_RUNNING,
    PROG_DONE,
    PROG_ERROR,
    PE_START,
    PE_STEP,
    PE_DONE,
    PE_ERROR,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _count_kind(ctx: Context, target_kind: Int32) -> Int32:
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


# ----------------------------------------------------------------------------
# 1. Empty state → IDLE
# ----------------------------------------------------------------------------


def test_empty_state_is_idle() raises:
    var ps = ProgressState()
    if ps.get(UInt64(1)) != PROG_IDLE:
        _fail("unseen node should read PROG_IDLE")
    print("PASS: test_empty_state_is_idle")


# ----------------------------------------------------------------------------
# 2. drain folds events + empties the queue
# ----------------------------------------------------------------------------


def test_drain_folds_events() raises:
    var ps = ProgressState()
    var events = List[ProgressEvent]()
    # node 1: START then STEP → RUNNING (last non-terminal wins as RUNNING).
    events.append(ProgressEvent(UInt64(1), PE_START, Int32(0), Int32(20)))
    events.append(ProgressEvent(UInt64(1), PE_STEP, Int32(5), Int32(20)))
    # node 2: DONE.
    events.append(ProgressEvent(UInt64(2), PE_DONE, Int32(0), Int32(0)))
    # node 3: ERROR.
    events.append(ProgressEvent(UInt64(3), PE_ERROR, Int32(0), Int32(0)))

    ps.drain(events)

    if len(events) != 0:
        _fail("drain should empty the event queue")
    if ps.get(UInt64(1)) != PROG_RUNNING:
        _fail("node 1 (START+STEP) should be RUNNING")
    if ps.get(UInt64(2)) != PROG_DONE:
        _fail("node 2 (DONE) should be DONE")
    if ps.get(UInt64(3)) != PROG_ERROR:
        _fail("node 3 (ERROR) should be ERROR")
    print("PASS: test_drain_folds_events")


def test_done_then_idle_other() raises:
    """A terminal DONE for one node leaves an unrelated node IDLE."""
    var ps = ProgressState()
    var events = List[ProgressEvent]()
    events.append(ProgressEvent(UInt64(7), PE_DONE, Int32(0), Int32(0)))
    ps.drain(events)
    if ps.get(UInt64(7)) != PROG_DONE:
        _fail("node 7 should be DONE")
    if ps.get(UInt64(99)) != PROG_IDLE:
        _fail("untouched node 99 should stay IDLE")
    print("PASS: test_done_then_idle_other")


# ----------------------------------------------------------------------------
# 3. set_status / reset
# ----------------------------------------------------------------------------


def test_set_status_and_reset() raises:
    var ps = ProgressState()
    ps.set_status(UInt64(5), PROG_RUNNING)
    if ps.get(UInt64(5)) != PROG_RUNNING:
        _fail("set_status should stick")
    ps.reset()
    if ps.get(UInt64(5)) != PROG_IDLE:
        _fail("reset should clear all status back to IDLE")
    print("PASS: test_set_status_and_reset")


# ----------------------------------------------------------------------------
# 4. overlay draws one badge per non-idle node
# ----------------------------------------------------------------------------


def test_overlay_draws_badge_per_nonidle() raises:
    """3 nodes; 2 non-idle (RUNNING, DONE), 1 idle. Overlay returns 2 and
    emits exactly 2 CMD_RECT badges."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var a = graph.add_node(String("test/a"), Vec2(Float32(10.0), Float32(10.0)))
    var b = graph.add_node(String("test/b"), Vec2(Float32(250.0), Float32(10.0)))
    var c = graph.add_node(String("test/c"), Vec2(Float32(490.0), Float32(10.0)))
    var ps = ProgressState()
    ps.set_status(a, PROG_RUNNING)
    ps.set_status(b, PROG_DONE)
    # c stays IDLE (unset).

    ctx.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
    )
    var drawn = draw_progress_overlay(ctx, state, graph, ps)
    ctx.end_frame()

    if drawn != Int32(2):
        _fail("overlay should draw 2 badges (RUNNING+DONE), got " + String(drawn))
    var rects = _count_kind(ctx, Int32(CMD_RECT))
    if rects != Int32(2):
        _fail("overlay should emit exactly 2 CMD_RECT, got " + String(Int(rects)))
    # idle node c must not have produced a badge — confirmed by count == 2.
    _ = c
    print("PASS: test_overlay_draws_badge_per_nonidle")


# ----------------------------------------------------------------------------
# 5. distinct badge colors
# ----------------------------------------------------------------------------


def _same(a: Color, b: Color) -> Bool:
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a


def test_badge_colors_distinct() raises:
    var run = progress_badge_color(PROG_RUNNING)
    var done = progress_badge_color(PROG_DONE)
    var err = progress_badge_color(PROG_ERROR)
    if _same(run, done) or _same(run, err) or _same(done, err):
        _fail("running/done/error badges must be visually distinct")
    print("PASS: test_badge_colors_distinct")


def main() raises:
    test_empty_state_is_idle()
    test_drain_folds_events()
    test_done_then_idle_other()
    test_set_status_and_reset()
    test_overlay_draws_badge_per_nonidle()
    test_badge_colors_distinct()
    print("PASS: all 6 progress tests")
