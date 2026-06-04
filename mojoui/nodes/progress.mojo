"""Per-node execution progress — events, state, and a badge overlay.

Mirrors EriGui's runtime progress system (`erigui-runtime/src/lib.rs`:
`NodeStart` / `NodeStep` / `NodeDone` / `NodeError` emitted over an
`mpsc::channel` and polled by the UI thread each frame). MojoUI has no
channel primitive (per `AUDIT_erigui_nodes.md` risk #3), so the contract
is simpler and synchronous: whatever drives execution appends
`ProgressEvent`s to a `List`, and the UI `drain`s that list into a
`ProgressState` (node_id → status) once per frame. There is NO threading
here — this is the pure-Mojo, FFI-free state layer plus a draw overlay;
wiring it to a real background executor is a later milestone.

Two-level model, matching the runtime:
  - `ProgressEvent` — a single emitted event (`PE_*` kind + optional
    step/total for a progress bar later).
  - `ProgressState` — the folded result: a node's current `PROG_*` status.

The overlay (`draw_progress_overlay`) draws a small status badge in each
running/done/errored node's title-bar corner. It is a SEPARATE function
called after `end_node_canvas` (not baked into `begin_node_canvas`) so the
canvas signature stays unchanged and execution-less callers pay nothing.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.id import RetainedId
from mojoui.nodes.graph import Graph
from mojoui.nodes.canvas import CanvasState, canvas_world_to_screen


# ============================================================================
# Status (folded) + event-kind (raw) constants
# ============================================================================

comptime NodeStatus = Int32

comptime PROG_IDLE: NodeStatus = 0
"""Node has not started (default for any node absent from the map)."""

comptime PROG_RUNNING: NodeStatus = 1
"""Node is currently executing (NodeStart / NodeStep seen, no terminal)."""

comptime PROG_DONE: NodeStatus = 2
"""Node finished successfully (NodeDone)."""

comptime PROG_ERROR: NodeStatus = 3
"""Node failed (NodeError)."""


comptime EventKind = Int32

comptime PE_START: EventKind = 0
comptime PE_STEP: EventKind = 1
comptime PE_DONE: EventKind = 2
comptime PE_ERROR: EventKind = 3


# ============================================================================
# ProgressEvent — one raw event from the executor
# ============================================================================


struct ProgressEvent(Copyable, Movable):
    """A single progress event for `node_id`. `step`/`total` carry sampler
    iteration counts for a future in-node progress bar; ignored by the
    M-now badge overlay (which only cares about the folded status)."""

    var node_id: RetainedId
    var kind: EventKind
    var step: Int32
    var total: Int32

    def __init__(
        out self,
        node_id: RetainedId,
        kind: EventKind,
        step: Int32,
        total: Int32,
    ):
        self.node_id = node_id
        self.kind = kind
        self.step = step
        self.total = total


# ============================================================================
# ProgressState — node_id → folded status
# ============================================================================


struct ProgressState(Movable):
    """Folded execution status keyed by node id. Movable-only (one per
    canvas/run). Absent keys read as `PROG_IDLE`."""

    var status: Dict[RetainedId, NodeStatus]

    def __init__(out self):
        self.status = Dict[RetainedId, NodeStatus]()

    def set_status(mut self, node_id: RetainedId, status: NodeStatus):
        """Directly set a node's status (Dict `__setitem__` does not raise
        in current beta — see `node.set_field`)."""
        self.status[node_id] = status

    def get(self, node_id: RetainedId) raises -> NodeStatus:
        """Folded status for `node_id`, or `PROG_IDLE` if never seen.
        Raises only structurally (Dict `__getitem__`); the `in` guard
        means it never actually raises in practice."""
        if node_id in self.status:
            return self.status[node_id]
        return PROG_IDLE

    def drain(mut self, mut events: List[ProgressEvent]):
        """Fold every queued event into `status`, then clear the queue.
        START/STEP → RUNNING, DONE → DONE, ERROR → ERROR. Call once per
        frame with the executor's pending-event list; on return the list
        is empty."""
        var n = len(events)
        for i in range(n):
            var ev = events[i].copy()
            if ev.kind == PE_DONE:
                self.status[ev.node_id] = PROG_DONE
            elif ev.kind == PE_ERROR:
                self.status[ev.node_id] = PROG_ERROR
            else:  # PE_START or PE_STEP
                self.status[ev.node_id] = PROG_RUNNING
        events = List[ProgressEvent]()

    def reset(mut self):
        """Clear all status (e.g. at the start of a new run)."""
        self.status = Dict[RetainedId, NodeStatus]()


# ============================================================================
# Badge rendering
# ============================================================================

comptime _BADGE_SIZE: Float32 = 10.0
"""On-screen badge square edge length (px). Drawn in the node title-bar's
top-right corner."""

comptime _BADGE_INSET: Float32 = 4.0
"""Inset of the badge from the node's top-right corner."""

comptime _TITLE_BAR_H: Float32 = 24.0
"""Must match `canvas._TITLE_BAR_H` (the badge sits inside the title bar).
Duplicated as a comptime here to avoid importing a private canvas const."""


def progress_badge_color(status: NodeStatus) -> Color:
    """Badge color per status: running = amber, done = green, error = red.
    IDLE returns transparent (the overlay skips idle nodes before this is
    called, so the value is only a safety default)."""
    if status == PROG_RUNNING:
        return Color(UInt8(245), UInt8(158), UInt8(11), UInt8(255))
    elif status == PROG_DONE:
        return Color(UInt8(80), UInt8(200), UInt8(120), UInt8(255))
    elif status == PROG_ERROR:
        return Color(UInt8(220), UInt8(70), UInt8(70), UInt8(255))
    return Color(UInt8(0), UInt8(0), UInt8(0), UInt8(0))


def draw_progress_overlay(
    mut ctx: Context,
    state: CanvasState,
    graph: Graph,
    progress: ProgressState,
) raises -> Int32:
    """Draw a status badge on every node with a non-idle status. Returns
    the number of badges drawn.

    Call AFTER `end_node_canvas` so badges paint on top of node bodies.
    Recomputes each node's screen rect from `state.pan`/`state.zoom`
    (same affine as the canvas) and places the badge in the title bar's
    top-right corner. Idle nodes are skipped (no badge).
    """
    var drawn: Int32 = 0
    var nn = graph.node_count()
    for i in range(nn):
        var node = graph.nodes[i].copy()
        var st = progress.get(node.id)
        if st == PROG_IDLE:
            continue
        var screen_pos = canvas_world_to_screen(state, node.position.copy())
        var node_w = node.size.x * state.zoom
        var badge_x = screen_pos.x + node_w - _BADGE_SIZE - _BADGE_INSET
        var badge_y = screen_pos.y + _BADGE_INSET
        ctx.draw_rect(
            Rect(badge_x, badge_y, _BADGE_SIZE, _BADGE_SIZE),
            progress_badge_color(st),
        )
        drawn = drawn + 1
    return drawn
