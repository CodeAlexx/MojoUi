"""Smoke tests for `mojoui/nodes/canvas.mojo` — M2.5 chunk 39.

Run: `pixi run test-canvas`

Exercises CanvasState + the transform helpers + `begin_node_canvas` /
`end_node_canvas`. Tests:
  1. `CanvasState()` defaults — zero pan, identity zoom, RET_ID_NONE
     dragging/selected, empty wire-drag state.
  2. World→screen round-trip at zoom=1 pan=(5,5) — world (10, 20) →
     screen (15, 25) and the inverse recovers (10, 20).
  3. World→screen at zoom=2 pan=(0,0) — world (10, 20) → screen (20, 40).
  4. `port_screen_pos` at zoom=1 pan=(0,0) for input port 0 of a node at
     world origin — should match `_TITLE_BAR_H + _PORT_SPACING / 2`.
  5. `begin_node_canvas` + `end_node_canvas` emit 2 CMD_CLIP commands
     (one push, one restore — same as scroll_area).
  6. Drag start: simulating a left-click inside a node sets
     `dragging_node` + `selected_node`.
  7. Drag continue: holding LEFT with a mouse_delta advances
     `node.position` in WORLD space.
  8. Drag release: dropping LEFT clears `dragging_node` back to
     `RET_ID_NONE`.
  9. Wire rendering: a graph with 2 nodes + 1 edge emits at least
     `WIRE_SEGMENTS` (24) bezier segment rects on top of the node bodies.

Pattern reused from `test_window_panel.mojo` (c30) and
`test_scroll_area.mojo` (c28): `begin_frame_no_input` to bypass FFI poll,
patch `ctx.input.mouse_delta` directly to simulate mouse motion (c22).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_CLIP, CMD_RECT, CMD_TEXT
from mojoui.core.id import RET_ID_NONE
from mojoui.render.ffi import MOJOUI_KEY_DELETE
from mojoui.nodes.node import PortRef, FieldValue
from mojoui.nodes.graph import Graph
from mojoui.nodes.wires import WIRE_SEGMENTS, WIRE_TANGENT_FRAC, cubic_bezier_point
from mojoui.nodes.canvas import (
    CanvasState,
    canvas_world_to_screen,
    canvas_screen_to_world,
    port_screen_pos,
    hovered_edge,
    begin_node_canvas,
    end_node_canvas,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _abs(x: Float32) -> Float32:
    if x < Float32(0.0):
        return -x
    return x


def _approx_eq(a: Float32, b: Float32) -> Bool:
    return _abs(a - b) <= Float32(1.0e-4)


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


def _begin_no_input(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
    delta_x: Float32,
    delta_y: Float32,
):
    """`begin_frame_no_input` does NOT call `poll()`, so we patch
    `mouse_delta` and `prev_mouse_held[0]` here to simulate held-mouse
    drag across frames (c22 pattern)."""
    ctx.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        mouse_pos.copy(),
        pressed,
        released,
    )
    ctx.input.mouse_delta = Vec2(delta_x, delta_y)


def _set_mouse_button_state(
    mut ctx: Context, button: Int, pressed: Bool, held: Bool, released: Bool
):
    """Patch `input.mouse[button]` directly. `begin_frame_no_input` does
    not auto-sync the per-button slot fields from its `pressed/released`
    args — the slot stays at its zero default. Tests that exercise
    drag continue / release must patch this slot to drive the canvas's
    `mouse_released(0)` / `mouse_held(0)` checks."""
    ctx.input.mouse[button].pressed = pressed
    ctx.input.mouse[button].held = held
    ctx.input.mouse[button].released = released


# ----------------------------------------------------------------------------
# Test 1: CanvasState defaults
# ----------------------------------------------------------------------------


def test_canvas_state_defaults() raises:
    """CanvasState() initializes with zero pan, zoom=1.0, RET_ID_NONE
    dragging/selected, empty wire-drag state."""
    var s = CanvasState()
    if not _approx_eq(s.pan.x, Float32(0.0)) or not _approx_eq(
        s.pan.y, Float32(0.0)
    ):
        _fail("pan should default to zero, got " + String(s.pan))
    if not _approx_eq(s.zoom, Float32(1.0)):
        _fail("zoom should default to 1.0, got " + String(s.zoom))
    if s.dragging_node != RET_ID_NONE:
        _fail(
            "dragging_node should default to RET_ID_NONE, got "
            + String(s.dragging_node)
        )
    if s.selected_node != RET_ID_NONE:
        _fail(
            "selected_node should default to RET_ID_NONE, got "
            + String(s.selected_node)
        )
    if s.wire_drag_from_node != RET_ID_NONE:
        _fail("wire_drag_from_node should default to RET_ID_NONE")
    if s.wire_drag_from_port != String(""):
        _fail("wire_drag_from_port should default to empty string")
    if s.wire_drag_from_is_output:
        _fail("wire_drag_from_is_output should default to False")
    print("PASS: test_canvas_state_defaults")


# ----------------------------------------------------------------------------
# Test 2: World↔screen round-trip
# ----------------------------------------------------------------------------


def test_world_to_screen_round_trip() raises:
    """At zoom=1 and pan=(5,5), world (10, 20) maps to screen (15, 25);
    the inverse recovers (10, 20)."""
    var s = CanvasState()
    s.pan = Vec2(Float32(5.0), Float32(5.0))
    var w = Vec2(Float32(10.0), Float32(20.0))
    var sc = canvas_world_to_screen(s, w.copy())
    if not _approx_eq(sc.x, Float32(15.0)) or not _approx_eq(
        sc.y, Float32(25.0)
    ):
        _fail(
            "world (10, 20) at pan=(5,5) zoom=1 should map to screen"
            " (15, 25), got "
            + String(sc)
        )
    var w2 = canvas_screen_to_world(s, sc.copy())
    if not _approx_eq(w2.x, w.x) or not _approx_eq(w2.y, w.y):
        _fail("inverse round-trip lost precision, got " + String(w2))
    print("PASS: test_world_to_screen_round_trip")


# ----------------------------------------------------------------------------
# Test 3: World→screen with zoom
# ----------------------------------------------------------------------------


def test_world_to_screen_with_zoom() raises:
    """At zoom=2 pan=(0,0), world (10, 20) maps to screen (20, 40)."""
    var s = CanvasState()
    s.zoom = Float32(2.0)
    var sc = canvas_world_to_screen(s, Vec2(Float32(10.0), Float32(20.0)))
    if not _approx_eq(sc.x, Float32(20.0)) or not _approx_eq(
        sc.y, Float32(40.0)
    ):
        _fail(
            "world (10, 20) at zoom=2 pan=(0,0) should map to screen"
            " (20, 40), got "
            + String(sc)
        )
    print("PASS: test_world_to_screen_with_zoom")


# ----------------------------------------------------------------------------
# Test 4: port_screen_pos
# ----------------------------------------------------------------------------


def test_port_screen_pos_first_input() raises:
    """Input port index 0 of a node at world (0, 0), zoom=1, pan=(0,0)
    sits at y = TITLE_BAR_H + PORT_SPACING/2 = 24 + 10 = 34. x = 0 (input
    anchors on the left edge of the node)."""
    var s = CanvasState()
    var g = Graph()
    _ = g.add_node(String("test/dummy"), Vec2(Float32(0.0), Float32(0.0)))
    g.nodes[0].add_input(PortRef(String("in"), Int32(0)))
    var pos = port_screen_pos(s, g.nodes[0].copy(), 0, True)
    if not _approx_eq(pos.x, Float32(0.0)) or not _approx_eq(
        pos.y, Float32(34.0)
    ):
        _fail(
            "port_screen_pos(input 0) expected (0, 34), got " + String(pos)
        )
    print("PASS: test_port_screen_pos_first_input")


# ----------------------------------------------------------------------------
# Test 5: begin/end emits 2 CMD_CLIP
# ----------------------------------------------------------------------------


def test_begin_end_emits_two_clip_commands() raises:
    """`begin_node_canvas` emits ONE CMD_CLIP at the viewport and
    `end_node_canvas` emits a second CMD_CLIP restoring the full window
    — total 2 CMD_CLIP records in the buffer."""
    var ctx = Context()
    _begin_no_input(
        ctx,
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state = CanvasState()
    var graph = Graph()
    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)
    var n_clip = _count_kind(ctx, Int32(CMD_CLIP))
    if n_clip != Int32(2):
        _fail(
            "begin/end should emit 2 CMD_CLIP, got " + String(Int(n_clip))
        )
    print("PASS: test_begin_end_emits_two_clip_commands")


# ----------------------------------------------------------------------------
# Test 6: drag start sets dragging/selected on press
# ----------------------------------------------------------------------------


def test_drag_start_on_press_sets_state() raises:
    """A LEFT press inside a node's body claims selection + starts drag.

    Setup: node at world (50, 50) of size 200x80. With pan=(0,0), zoom=1,
    the screen rect is (50, 50, 200, 80). A click at (100, 70) lands
    inside the body; the control SM emits CTRL_PRESSED on the press
    frame, which the canvas handler turns into dragging_node + selected
    + drag_offset.
    """
    var ctx = Context()
    _begin_no_input(
        ctx,
        Vec2(Float32(100.0), Float32(70.0)),
        True,  # pressed this frame
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state = CanvasState()
    var graph = Graph()
    var nid = graph.add_node(
        String("test/dummy"), Vec2(Float32(50.0), Float32(50.0))
    )

    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)

    if state.dragging_node != nid:
        _fail(
            "press inside node body should set dragging_node="
            + String(nid)
            + ", got "
            + String(state.dragging_node)
        )
    if state.selected_node != nid:
        _fail("press inside node should set selected_node")
    # drag_offset = mouse_pos - node_screen_pos = (100-50, 70-50) = (50, 20).
    if not _approx_eq(
        state.drag_offset.x, Float32(50.0)
    ) or not _approx_eq(state.drag_offset.y, Float32(20.0)):
        _fail(
            "drag_offset expected (50, 20), got " + String(state.drag_offset)
        )
    print("PASS: test_drag_start_on_press_sets_state")


# ----------------------------------------------------------------------------
# Test 7: drag continue advances node.position
# ----------------------------------------------------------------------------


def test_drag_continue_moves_node_position() raises:
    """After drag start, holding LEFT with a mouse delta updates
    `node.position` in WORLD coordinates each frame.

    Frame 1: press at (100, 70) over a node at world (50, 50). drag_offset
    becomes (50, 20).
    Frame 2: hold LEFT (mouse_held(0) = True), cursor moves to (110, 75).
    The canvas recomputes node.position = mouse_pos - drag_offset =
    (110, 75) - (50, 20) = (60, 55) (in world space since zoom=1, pan=0).
    """
    var ctx = Context()
    _begin_no_input(
        ctx,
        Vec2(Float32(100.0), Float32(70.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state = CanvasState()
    var graph = Graph()
    var nid = graph.add_node(
        String("test/dummy"), Vec2(Float32(50.0), Float32(50.0))
    )
    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)

    if state.dragging_node != nid:
        _fail("frame 1 should have started drag")

    # Frame 2: hold the button (no fresh press), advance the cursor.
    _begin_no_input(
        ctx,
        Vec2(Float32(110.0), Float32(75.0)),
        False,
        False,
        Float32(10.0),
        Float32(5.0),
    )
    _set_mouse_button_state(ctx, 0, False, True, False)

    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)

    var idx = graph.find_node(nid)
    if idx < 0:
        _fail("node should still exist after drag")
    var p = graph.nodes[idx].position.copy()
    if not _approx_eq(p.x, Float32(60.0)) or not _approx_eq(
        p.y, Float32(55.0)
    ):
        _fail(
            "after drag-continue node.position expected (60, 55), got "
            + String(p)
        )
    print("PASS: test_drag_continue_moves_node_position")


# ----------------------------------------------------------------------------
# Test 8: drag release clears dragging_node
# ----------------------------------------------------------------------------


def test_drag_release_clears_dragging_node() raises:
    """Once the LEFT button is released, the canvas clears
    `dragging_node` back to `RET_ID_NONE`. `selected_node` is NOT
    cleared (single-select stays sticky across the drag end)."""
    var ctx = Context()
    _begin_no_input(
        ctx,
        Vec2(Float32(100.0), Float32(70.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state = CanvasState()
    var graph = Graph()
    var nid = graph.add_node(
        String("test/dummy"), Vec2(Float32(50.0), Float32(50.0))
    )
    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)
    if state.dragging_node != nid:
        _fail("press frame should have started drag")

    # Frame 2: cursor at (110, 75), LEFT button released this frame.
    # `mouse_released(0)` reads `input.mouse[0].released` — patch both
    # `.held=False` and `.released=True` to simulate the falling edge.
    _begin_no_input(
        ctx,
        Vec2(Float32(110.0), Float32(75.0)),
        False,
        True,
        Float32(0.0),
        Float32(0.0),
    )
    _set_mouse_button_state(ctx, 0, False, False, True)
    _ = begin_node_canvas(ctx, String("main_canvas"), state, graph)
    end_node_canvas(ctx)

    if state.dragging_node != RET_ID_NONE:
        _fail("after release dragging_node should be RET_ID_NONE")
    if state.selected_node != nid:
        _fail("selected_node should remain sticky across release")
    print("PASS: test_drag_release_clears_dragging_node")


# ----------------------------------------------------------------------------
# Test 9: wire rendering — bezier segments emitted for each edge
# ----------------------------------------------------------------------------


def test_wire_rendering_emits_bezier_segments() raises:
    """A graph with 2 nodes + 1 edge should emit at least `WIRE_SEGMENTS`
    (24) extra CMD_RECT records beyond the per-node body/title/border/
    port-dot baseline — one per polyline segment of the cubic bezier.

    Methodology: run the canvas with NO edge (baseline rect count); then
    add one edge between matching ports and re-run; the delta should be
    >= WIRE_SEGMENTS.
    """
    var ctx_a = Context()
    _begin_no_input(
        ctx_a,
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state_a = CanvasState()
    var graph_a = Graph()
    _ = graph_a.add_node(
        String("test/a"), Vec2(Float32(50.0), Float32(50.0))
    )
    _ = graph_a.add_node(
        String("test/b"), Vec2(Float32(300.0), Float32(200.0))
    )
    graph_a.nodes[0].add_output(PortRef(String("out"), Int32(0)))
    graph_a.nodes[1].add_input(PortRef(String("in"), Int32(0)))
    _ = begin_node_canvas(ctx_a, String("c"), state_a, graph_a)
    end_node_canvas(ctx_a)
    var baseline_rects = _count_kind(ctx_a, Int32(CMD_RECT))

    var ctx_b = Context()
    _begin_no_input(
        ctx_b,
        Vec2(Float32(0.0), Float32(0.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var state_b = CanvasState()
    var graph_b = Graph()
    _ = graph_b.add_node(
        String("test/a"), Vec2(Float32(50.0), Float32(50.0))
    )
    _ = graph_b.add_node(
        String("test/b"), Vec2(Float32(300.0), Float32(200.0))
    )
    graph_b.nodes[0].add_output(PortRef(String("out"), Int32(0)))
    graph_b.nodes[1].add_input(PortRef(String("in"), Int32(0)))
    var ok = graph_b.add_edge(
        graph_b.nodes[0].id,
        String("out"),
        graph_b.nodes[1].id,
        String("in"),
    )
    if not ok:
        _fail("add_edge should succeed for both-known endpoints")
    _ = begin_node_canvas(ctx_b, String("c"), state_b, graph_b)
    end_node_canvas(ctx_b)
    var with_edge_rects = _count_kind(ctx_b, Int32(CMD_RECT))

    var delta = Int(with_edge_rects) - Int(baseline_rects)
    if delta < Int(WIRE_SEGMENTS):
        _fail(
            "adding one edge should emit >= "
            + String(Int(WIRE_SEGMENTS))
            + " new CMD_RECT records, got delta="
            + String(delta)
        )
    print(
        "PASS: test_wire_rendering_emits_bezier_segments (delta="
        + String(delta)
        + " rects)"
    )


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------


# ----------------------------------------------------------------------------
# Test 10: per-node body renders field rows (draw_body hook)
# ----------------------------------------------------------------------------


def test_node_body_renders_field_rows() raises:
    """A node with 2 fields emits 2 more CMD_TEXT records than a node with
    0 fields (1 title line each + 2 body lines for the fielded node).
    Requires font_id != 0 (else all text is skipped per FRAGILE #5)."""
    # Baseline: node with no fields.
    var ctx_a = Context()
    ctx_a.set_default_font(UInt32(1))
    _begin_no_input(
        ctx_a, Vec2(0.0, 0.0), False, False, Float32(0.0), Float32(0.0)
    )
    var widths_a = List[Int32]()
    widths_a.append(Int32(800))
    ctx_a.layout_row(widths_a^, Int32(600))
    var state_a = CanvasState()
    var graph_a = Graph()
    _ = graph_a.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    _ = begin_node_canvas(ctx_a, String("c"), state_a, graph_a)
    end_node_canvas(ctx_a)
    var baseline_text = _count_kind(ctx_a, Int32(CMD_TEXT))

    # With 2 fields.
    var ctx_b = Context()
    ctx_b.set_default_font(UInt32(1))
    _begin_no_input(
        ctx_b, Vec2(0.0, 0.0), False, False, Float32(0.0), Float32(0.0)
    )
    var widths_b = List[Int32]()
    widths_b.append(Int32(800))
    ctx_b.layout_row(widths_b^, Int32(600))
    var state_b = CanvasState()
    var graph_b = Graph()
    _ = graph_b.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    graph_b.nodes[0].set_field(String("steps"), FieldValue.int_(Int64(30)))
    graph_b.nodes[0].set_field(String("cfg"), FieldValue.number(Float64(7.0)))
    _ = begin_node_canvas(ctx_b, String("c"), state_b, graph_b)
    end_node_canvas(ctx_b)
    var with_fields_text = _count_kind(ctx_b, Int32(CMD_TEXT))

    var delta = Int(with_fields_text) - Int(baseline_text)
    if delta != 2:
        _fail(
            "2 fields should add exactly 2 CMD_TEXT body rows, got delta="
            + String(delta)
        )
    print("PASS: test_node_body_renders_field_rows (delta=" + String(delta) + ")")


# ----------------------------------------------------------------------------
# Test 11: hovered_edge hit-tests against the drawn wire
# ----------------------------------------------------------------------------


def _wire_midpoint(state: CanvasState, graph: Graph) -> Vec2:
    """Screen-space midpoint (t=0.5) of the single wire in `graph` between
    node[0].out and node[1].in — same control-point layout as draw_wire."""
    var from_pos = port_screen_pos(state, graph.nodes[0].copy(), 0, False)
    var to_pos = port_screen_pos(state, graph.nodes[1].copy(), 0, True)
    var dx = to_pos.x - from_pos.x
    var ctrl_dx = dx * WIRE_TANGENT_FRAC
    var p0 = from_pos.copy()
    var p1 = Vec2(from_pos.x + ctrl_dx, from_pos.y)
    var p2 = Vec2(to_pos.x - ctrl_dx, to_pos.y)
    var p3 = to_pos.copy()
    return cubic_bezier_point(p0, p1, p2, p3, Float32(0.5))


def _two_node_wired_graph(mut graph: Graph):
    _ = graph.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    _ = graph.add_node(String("test/b"), Vec2(Float32(400.0), Float32(260.0)))
    graph.nodes[0].add_output(PortRef(String("out"), Int32(0)))
    graph.nodes[1].add_input(PortRef(String("in"), Int32(0)))
    _ = graph.add_edge(
        graph.nodes[0].id, String("out"), graph.nodes[1].id, String("in")
    )


def test_hovered_edge_hit_and_miss() raises:
    """A point on the wire midpoint hits edge 0; a far point misses (-1)."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    var mid = _wire_midpoint(state, graph)
    var hit = hovered_edge(state, graph, mid.copy(), Float32(6.0))
    if hit != Int32(0):
        _fail("midpoint should hover edge 0, got " + String(hit))
    var miss = hovered_edge(
        state, graph, Vec2(Float32(5.0), Float32(595.0)), Float32(6.0)
    )
    if miss != Int32(-1):
        _fail("far point should hover no edge (-1), got " + String(miss))
    print("PASS: test_hovered_edge_hit_and_miss")


# ----------------------------------------------------------------------------
# Test 12: left-click selects a wire, Delete key removes it
# ----------------------------------------------------------------------------


def test_wire_select_then_delete() raises:
    """Left-press on a wire (not over a node) selects it; a later Delete
    keypress removes it from the graph."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    var mid = _wire_midpoint(state, graph)

    # Frame 1: left-press at the wire midpoint → select edge 0.
    _begin_no_input(ctx, mid.copy(), True, False, Float32(0.0), Float32(0.0))
    var widths = List[Int32]()
    widths.append(Int32(800))
    ctx.layout_row(widths^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.selected_edge != Int32(0):
        _fail(
            "left-press on wire should select edge 0, got "
            + String(state.selected_edge)
        )
    if graph.edge_count() != 1:
        _fail("selection must not delete the edge yet")

    # Frame 2: Delete key pressed → edge removed.
    _begin_no_input(
        ctx, mid.copy(), False, False, Float32(0.0), Float32(0.0)
    )
    ctx.input.keys[Int(MOJOUI_KEY_DELETE)].pressed = True
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.edge_count() != 0:
        _fail("Delete key should remove the selected wire")
    if state.selected_edge != Int32(-1):
        _fail("selected_edge should reset to -1 after delete")
    print("PASS: test_wire_select_then_delete")


def main() raises:
    test_canvas_state_defaults()
    test_world_to_screen_round_trip()
    test_world_to_screen_with_zoom()
    test_port_screen_pos_first_input()
    test_begin_end_emits_two_clip_commands()
    test_drag_start_on_press_sets_state()
    test_drag_continue_moves_node_position()
    test_drag_release_clears_dragging_node()
    test_wire_rendering_emits_bezier_segments()
    test_node_body_renders_field_rows()
    test_hovered_edge_hit_and_miss()
    test_wire_select_then_delete()
    print("PASS: all 12 smoke tests")
