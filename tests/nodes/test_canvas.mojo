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
  9. Wire rendering: a graph with 2 nodes + 1 edge emits additional
     CMD_TRIANGLES batches for the stroked bezier wire.
 10. Per-node body rows render field values.
 11. Hover hit-testing follows the drawn wire.
 12. Left-click selects a wire; Delete removes it.
 13. Port-to-port drag creates a matching typed edge.
 14. Port-to-port drag rejects mismatched value types.
 15. Delete removes the selected node and attached edges.
 16. Select-all + copy/paste duplicates selected nodes and internal edges.
 17. Group-selected creates a reusable canvas group region.
 18. Reroute insertion splits one edge into two type-preserving edges.
 19. Mute/bypass/collapse/pin flags toggle on selected nodes.
 20. Fit/zoom helpers adjust pan/zoom around graph bounds and cursor.
 21. Empty-canvas marquee selects intersecting nodes.
 22. Shift multi-select + drag moves the selected group.
  23. Group header click selects members; group header drag moves bound nodes.
  24. rgthree-style group fast toggles mutate all bound member nodes.
  25. Group output collection returns queueable output/sink nodes.
  26. Canvas bookmarks jump pan/zoom to saved workflow views.
  27. Inline field editing opens from a row click and commits typed values.
  28. Prompt-builder bbox boxes can be selected and moved on-canvas.
  29. Empty prompt-builder image-stage clicks add new bbox boxes.
  30. Prompt-builder bbox resize handles update normalized size.
  31. Prompt-builder bbox label chips edit `elements_data` labels.
  32. Delete removes selected bbox boxes before selected nodes.
  33. Canvas action buttons expose reusable Generate/Add/Import requests.

Pattern reused from `test_window_panel.mojo` (c30) and
`test_scroll_area.mojo` (c28): `begin_frame_no_input` to bypass FFI poll,
patch `ctx.input.mouse_delta` directly to simulate mouse motion (c22).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_CLIP, CMD_RECT, CMD_TEXT, CMD_TRIANGLES
from mojoui.core.id import RET_ID_NONE
from mojoui.render.ffi import MOJOUI_KEY_DELETE, MOJOUI_KEY_RETURN
from mojoui.nodes.node import PortRef, FieldValue
from mojoui.nodes.graph import Graph
from mojoui.nodes.wires import WIRE_TANGENT_FRAC, cubic_bezier_point
from mojoui.serde.json import JK_ARRAY, parse_json
from mojoui.nodes.canvas import (
    CanvasState,
    canvas_world_to_screen,
    canvas_screen_to_world,
    port_screen_pos,
    hovered_edge,
    canvas_is_node_selected,
    canvas_selected_count,
    canvas_select_all,
    canvas_add_node_to_selection,
    canvas_copy_selection,
    canvas_paste_clipboard,
    canvas_group_selection,
    canvas_toggle_group_nodes_mute,
    canvas_toggle_group_nodes_bypass,
    canvas_group_output_nodes,
    canvas_add_bookmark,
    canvas_jump_to_bookmark,
    canvas_insert_reroute_on_edge,
    canvas_toggle_selected_nodes_mute,
    canvas_toggle_selected_nodes_bypass,
    canvas_toggle_selected_nodes_collapse,
    canvas_toggle_selected_nodes_pin,
    canvas_nudge_selection,
    canvas_fit_selection,
    canvas_zoom_at,
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
    shift_held: Bool = False,
):
    """`begin_frame_no_input` does NOT call `poll()`, so we patch
    `mouse_delta` and `prev_mouse_held[0]` here to simulate held-mouse
    drag across frames (c22 pattern)."""
    ctx.begin_frame_no_input(
        Vec2(Float32(800.0), Float32(600.0)),
        mouse_pos.copy(),
        pressed,
        released,
        False,
        shift_held,
    )
    ctx.input.mouse[0].pressed = pressed
    ctx.input.mouse[0].held = pressed
    ctx.input.mouse[0].released = released
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
    """A graph with 2 nodes + 1 edge should emit additional CMD_TRIANGLES
    batches beyond the per-node shell/body/port baseline.

    Methodology: run the canvas with NO edge (baseline rect count); then
    add one edge between matching ports and re-run; the delta should be
    at least four batches: glow stroke, core stroke, and two round caps.
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
    var baseline_tris = _count_kind(ctx_a, Int32(CMD_TRIANGLES))

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
    var with_edge_tris = _count_kind(ctx_b, Int32(CMD_TRIANGLES))

    var delta = Int(with_edge_tris) - Int(baseline_tris)
    if delta < 4:
        _fail(
            "adding one edge should emit >= 4 new CMD_TRIANGLES records, got delta="
            + String(delta)
        )
    print(
        "PASS: test_wire_rendering_emits_bezier_segments (delta="
        + String(delta)
        + " triangle batches)"
    )


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------


# ----------------------------------------------------------------------------
# Test 10: per-node body renders field rows (draw_body hook)
# ----------------------------------------------------------------------------


def test_node_body_renders_field_rows() raises:
    """A node with 2 fields emits 4 more CMD_TEXT records than a node with
    0 fields (1 pill label + 1 right arrow per field row).
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
    graph_a.nodes[0].size = Vec2(Float32(220.0), Float32(135.0))
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
    graph_b.nodes[0].size = Vec2(Float32(220.0), Float32(135.0))
    graph_b.nodes[0].set_field(String("steps"), FieldValue.int_(Int64(30)))
    graph_b.nodes[0].set_field(String("cfg"), FieldValue.number(Float64(7.0)))
    _ = begin_node_canvas(ctx_b, String("c"), state_b, graph_b)
    end_node_canvas(ctx_b)
    var with_fields_text = _count_kind(ctx_b, Int32(CMD_TEXT))

    var delta = Int(with_fields_text) - Int(baseline_text)
    if delta != 4:
        _fail(
            "2 fields should add exactly 4 CMD_TEXT body records, got delta="
            + String(delta)
        )
    print("PASS: test_node_body_renders_field_rows (delta=" + String(delta) + ")")


def test_inline_field_edit_commits_number() raises:
    """Clicking a field row opens inline edit mode; Enter commits through
    the type-aware conversion path and does not start a node drag."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    graph.nodes[0].size = Vec2(Float32(240.0), Float32(130.0))
    graph.nodes[0].set_field(String("cfg"), FieldValue.number(Float64(7.0)))

    _begin_no_input(
        ctx,
        Vec2(Float32(190.0), Float32(92.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    ctx.input.disable_ffi_text()
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.editing_field_node != graph.nodes[0].id:
        _fail("field click should enter inline edit mode")
    if state.editing_field_name != String("cfg"):
        _fail("inline editor should target cfg field")
    if state.dragging_node != RET_ID_NONE:
        _fail("field click should not start a node drag")

    state.editing_field_buffer = String("9.25")
    _begin_no_input(
        ctx,
        Vec2(Float32(190.0), Float32(92.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    ctx.input.disable_ffi_text()
    ctx.input.keys[Int(MOJOUI_KEY_RETURN)].pressed = True
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.editing_field_node != RET_ID_NONE:
        _fail("Enter should close inline edit mode after valid commit")
    var cfg = graph.nodes[0].fields[String("cfg")].copy()
    if cfg.num_val < Float64(9.249) or cfg.num_val > Float64(9.251):
        _fail("cfg should commit to 9.25, got " + String(cfg.num_val))
    print("PASS: test_inline_field_edit_commits_number")


def test_bbox_drag_updates_elements_data() raises:
    """Prompt-builder bbox boxes are direct-manipulation controls: a drag
    moves the selected normalized box and writes `elements_data` JSON."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(
        String("core/ideogram4_prompt_builder"),
        Vec2(Float32(50.0), Float32(50.0)),
    )
    graph.nodes[0].size = Vec2(Float32(420.0), Float32(280.0))
    graph.nodes[0].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72}]")
        ),
    )

    _begin_no_input(
        ctx,
        Vec2(Float32(200.0), Float32(205.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.bbox_selected_node != graph.nodes[0].id:
        _fail("click inside bbox should select the prompt-builder box")
    if state.bbox_drag_node != graph.nodes[0].id:
        _fail("click inside bbox should start bbox drag")
    if state.dragging_node != RET_ID_NONE:
        _fail("bbox click should not start node drag")

    _begin_no_input(
        ctx,
        Vec2(Float32(220.0), Float32(205.0)),
        False,
        False,
        Float32(20.0),
        Float32(0.0),
    )
    _set_mouse_button_state(ctx, 0, False, True, False)
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    var updated = graph.nodes[0].fields[String("elements_data")].copy()
    var parsed = parse_json(updated.str_val.copy())
    if parsed.kind != JK_ARRAY or len(parsed.arr_val) != 1:
        _fail("elements_data should remain a one-box JSON array")
    var x = parsed.arr_val[0].get_object_field(String("x")).num_val
    if x <= Float64(0.20):
        _fail("bbox drag should move x past 0.20, got " + String(x))
    print("PASS: test_bbox_drag_updates_elements_data")


def test_bbox_empty_stage_click_adds_box() raises:
    """Clicking empty prompt-builder image-stage space adds/selects a box
    without starting a node drag."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(
        String("core/ideogram4_prompt_builder"),
        Vec2(Float32(50.0), Float32(50.0)),
    )
    graph.nodes[0].size = Vec2(Float32(420.0), Float32(280.0))
    graph.nodes[0].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72}]")
        ),
    )

    _begin_no_input(
        ctx,
        Vec2(Float32(405.0), Float32(250.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var widths = List[Int32]()
    widths.append(Int32(800))
    ctx.layout_row(widths^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    var updated = graph.nodes[0].fields[String("elements_data")].copy()
    var parsed = parse_json(updated.str_val.copy())
    if parsed.kind != JK_ARRAY or len(parsed.arr_val) != 2:
        _fail("empty stage click should append a second bbox")
    if state.bbox_selected_index != Int64(1):
        _fail("new bbox should be selected")
    if state.dragging_node != RET_ID_NONE:
        _fail("adding bbox should not start node drag")
    print("PASS: test_bbox_empty_stage_click_adds_box")


def test_bbox_resize_handle_updates_size() raises:
    """Dragging the south-east bbox handle updates width/height in JSON."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(
        String("core/ideogram4_prompt_builder"),
        Vec2(Float32(50.0), Float32(50.0)),
    )
    graph.nodes[0].size = Vec2(Float32(420.0), Float32(280.0))
    graph.nodes[0].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72}]")
        ),
    )

    _begin_no_input(
        ctx,
        Vec2(Float32(288.0), Float32(264.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(
        ctx,
        Vec2(Float32(328.0), Float32(284.0)),
        False,
        False,
        Float32(40.0),
        Float32(20.0),
    )
    _set_mouse_button_state(ctx, 0, False, True, False)
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    var updated = graph.nodes[0].fields[String("elements_data")].copy()
    var parsed = parse_json(updated.str_val.copy())
    var w = parsed.arr_val[0].get_object_field(String("w")).num_val
    var h = parsed.arr_val[0].get_object_field(String("h")).num_val
    if w <= Float64(0.50):
        _fail("bbox resize should increase width past 0.50, got " + String(w))
    if h <= Float64(0.80):
        _fail("bbox resize should increase height past 0.80, got " + String(h))
    print("PASS: test_bbox_resize_handle_updates_size")


def test_bbox_label_chip_edit_commits_label() raises:
    """Clicking a bbox label chip opens inline edit mode and Enter commits
    the label back into `elements_data` JSON."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(
        String("core/ideogram4_prompt_builder"),
        Vec2(Float32(50.0), Float32(50.0)),
    )
    graph.nodes[0].size = Vec2(Float32(420.0), Float32(280.0))
    graph.nodes[0].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72}]")
        ),
    )

    _begin_no_input(
        ctx,
        Vec2(Float32(150.0), Float32(152.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    ctx.input.disable_ffi_text()
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.bbox_edit_node != graph.nodes[0].id:
        _fail("bbox label click should enter bbox edit mode")
    if state.bbox_edit_index != Int64(0):
        _fail("bbox label edit should target first box")
    if state.bbox_drag_node != RET_ID_NONE:
        _fail("bbox label edit should not start a bbox drag")

    state.bbox_edit_buffer = String("hero subject")
    _begin_no_input(
        ctx,
        Vec2(Float32(150.0), Float32(152.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    ctx.input.disable_ffi_text()
    ctx.input.keys[Int(MOJOUI_KEY_RETURN)].pressed = True
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.bbox_edit_node != RET_ID_NONE:
        _fail("Enter should close bbox edit mode")
    var updated = graph.nodes[0].fields[String("elements_data")].copy()
    var parsed = parse_json(updated.str_val.copy())
    var label = parsed.arr_val[0].get_object_field(String("label")).str_val
    if label != String("hero subject"):
        _fail("bbox label should commit into JSON, got " + label)
    print("PASS: test_bbox_label_chip_edit_commits_label")


def test_delete_selected_bbox_does_not_delete_node() raises:
    """Delete removes a selected bbox before falling through to node delete."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(
        String("core/ideogram4_prompt_builder"),
        Vec2(Float32(50.0), Float32(50.0)),
    )
    graph.nodes[0].size = Vec2(Float32(420.0), Float32(280.0))
    graph.nodes[0].set_field(
        String("elements_data"),
        FieldValue.string(
            String("[{\"label\":\"subject\",\"x\":0.16,\"y\":0.12,\"w\":0.42,\"h\":0.72}]")
        ),
    )

    _begin_no_input(
        ctx,
        Vec2(Float32(200.0), Float32(205.0)),
        True,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.bbox_selected_node != graph.nodes[0].id:
        _fail("bbox body click should select bbox")

    _begin_no_input(
        ctx,
        Vec2(Float32(200.0), Float32(205.0)),
        False,
        False,
        Float32(0.0),
        Float32(0.0),
    )
    ctx.input.keys[Int(MOJOUI_KEY_DELETE)].pressed = True
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.node_count() != 1:
        _fail("Delete on selected bbox should not delete the node")
    var updated = graph.nodes[0].fields[String("elements_data")].copy()
    var parsed = parse_json(updated.str_val.copy())
    if parsed.kind != JK_ARRAY or len(parsed.arr_val) != 0:
        _fail("Delete should remove the selected bbox from elements_data")
    print("PASS: test_delete_selected_bbox_does_not_delete_node")


def test_canvas_generate_action_button_sets_request() raises:
    """The reusable canvas action strip exposes a Generate request flag."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()

    _begin_no_input(ctx, Vec2(Float32(50.0), Float32(30.0)), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(ctx, Vec2(Float32(50.0), Float32(30.0)), False, True, Float32(0.0), Float32(0.0))
    _set_mouse_button_state(ctx, 0, False, False, True)
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if not state.generate_requested:
        _fail("Generate action button should set generate_requested on release")
    if state.add_image_requested or state.import_json_requested:
        _fail("Generate action should not set sibling action flags")
    print("PASS: test_canvas_generate_action_button_sets_request")


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


def _two_node_link_graph(mut graph: Graph, out_type: Int32, in_type: Int32):
    _ = graph.add_node(String("test/source"), Vec2(Float32(50.0), Float32(50.0)))
    _ = graph.add_node(String("test/sink"), Vec2(Float32(400.0), Float32(50.0)))
    graph.nodes[0].add_output(PortRef(String("out"), out_type))
    graph.nodes[1].add_input(PortRef(String("in"), in_type))


def test_port_drag_creates_matching_edge() raises:
    """Left-drag from an output port to a matching input port commits an edge."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _two_node_link_graph(graph, Int32(0), Int32(0))

    var out_pos = port_screen_pos(state, graph.nodes[0].copy(), 0, False)
    _begin_no_input(ctx, out_pos.copy(), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.wire_drag_from_node != graph.nodes[0].id:
        _fail("pressing an output port should start wire drag")
    if not state.wire_drag_from_is_output:
        _fail("wire drag should remember output direction")

    var in_pos = port_screen_pos(state, graph.nodes[1].copy(), 0, True)
    _begin_no_input(ctx, in_pos.copy(), False, True, Float32(0.0), Float32(0.0))
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.edge_count() != 1:
        _fail("matching port drag should create exactly one edge")
    if state.wire_drag_from_node != RET_ID_NONE:
        _fail("wire drag should clear after release")
    if graph.edges[0].from_node != graph.nodes[0].id:
        _fail("edge should start at source node")
    if graph.edges[0].to_node != graph.nodes[1].id:
        _fail("edge should end at sink node")
    print("PASS: test_port_drag_creates_matching_edge")


def test_port_drag_rejects_mismatched_type() raises:
    """A dragged wire released on a different typed port should not commit."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _two_node_link_graph(graph, Int32(0), Int32(1))

    var out_pos = port_screen_pos(state, graph.nodes[0].copy(), 0, False)
    _begin_no_input(ctx, out_pos.copy(), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    var in_pos = port_screen_pos(state, graph.nodes[1].copy(), 0, True)
    _begin_no_input(ctx, in_pos.copy(), False, True, Float32(0.0), Float32(0.0))
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.edge_count() != 0:
        _fail("mismatched port type should not create an edge")
    if state.wire_drag_from_node != RET_ID_NONE:
        _fail("wire drag should clear after rejected release")
    print("PASS: test_port_drag_rejects_mismatched_type")


def test_delete_selected_node_removes_node_and_edges() raises:
    """Delete on a selected node removes the node and every attached edge."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    var node_pos = Vec2(Float32(80.0), Float32(70.0))

    _begin_no_input(ctx, node_pos.copy(), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.selected_node != graph.nodes[0].id:
        _fail("left press inside node should select node 0")

    _begin_no_input(ctx, node_pos.copy(), False, False, Float32(0.0), Float32(0.0))
    ctx.input.keys[Int(MOJOUI_KEY_DELETE)].pressed = True
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.node_count() != 1:
        _fail("Delete should remove selected node")
    if graph.edge_count() != 0:
        _fail("removing a node should remove attached edges")
    if state.selected_node != RET_ID_NONE:
        _fail("selected_node should reset after node delete")
    print("PASS: test_delete_selected_node_removes_node_and_edges")


def test_copy_paste_selection_duplicates_internal_edges() raises:
    """Select-all + copy/paste clones selected nodes and edges between them."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    if canvas_select_all(state, graph) != 2:
        _fail("select-all should select both setup nodes")
    if canvas_copy_selection(state, graph) != 2:
        _fail("copy-selection should stage two nodes")
    if canvas_paste_clipboard(state, graph, Vec2(Float32(24.0), Float32(24.0))) != 2:
        _fail("paste should add two copied nodes")
    if graph.node_count() != 4:
        _fail("paste should leave four nodes, got " + String(graph.node_count()))
    if graph.edge_count() != 2:
        _fail("paste should duplicate the internal edge")
    if canvas_selected_count(state) != 2:
        _fail("pasted nodes should become the new selection")
    print("PASS: test_copy_paste_selection_duplicates_internal_edges")


def test_group_selection_creates_region() raises:
    """Grouping selected nodes creates one canvas-owned visual region."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    _ = canvas_select_all(state, graph)
    var gid = canvas_group_selection(state, graph, String("main"))
    if gid != Int64(1):
        _fail("first group id should be 1, got " + String(gid))
    if len(state.groups) != 1:
        _fail("group-selection should append exactly one group")
    if state.groups[0].title != String("main"):
        _fail("group title should be preserved")
    if state.groups[0].rect.w <= Float32(550.0):
        _fail("group rect should cover and pad both nodes")
    print("PASS: test_group_selection_creates_region")


def test_insert_reroute_splits_edge() raises:
    """A selected edge can be split with a compact core/reroute node."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    state.selected_edge = Int32(0)
    var rid = canvas_insert_reroute_on_edge(
        state, graph, 0, Vec2(Float32(250.0), Float32(180.0))
    )
    if rid == RET_ID_NONE:
        _fail("reroute insertion should return a real node id")
    if graph.node_count() != 3:
        _fail("reroute insertion should add one node")
    if graph.edge_count() != 2:
        _fail("reroute insertion should replace one edge with two")
    var idx = graph.find_node(rid)
    if idx < 0:
        _fail("reroute node id should exist in graph")
    if graph.nodes[idx].type_id != String("core/reroute"):
        _fail("reroute node should use core/reroute type")
    if graph.edges[0].to_node != rid or graph.edges[1].from_node != rid:
        _fail("edges should be source->reroute and reroute->target")
    if not canvas_is_node_selected(state, rid):
        _fail("inserted reroute should become selected")
    print("PASS: test_insert_reroute_splits_edge")


def test_selected_node_flags_and_pin_nudge_guard() raises:
    """Selected-node Comfy flags toggle, and pinned nodes resist nudging."""
    var state = CanvasState()
    var graph = Graph()
    var nid = graph.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    _ = canvas_select_all(state, graph)
    _ = canvas_toggle_selected_nodes_mute(state, graph)
    _ = canvas_toggle_selected_nodes_bypass(state, graph)
    _ = canvas_toggle_selected_nodes_collapse(state, graph)
    _ = canvas_toggle_selected_nodes_pin(state, graph)
    if not graph.nodes[0].muted:
        _fail("mute flag should toggle on")
    if not graph.nodes[0].bypassed:
        _fail("bypass flag should toggle on")
    if not graph.nodes[0].collapsed:
        _fail("collapse flag should toggle on")
    if not graph.nodes[0].pinned:
        _fail("pin flag should toggle on")
    var before = graph.nodes[0].position.copy()
    if canvas_nudge_selection(state, graph, Vec2(Float32(10.0), Float32(0.0))) != 0:
        _fail("pinned node should not be nudged")
    if graph.nodes[0].position != before:
        _fail("pinned node position should stay fixed")
    if state.selected_node != nid:
        _fail("selected node should remain primary after flag toggles")
    print("PASS: test_selected_node_flags_and_pin_nudge_guard")


def test_group_fast_toggles_mutate_members() raises:
    """Rgthree-style group controls mute/bypass all bound member nodes."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    _ = canvas_select_all(state, graph)
    var gid = canvas_group_selection(state, graph, String("fast"))
    if gid < Int64(0):
        _fail("group setup should create a group")
    if canvas_toggle_group_nodes_mute(state, graph, gid) != 2:
        _fail("group mute toggle should touch two members")
    if not graph.nodes[0].muted or not graph.nodes[1].muted:
        _fail("group mute toggle should mute both nodes")
    _ = canvas_toggle_group_nodes_mute(state, graph, gid)
    if graph.nodes[0].muted or graph.nodes[1].muted:
        _fail("second group mute toggle should unmute both nodes")
    if canvas_toggle_group_nodes_bypass(state, graph, gid) != 2:
        _fail("group bypass toggle should touch two members")
    if not graph.nodes[0].bypassed or not graph.nodes[1].bypassed:
        _fail("group bypass toggle should bypass both nodes")
    _ = canvas_toggle_group_nodes_bypass(state, graph, gid)
    if graph.nodes[0].bypassed or graph.nodes[1].bypassed:
        _fail("second group bypass toggle should enable both nodes")
    print("PASS: test_group_fast_toggles_mutate_members")


def test_group_output_nodes_collects_queue_targets() raises:
    """Group output collection finds sink nodes for selective queueing."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    _ = canvas_select_all(state, graph)
    var gid = canvas_group_selection(state, graph, String("queue"))
    var outputs = canvas_group_output_nodes(state, graph, gid)
    if len(outputs) != 1:
        _fail("two-node chain should expose one queueable output node")
    if outputs[0] != graph.nodes[1].id:
        _fail("sink node should be the queueable output")

    var save = graph.add_node(String("core/save_image"), Vec2(Float32(700.0), Float32(260.0)))
    graph.nodes[2].add_input(PortRef(String("image"), Int32(1)))
    graph.nodes[1].add_output(PortRef(String("image"), Int32(1)))
    _ = graph.add_edge(graph.nodes[1].id, String("image"), save, String("image"))
    canvas_add_node_to_selection(state, save)
    _ = canvas_group_selection(state, graph, String("save"))
    var outputs2 = canvas_group_output_nodes(state, graph, Int64(2))
    if len(outputs2) != 1:
        _fail("group with explicit save sink should expose one queue target")
    if outputs2[0] != save:
        _fail("explicit save node should be the queue target")
    print("PASS: test_group_output_nodes_collects_queue_targets")


def test_canvas_bookmark_jump_sets_view() raises:
    """Canvas bookmark stores a world target and jumps pan/zoom to it."""
    var state = CanvasState()
    var gid = canvas_add_bookmark(
        state,
        String("hero"),
        String("1"),
        Vec2(Float32(200.0), Float32(100.0)),
        Float32(1.5),
    )
    if gid != Int64(1):
        _fail("first bookmark id should be 1")
    if len(state.bookmarks) != 1:
        _fail("bookmark list should contain one entry")
    if not canvas_jump_to_bookmark(state, gid, Rect(0.0, 0.0, 800.0, 600.0)):
        _fail("jump to existing bookmark should succeed")
    if not _approx_eq(state.zoom, Float32(1.5)):
        _fail("bookmark jump should apply saved zoom")
    if not _approx_eq(state.pan.x, Float32(100.0)):
        _fail("bookmark jump should center x target in viewport")
    if not _approx_eq(state.pan.y, Float32(150.0)):
        _fail("bookmark jump should center y target in viewport")
    if canvas_jump_to_bookmark(state, Int64(99), Rect(0.0, 0.0, 800.0, 600.0)):
        _fail("jump to missing bookmark should fail")
    print("PASS: test_canvas_bookmark_jump_sets_view")


def test_fit_and_zoom_helpers() raises:
    """Fit-selection and cursor zoom adjust retained pan/zoom state."""
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    _ = canvas_select_all(state, graph)
    if not canvas_fit_selection(state, graph, Rect(0.0, 0.0, 800.0, 600.0)):
        _fail("fit-selection should succeed for a non-empty graph")
    var old_zoom = state.zoom
    if not canvas_zoom_at(state, Vec2(Float32(400.0), Float32(300.0)), Float32(1.2)):
        _fail("zoom-at should report a zoom change")
    if state.zoom <= old_zoom:
        _fail("zoom-at with factor >1 should increase zoom")
    print("PASS: test_fit_and_zoom_helpers")


def test_marquee_selects_intersecting_nodes() raises:
    """Dragging on empty canvas selects nodes inside the marquee box."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = graph.add_node(String("test/a"), Vec2(Float32(80.0), Float32(80.0)))
    _ = graph.add_node(String("test/b"), Vec2(Float32(500.0), Float32(350.0)))

    _begin_no_input(ctx, Vec2(Float32(20.0), Float32(70.0)), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(ctx, Vec2(Float32(340.0), Float32(260.0)), False, True, Float32(320.0), Float32(190.0))
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if not canvas_is_node_selected(state, graph.nodes[0].id):
        _fail("marquee should select first node")
    if canvas_is_node_selected(state, graph.nodes[1].id):
        _fail("marquee should not select second node outside box")
    print("PASS: test_marquee_selects_intersecting_nodes")


def test_shift_multi_select_drag_moves_group() raises:
    """Shift-click adds to selection; dragging one selected node moves both."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var a = graph.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    var b = graph.add_node(String("test/b"), Vec2(Float32(300.0), Float32(50.0)))

    _begin_no_input(ctx, Vec2(Float32(100.0), Float32(70.0)), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(ctx, Vec2(Float32(100.0), Float32(70.0)), False, True, Float32(0.0), Float32(0.0))
    _set_mouse_button_state(ctx, 0, False, False, True)
    var widths1r = List[Int32]()
    widths1r.append(Int32(800))
    ctx.layout_row(widths1r^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(ctx, Vec2(Float32(330.0), Float32(70.0)), True, False, Float32(0.0), Float32(0.0), True)
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    _begin_no_input(ctx, Vec2(Float32(330.0), Float32(70.0)), False, True, Float32(0.0), Float32(0.0), True)
    _set_mouse_button_state(ctx, 0, False, False, True)
    var widths2r = List[Int32]()
    widths2r.append(Int32(800))
    ctx.layout_row(widths2r^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if canvas_selected_count(state) != 2:
        _fail("shift-click should leave two selected nodes")
    if not canvas_is_node_selected(state, a) or not canvas_is_node_selected(state, b):
        _fail("both nodes should be selected after shift-click")

    _begin_no_input(ctx, Vec2(Float32(100.0), Float32(70.0)), True, False, Float32(0.0), Float32(0.0))
    var widths3 = List[Int32]()
    widths3.append(Int32(800))
    ctx.layout_row(widths3^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()
    if graph.nodes[0].position != Vec2(Float32(50.0), Float32(50.0)):
        _fail(
            "drag-start press moved A unexpectedly to "
            + String(graph.nodes[0].position)
            + " offset="
            + String(state.drag_offset)
            + " dragging="
            + String(state.dragging_node)
            + " pan="
            + String(state.pan)
        )

    _begin_no_input(ctx, Vec2(Float32(120.0), Float32(90.0)), False, False, Float32(20.0), Float32(20.0))
    _set_mouse_button_state(ctx, 0, False, True, False)
    var widths4 = List[Int32]()
    widths4.append(Int32(800))
    ctx.layout_row(widths4^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if graph.nodes[0].position != Vec2(Float32(70.0), Float32(70.0)):
        _fail(
            "dragging selected node A should move A by (20,20), got "
            + String(graph.nodes[0].position)
        )
    if graph.nodes[1].position != Vec2(Float32(320.0), Float32(70.0)):
        _fail(
            "dragging selected node A should also move selected node B, got "
            + String(graph.nodes[1].position)
        )
    print("PASS: test_shift_multi_select_drag_moves_group")


def test_group_header_drag_moves_members() raises:
    """Clicking a group header selects members; dragging moves the group."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _two_node_wired_graph(graph)
    _ = canvas_select_all(state, graph)
    var group_id = canvas_group_selection(state, graph, String("main"))
    if group_id < Int64(0):
        _fail("group setup should create a group")
    state.groups[0].rect.y = Float32(80.0)
    var original_group = state.groups[0].rect.copy()

    _begin_no_input(ctx, Vec2(Float32(40.0), Float32(95.0)), True, False, Float32(0.0), Float32(0.0))
    var widths1 = List[Int32]()
    widths1.append(Int32(800))
    ctx.layout_row(widths1^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.selected_group != group_id:
        _fail("group header click should select the group")
    if canvas_selected_count(state) != 2:
        _fail("group header click should select bound member nodes")

    _begin_no_input(ctx, Vec2(Float32(60.0), Float32(115.0)), False, False, Float32(20.0), Float32(20.0))
    _set_mouse_button_state(ctx, 0, False, True, False)
    var widths2 = List[Int32]()
    widths2.append(Int32(800))
    ctx.layout_row(widths2^, Int32(600))
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if state.groups[0].rect.x != original_group.x + Float32(20.0):
        _fail("group rect should move by drag delta")
    if graph.nodes[0].position != Vec2(Float32(70.0), Float32(70.0)):
        _fail("group drag should move first member node")
    if graph.nodes[1].position != Vec2(Float32(420.0), Float32(280.0)):
        _fail("group drag should move second member node")
    print("PASS: test_group_header_drag_moves_members")


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
    test_inline_field_edit_commits_number()
    test_bbox_drag_updates_elements_data()
    test_bbox_empty_stage_click_adds_box()
    test_bbox_resize_handle_updates_size()
    test_bbox_label_chip_edit_commits_label()
    test_delete_selected_bbox_does_not_delete_node()
    test_canvas_generate_action_button_sets_request()
    test_hovered_edge_hit_and_miss()
    test_wire_select_then_delete()
    test_port_drag_creates_matching_edge()
    test_port_drag_rejects_mismatched_type()
    test_delete_selected_node_removes_node_and_edges()
    test_copy_paste_selection_duplicates_internal_edges()
    test_group_selection_creates_region()
    test_insert_reroute_splits_edge()
    test_selected_node_flags_and_pin_nudge_guard()
    test_group_fast_toggles_mutate_members()
    test_group_output_nodes_collects_queue_targets()
    test_canvas_bookmark_jump_sets_view()
    test_fit_and_zoom_helpers()
    test_marquee_selects_intersecting_nodes()
    test_shift_multi_select_drag_moves_group()
    test_group_header_drag_moves_members()
    print("PASS: all 33 smoke tests")
