"""Tests for the per-node right-click context menu — Delete/Duplicate/Rename/Color.

Run: `pixi run test-node-menu`

Pure `mojo run` (no FFI): `node_menu` → `widgets/context_menu` → `popup`
only touch the popup layer + control SM, all driven via
`begin_frame_no_input`. The two-frame press→release click pattern is
copied from `tests/widgets/test_menu_system.mojo`.

Covers:
  1. Canvas right-click over a node opens the context menu (state set).
  2. Delete dispatch removes the node AND its edges.
  3. Duplicate dispatch adds a fresh offset copy, selects it.
  4. Rename dispatch sets `renaming_node` and leaves the graph intact.
  5. Color swatch dispatch writes the selected `ui_color`.
  6. Closed menu renders nothing / returns NODE_ACTION_NONE.
"""

from mojoui.core.types import Vec2
from mojoui.core.context import Context
from mojoui.core.id import RET_ID_NONE
from mojoui.render.ffi import MOJOUI_BTN_RIGHT
from mojoui.nodes.node import FK_STRING, PortRef
from mojoui.nodes.graph import Graph
from mojoui.nodes.canvas import CanvasState, begin_node_canvas, end_node_canvas
from mojoui.nodes.node_menu import (
    node_context_menu,
    NODE_ACTION_NONE,
    NODE_ACTION_DELETE,
    NODE_ACTION_DUPLICATE,
    NODE_ACTION_RENAME,
    NODE_ACTION_COLOR,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _win() -> Vec2:
    return Vec2(Float32(800.0), Float32(600.0))


def _full_row(mut ctx: Context):
    """Lay out one full-window row so begin_node_canvas's layout_next gets
    a sane viewport rect."""
    var widths = List[Int32]()
    widths.append(Int32(800))
    ctx.layout_row(widths^, Int32(600))


def _two_node_graph(mut graph: Graph) -> List[UInt64]:
    """A→B with one edge out→in. Returns [a_id, b_id]."""
    var a = graph.add_node(String("test/a"), Vec2(Float32(50.0), Float32(50.0)))
    var b = graph.add_node(
        String("test/b"), Vec2(Float32(300.0), Float32(200.0))
    )
    graph.nodes[0].add_output(PortRef(String("out"), Int32(0)))
    graph.nodes[1].add_input(PortRef(String("in"), Int32(0)))
    _ = graph.add_edge(a, String("out"), b, String("in"))
    var ids = List[UInt64]()
    ids.append(a)
    ids.append(b)
    return ids^


# ----------------------------------------------------------------------------
# 1. Right-click over a node opens the context menu
# ----------------------------------------------------------------------------


def test_right_click_node_opens_menu() raises:
    """RMB press inside a node body sets ctx_menu_open + ctx_menu_node +
    anchor, and selects the node."""
    var ctx = Context()
    ctx.begin_frame_no_input(_win(), Vec2(100.0, 70.0), False, False)
    # Synthesize a right-button press (begin_frame_no_input does not sync
    # per-button slots — same pattern as test_menu_system._set_right_button).
    ctx.input.mouse[Int(MOJOUI_BTN_RIGHT)].pressed = True
    _full_row(ctx)
    var state = CanvasState()
    var graph = Graph()
    var nid = graph.add_node(
        String("test/a"), Vec2(Float32(50.0), Float32(50.0))
    )
    _ = begin_node_canvas(ctx, String("c"), state, graph)
    end_node_canvas(ctx)
    ctx.end_frame()

    if not state.ctx_menu_open:
        _fail("right-click over node should open ctx menu")
    if state.ctx_menu_node != nid:
        _fail("ctx_menu_node should be the right-clicked node")
    if state.selected_node != nid:
        _fail("right-click should also select the node")
    if not (
        state.ctx_menu_anchor.x == Float32(100.0)
        and state.ctx_menu_anchor.y == Float32(70.0)
    ):
        _fail("anchor should be the cursor pos, got " + String(state.ctx_menu_anchor))
    print("PASS: test_right_click_node_opens_menu")


# ----------------------------------------------------------------------------
# 2. Delete dispatch removes node + edges
# ----------------------------------------------------------------------------


def test_delete_removes_node_and_edges() raises:
    """Clicking 'Delete' (row 0) removes the target node and every edge
    touching it."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var ids = _two_node_graph(graph)
    var a = ids[0]
    if graph.edge_count() != 1:
        _fail("setup should have 1 edge")

    state.ctx_menu_open = True
    state.ctx_menu_node = a
    state.selected_node = a
    state.ctx_menu_anchor = Vec2(Float32(0.0), Float32(24.0))

    # Row 0 (Delete) spans y 24..48; y=30 lands in it.
    # Frame 1: press inside row 0.
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 30.0), True, False)
    _ = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()
    # Frame 2: release inside row 0 → dispatch.
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 30.0), False, True)
    var act = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()

    if act != NODE_ACTION_DELETE:
        _fail("row 0 release should dispatch DELETE, got " + String(act))
    if graph.find_node(a) >= 0:
        _fail("node should be removed after Delete")
    if graph.edge_count() != 0:
        _fail("edge touching deleted node should be gone")
    if state.selected_node != RET_ID_NONE:
        _fail("selection of deleted node should clear")
    if state.ctx_menu_open:
        _fail("menu should close after dispatch")
    print("PASS: test_delete_removes_node_and_edges")


# ----------------------------------------------------------------------------
# 3. Duplicate dispatch clones node at offset, selects copy
# ----------------------------------------------------------------------------


def test_duplicate_clones_and_selects() raises:
    """Clicking 'Duplicate' (row 1) adds a fresh offset copy with a new id
    and selects it. Edge count unchanged (copy has no wires)."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var ids = _two_node_graph(graph)
    var a = ids[0]
    var b = ids[1]
    var before = graph.node_count()

    state.ctx_menu_open = True
    state.ctx_menu_node = a
    state.ctx_menu_anchor = Vec2(Float32(0.0), Float32(24.0))

    # Row 1 (Duplicate) spans y 48..72; y=60 lands in it.
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 60.0), True, False)
    _ = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 60.0), False, True)
    var act = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()

    if act != NODE_ACTION_DUPLICATE:
        _fail("row 1 release should dispatch DUPLICATE, got " + String(act))
    if graph.node_count() != before + 1:
        _fail("duplicate should add exactly one node")
    if graph.edge_count() != 1:
        _fail("duplicate must not add or drop edges")
    if state.selected_node == a or state.selected_node == b:
        _fail("the duplicated copy should become the selection")
    if state.selected_node == RET_ID_NONE:
        _fail("a fresh node should be selected after duplicate")
    # The copy sits at the source position + offset (50+24, 50+24).
    var copy_idx = graph.find_node(state.selected_node)
    if copy_idx < 0:
        _fail("selected copy id should exist in graph")
    var cp = graph.nodes[copy_idx].position.copy()
    if not (cp.x == Float32(74.0) and cp.y == Float32(74.0)):
        _fail("copy should be offset by (24,24), got " + String(cp))
    print("PASS: test_duplicate_clones_and_selects")


# ----------------------------------------------------------------------------
# 4. Rename dispatch sets renaming_node, leaves graph intact
# ----------------------------------------------------------------------------


def test_rename_sets_flag_only() raises:
    """Clicking 'Rename' (row 2) sets renaming_node to the target and does
    NOT mutate the graph (the live app overlays a text_edit)."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var ids = _two_node_graph(graph)
    var a = ids[0]
    var before = graph.node_count()

    state.ctx_menu_open = True
    state.ctx_menu_node = a
    state.ctx_menu_anchor = Vec2(Float32(0.0), Float32(24.0))

    # Row 2 (Rename) spans y 72..96; y=84 lands in it.
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 84.0), True, False)
    _ = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 84.0), False, True)
    var act = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()

    if act != NODE_ACTION_RENAME:
        _fail("row 2 release should dispatch RENAME, got " + String(act))
    if state.renaming_node != a:
        _fail("renaming_node should be the target node")
    if graph.node_count() != before:
        _fail("rename must not change node count")
    if graph.find_node(a) < 0:
        _fail("renamed node must still exist")
    print("PASS: test_rename_sets_flag_only")


# ----------------------------------------------------------------------------
# 5. Color swatch dispatch writes ui_color
# ----------------------------------------------------------------------------


def test_color_swatch_sets_ui_color() raises:
    """Clicking the Gold swatch writes `ui_color = "gold"` and returns the
    stable NODE_ACTION_COLOR action."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    var ids = _two_node_graph(graph)
    var a = ids[0]

    state.ctx_menu_open = True
    state.ctx_menu_node = a
    state.ctx_menu_anchor = Vec2(Float32(0.0), Float32(24.0))

    # Rows: Delete, Duplicate, Rename, Default, Gold.
    # Gold spans y 120..144 when row_height=24; y=132 lands in it.
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 132.0), True, False)
    _ = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 132.0), False, True)
    var act = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()

    if act != NODE_ACTION_COLOR:
        _fail("gold row release should dispatch COLOR, got " + String(act))
    var idx = graph.find_node(a)
    if idx < 0:
        _fail("target node should still exist")
    if not (String("ui_color") in graph.nodes[idx].fields):
        _fail("color selection should set ui_color field")
    var fv = graph.nodes[idx].fields[String("ui_color")].copy()
    if fv.kind != FK_STRING:
        _fail("ui_color should be stored as string field")
    if fv.str_val != String("gold"):
        _fail("ui_color should be gold, got " + fv.str_val.copy())
    if state.ctx_menu_open:
        _fail("menu should close after color dispatch")
    print("PASS: test_color_swatch_sets_ui_color")


# ----------------------------------------------------------------------------
# 6. Closed menu is a no-op
# ----------------------------------------------------------------------------


def test_closed_menu_is_noop() raises:
    """When ctx_menu_open is False, node_context_menu returns NONE and
    touches nothing."""
    var ctx = Context()
    var state = CanvasState()
    var graph = Graph()
    _ = _two_node_graph(graph)
    ctx.begin_frame_no_input(_win(), Vec2(50.0, 60.0), False, False)
    var act = node_context_menu(ctx, String("node_ctx"), state, graph)
    ctx.end_frame()
    if act != NODE_ACTION_NONE:
        _fail("closed menu should return NODE_ACTION_NONE")
    if graph.node_count() != 2:
        _fail("closed menu should not mutate graph")
    print("PASS: test_closed_menu_is_noop")


def main() raises:
    test_right_click_node_opens_menu()
    test_delete_removes_node_and_edges()
    test_duplicate_clones_and_selects()
    test_rename_sets_flag_only()
    test_color_swatch_sets_ui_color()
    test_closed_menu_is_noop()
    print("PASS: all 6 node-menu tests")
