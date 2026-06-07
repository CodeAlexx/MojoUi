"""Canvas model/state helpers for the reusable node graph canvas.

Kept separate from `canvas.mojo` so rendering/input code stays small enough
for Mojo builds while future apps can reuse selection, grouping, clipboard,
fit, zoom, and wire-drag model behavior without pulling in drawing code.
"""

from std.math import floor, sqrt
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.core.textedit import TextEditState
from mojoui.nodes.node import Node, PortRef
from mojoui.nodes.graph import Graph, Edge


# Shared world-space geometry defaults. `canvas.mojo` keeps local visual
# aliases with the same values for renderer-only drawing code.
comptime _TITLE_BAR_H: Float32 = 24.0
comptime _PORT_SPACING: Float32 = 20.0
comptime _PORT_HIT_RADIUS: Float32 = 9.0
comptime _SNAP_GRID_WORLD: Float32 = 20.0
comptime _PASTE_OFFSET_WORLD: Float32 = 24.0
comptime _ZOOM_MIN: Float32 = 0.20
comptime _ZOOM_MAX: Float32 = 3.00
comptime _FIT_PADDING: Float32 = 80.0
comptime _GROUP_PADDING: Float32 = 28.0

# CanvasState — retained per-canvas state
# ============================================================================


struct CanvasGroup(Copyable, Movable):
    """Visual group/region in canvas world-space.

    Comfy stores groups as graph UI objects. MojoUI keeps them in
    `CanvasState` for now so workflow execution and serde remain stable
    while apps get reusable region drawing and group-selection behavior.
    """

    var id: Int64
    var title: String
    var rect: Rect
    var color: Color
    var members: List[RetainedId]
    var collapsed: Bool
    var selected: Bool

    def __init__(out self, id: Int64, title: String, rect: Rect, color: Color):
        self.id = id
        self.title = title.copy()
        self.rect = rect.copy()
        self.color = color.copy()
        self.members = List[RetainedId]()
        self.collapsed = False
        self.selected = False


struct CanvasBookmark(Copyable, Movable):
    """Saved canvas view target inspired by rgthree bookmarks.

    SerenityUI can store lightweight navigation anchors without requiring a
    virtual graph node. `center` is world-space, while `zoom` is the target
    affine scale used by `canvas_jump_to_bookmark`.
    """

    var id: Int64
    var title: String
    var shortcut: String
    var center: Vec2
    var zoom: Float32

    def __init__(
        out self,
        id: Int64,
        title: String,
        shortcut: String,
        center: Vec2,
        zoom: Float32,
    ):
        self.id = id
        self.title = title.copy()
        self.shortcut = shortcut.copy()
        self.center = center.copy()
        self.zoom = zoom


struct CanvasState(Movable):
    """Per-canvas mutable state — persists across frames (retained).

    Owned by the application; threaded into `begin_node_canvas` by `mut`
    reference. `Movable` only — copy semantics make no sense for "active
    drag in progress" (would alias the drag across canvases).

    LinkDrag fields (`wire_drag_from_*`) track the currently dragged wire
    source port until mouse release commits or rejects the connection.
    """

    var pan: Vec2
    """Screen-space offset of the world origin. Mutated by middle-button
    drag. `screen = world * zoom + pan`."""

    var zoom: Float32
    """Affine scale factor. 1.0 = no scaling; >1 zooms in. Mouse-wheel
    zoom is M3."""

    var dragging_node: RetainedId
    """Id of the node currently being dragged, or `RET_ID_NONE`. Set on
    `CTRL_PRESSED` over a node body; cleared on LEFT-button release."""

    var drag_offset: Vec2
    """Mouse-pos minus node-screen-top-left at drag start; used each
    frame to keep the click point under the cursor."""

    var selected_node: RetainedId
    """Single-select for M2.5 — never auto-cleared (M3 clears on
    background click). Set on every successful node press."""

    var wire_drag_from_node: RetainedId
    """Source node for an in-progress port-to-port wire drag."""

    var wire_drag_from_port: String
    """Source port name for an in-progress port-to-port wire drag."""

    var wire_drag_from_is_output: Bool
    """True when the drag source is an output port; false for input."""

    var wire_drag_from_type: Int32
    """Value-type tag for the drag source port. Used by LinkDrag to reject
    incompatible ports before committing an edge."""

    var ctx_menu_open: Bool
    """True while the per-node right-click context menu is showing. Set
    when RMB is pressed over a node body; cleared by the menu widget on
    item-click or click-outside (see `node_menu.node_context_menu`)."""

    var ctx_menu_anchor: Vec2
    """Window-space top-left for the open context menu — the point where
    the user right-clicked."""

    var ctx_menu_node: RetainedId
    """Id of the node the open context menu targets, or `RET_ID_NONE`."""

    var renaming_node: RetainedId
    """Id of the node currently being renamed (set when the context
    menu's Rename item is chosen), or `RET_ID_NONE`. The canvas itself
    does NOT draw the rename text field — that pulls the FFI-backed
    `text_edit` into the pure node layer. A live app overlays a
    `text_edit` bound to `graph.nodes[i].title` while this is set, then
    clears it. Pure-Mojo callers/tests just observe the flag."""

    var selected_edge: Int32
    """List index of the currently-selected wire, or -1. Selection is
    by index (stable while the edge list is unmutated); cleared to -1 on
    any structural change (node press, edge delete)."""

    var hovered_edge: Int32
    """List index of the wire under the cursor this frame, or -1.
    Recomputed every frame in `begin_node_canvas`; drives the thicker
    hover stroke. Not persisted across frames in any meaningful way."""

    var selected_nodes: List[RetainedId]
    """Multi-select set. `selected_node` remains the primary/last-selected
    id for backward compatibility with existing app code."""

    var resizing_node: RetainedId
    """Node currently being resized from its bottom-right handle."""

    var resize_start_mouse_world: Vec2
    var resize_start_size: Vec2
    """World-space mouse and node size captured at resize start."""

    var marquee_active: Bool
    """True while an empty-canvas left drag is drawing a selection box."""

    var marquee_start: Vec2
    var marquee_end: Vec2
    """Screen-space marquee endpoints."""

    var drag_last_world: Vec2
    """Last primary-node world position during a group drag."""

    var snap_to_grid: Bool
    """When true, node drag/nudge snaps to `snap_grid` even without Shift."""

    var snap_grid: Float32
    """World-space grid size for snapping and large keyboard nudge."""

    var show_links: Bool
    """False hides wires without deleting graph edges."""

    var show_minimap: Bool
    """Draw a compact minimap in the canvas corner."""

    var locked: Bool
    """When true, selection/view can still change but graph structure and
    node positions are protected from canvas edits."""

    var groups: List[CanvasGroup]
    """Visual regions/groups drawn behind nodes."""

    var next_group_id: Int64

    var selected_group: Int64
    """Currently selected canvas group id, or -1."""

    var dragging_group: Int64
    """Group title currently being dragged, or -1."""

    var drag_group_last_world: Vec2
    """Last cursor world position while dragging a group."""

    var bookmarks: List[CanvasBookmark]
    """Saved canvas view bookmarks for quick workflow navigation."""

    var next_bookmark_id: Int64

    var editing_field_node: RetainedId
    """Node whose field is currently being edited inline, or RET_ID_NONE."""

    var editing_field_name: String
    var editing_field_buffer: String
    var editing_field_kind: Int32
    var editing_field_state: TextEditState

    var bbox_selected_node: RetainedId
    var bbox_selected_index: Int64
    var bbox_drag_node: RetainedId
    var bbox_drag_index: Int64
    var bbox_drag_mode: Int32
    var bbox_drag_start_mouse: Vec2
    var bbox_drag_start_rect: Rect
    var bbox_edit_node: RetainedId
    var bbox_edit_index: Int64
    var bbox_edit_buffer: String
    var bbox_edit_state: TextEditState

    var generate_requested: Bool
    """One-frame canvas action flag set by the reusable Generate button."""

    var add_image_requested: Bool
    """One-frame action flag for apps that want to spawn/import an image node."""

    var import_json_requested: Bool
    """One-frame action flag for apps that expose workflow JSON import."""

    var action_anchor_world: Vec2
    """World-space placement hint for action buttons that add graph content."""

    var clipboard_nodes: List[Node]
    var clipboard_edges: List[Edge]
    """In-memory graph clipboard used by reusable copy/paste helpers.
    It is intentionally app-local rather than OS clipboard-backed."""

    def __init__(out self):
        """Default — origin pan, identity zoom, no drag, no selection."""
        self.pan = Vec2.zero()
        self.zoom = Float32(1.0)
        self.dragging_node = RET_ID_NONE
        self.drag_offset = Vec2.zero()
        self.selected_node = RET_ID_NONE
        self.resizing_node = RET_ID_NONE
        self.resize_start_mouse_world = Vec2.zero()
        self.resize_start_size = Vec2.zero()
        self.wire_drag_from_node = RET_ID_NONE
        self.wire_drag_from_port = String("")
        self.wire_drag_from_is_output = False
        self.wire_drag_from_type = Int32(-1)
        self.ctx_menu_open = False
        self.ctx_menu_anchor = Vec2.zero()
        self.ctx_menu_node = RET_ID_NONE
        self.renaming_node = RET_ID_NONE
        self.selected_edge = Int32(-1)
        self.hovered_edge = Int32(-1)
        self.selected_nodes = List[RetainedId]()
        self.marquee_active = False
        self.marquee_start = Vec2.zero()
        self.marquee_end = Vec2.zero()
        self.drag_last_world = Vec2.zero()
        self.snap_to_grid = False
        self.snap_grid = _SNAP_GRID_WORLD
        self.show_links = True
        self.show_minimap = False
        self.locked = False
        self.groups = List[CanvasGroup]()
        self.next_group_id = Int64(1)
        self.selected_group = Int64(-1)
        self.dragging_group = Int64(-1)
        self.drag_group_last_world = Vec2.zero()
        self.bookmarks = List[CanvasBookmark]()
        self.next_bookmark_id = Int64(1)
        self.editing_field_node = RET_ID_NONE
        self.editing_field_name = String("")
        self.editing_field_buffer = String("")
        self.editing_field_kind = Int32(0)
        self.editing_field_state = TextEditState(single_line=True)
        self.bbox_selected_node = RET_ID_NONE
        self.bbox_selected_index = Int64(-1)
        self.bbox_drag_node = RET_ID_NONE
        self.bbox_drag_index = Int64(-1)
        self.bbox_drag_mode = Int32(0)
        self.bbox_drag_start_mouse = Vec2.zero()
        self.bbox_drag_start_rect = Rect()
        self.bbox_edit_node = RET_ID_NONE
        self.bbox_edit_index = Int64(-1)
        self.bbox_edit_buffer = String("")
        self.bbox_edit_state = TextEditState(single_line=True)
        self.generate_requested = False
        self.add_image_requested = False
        self.import_json_requested = False
        self.action_anchor_world = Vec2.zero()
        self.clipboard_nodes = List[Node]()
        self.clipboard_edges = List[Edge]()


# ============================================================================
# Transform helpers
# ============================================================================


def canvas_world_to_screen(state: CanvasState, world: Vec2) -> Vec2:
    """Affine world→screen: `screen = world * zoom + pan`."""
    return Vec2(world.x * state.zoom + state.pan.x, world.y * state.zoom + state.pan.y)


def canvas_screen_to_world(state: CanvasState, screen: Vec2) -> Vec2:
    """Inverse of `canvas_world_to_screen`. Guards against divide-by-zero
    in the degenerate `zoom == 0` case (returns origin)."""
    if state.zoom == Float32(0.0):
        return Vec2.zero()
    return Vec2(
        (screen.x - state.pan.x) / state.zoom,
        (screen.y - state.pan.y) / state.zoom,
    )


def _clamp_zoom(z: Float32) -> Float32:
    var out = z
    if out < _ZOOM_MIN:
        out = _ZOOM_MIN
    if out > _ZOOM_MAX:
        out = _ZOOM_MAX
    return out


def canvas_snap_world(pos: Vec2, grid: Float32) -> Vec2:
    """Snap a world-space point to the nearest grid cell."""
    if grid <= Float32(0.0):
        return pos.copy()
    return Vec2(
        floor(pos.x / grid + Float32(0.5)) * grid,
        floor(pos.y / grid + Float32(0.5)) * grid,
    )


def canvas_zoom_at(mut state: CanvasState, pivot_screen: Vec2, factor: Float32) -> Bool:
    """Zoom around `pivot_screen` while keeping the world point under the
    cursor fixed. Returns True when zoom changed."""
    var old_zoom = state.zoom
    var next_zoom = _clamp_zoom(old_zoom * factor)
    if next_zoom == old_zoom:
        return False
    var world = canvas_screen_to_world(state, pivot_screen.copy())
    state.zoom = next_zoom
    state.pan = Vec2(
        pivot_screen.x - world.x * state.zoom,
        pivot_screen.y - world.y * state.zoom,
    )
    return True


def canvas_reset_view(mut state: CanvasState):
    state.pan = Vec2.zero()
    state.zoom = Float32(1.0)


def _rect_from_points(a: Vec2, b: Vec2) -> Rect:
    var x0 = a.x
    var y0 = a.y
    var x1 = b.x
    var y1 = b.y
    if x1 < x0:
        var tmp = x0
        x0 = x1
        x1 = tmp
    if y1 < y0:
        var tmp_y = y0
        y0 = y1
        y1 = tmp_y
    return Rect(x0, y0, x1 - x0, y1 - y0)


def _node_world_rect(node: Node) -> Rect:
    return Rect(node.position.x, node.position.y, node.size.x, node.size.y)


def _node_screen_rect(state: CanvasState, node: Node) -> Rect:
    var pos = canvas_world_to_screen(state, node.position.copy())
    return Rect(pos.x, pos.y, node.size.x * state.zoom, node.size.y * state.zoom)


def canvas_is_node_selected(state: CanvasState, node_id: RetainedId) -> Bool:
    if node_id == RET_ID_NONE:
        return False
    if state.selected_node == node_id:
        return True
    for i in range(len(state.selected_nodes)):
        if state.selected_nodes[i] == node_id:
            return True
    return False


def _selection_list_has(state: CanvasState, node_id: RetainedId) -> Bool:
    for i in range(len(state.selected_nodes)):
        if state.selected_nodes[i] == node_id:
            return True
    return False


def canvas_selected_count(state: CanvasState) -> Int:
    var n = len(state.selected_nodes)
    if n == 0 and state.selected_node != RET_ID_NONE:
        return 1
    return n


def canvas_clear_selection(mut state: CanvasState):
    state.selected_nodes = List[RetainedId]()
    state.selected_node = RET_ID_NONE
    state.selected_edge = Int32(-1)
    state.selected_group = Int64(-1)


def canvas_add_node_to_selection(mut state: CanvasState, node_id: RetainedId):
    if node_id == RET_ID_NONE:
        return
    if not canvas_is_node_selected(state, node_id):
        state.selected_nodes.append(node_id)
    state.selected_node = node_id
    state.selected_edge = Int32(-1)


def canvas_remove_node_from_selection(mut state: CanvasState, node_id: RetainedId):
    var out = List[RetainedId]()
    for i in range(len(state.selected_nodes)):
        if state.selected_nodes[i] != node_id:
            out.append(state.selected_nodes[i])
    state.selected_nodes = out^
    if state.selected_node == node_id:
        state.selected_node = RET_ID_NONE
        if len(state.selected_nodes) > 0:
            state.selected_node = state.selected_nodes[len(state.selected_nodes) - 1]


def canvas_toggle_node_selection(mut state: CanvasState, node_id: RetainedId):
    if canvas_is_node_selected(state, node_id):
        canvas_remove_node_from_selection(state, node_id)
    else:
        canvas_add_node_to_selection(state, node_id)


def canvas_set_single_selection(mut state: CanvasState, node_id: RetainedId):
    canvas_clear_selection(state)
    canvas_add_node_to_selection(state, node_id)


def _ensure_primary_in_selection(mut state: CanvasState):
    if state.selected_node != RET_ID_NONE and not _selection_list_has(
        state, state.selected_node
    ):
        state.selected_nodes.append(state.selected_node)


def canvas_select_all(mut state: CanvasState, graph: Graph) -> Int:
    canvas_clear_selection(state)
    for i in range(graph.node_count()):
        canvas_add_node_to_selection(state, graph.nodes[i].id)
    return len(state.selected_nodes)


def canvas_selection_bounds(state: CanvasState, graph: Graph) -> Tuple[Bool, Rect]:
    var found = False
    var bounds = Rect()
    for i in range(graph.node_count()):
        var node = graph.nodes[i].copy()
        if canvas_is_node_selected(state, node.id):
            var nr = _node_world_rect(node)
            if not found:
                bounds = nr.copy()
                found = True
            else:
                bounds = bounds.union(nr.copy())
    return (found, bounds.copy())


def canvas_all_nodes_bounds(graph: Graph) -> Tuple[Bool, Rect]:
    var found = False
    var bounds = Rect()
    for i in range(graph.node_count()):
        var nr = _node_world_rect(graph.nodes[i].copy())
        if not found:
            bounds = nr.copy()
            found = True
        else:
            bounds = bounds.union(nr.copy())
    return (found, bounds.copy())


def canvas_fit_rect(
    mut state: CanvasState, world_rect: Rect, viewport: Rect, padding: Float32
):
    if viewport.w <= Float32(0.0) or viewport.h <= Float32(0.0):
        return
    var rw = world_rect.w
    var rh = world_rect.h
    if rw < Float32(1.0):
        rw = Float32(1.0)
    if rh < Float32(1.0):
        rh = Float32(1.0)
    var avail_w = viewport.w - padding * Float32(2.0)
    var avail_h = viewport.h - padding * Float32(2.0)
    if avail_w < Float32(32.0):
        avail_w = viewport.w
    if avail_h < Float32(32.0):
        avail_h = viewport.h
    var zx = avail_w / rw
    var zy = avail_h / rh
    var z = zx
    if zy < z:
        z = zy
    state.zoom = _clamp_zoom(z)
    var c = world_rect.center()
    state.pan = Vec2(
        viewport.x + viewport.w * Float32(0.5) - c.x * state.zoom,
        viewport.y + viewport.h * Float32(0.5) - c.y * state.zoom,
    )


def canvas_fit_selection(mut state: CanvasState, graph: Graph, viewport: Rect) -> Bool:
    var result = canvas_selection_bounds(state, graph)
    if not result[0]:
        result = canvas_all_nodes_bounds(graph)
    if not result[0]:
        canvas_reset_view(state)
        return False
    canvas_fit_rect(state, result[1], viewport.copy(), _FIT_PADDING)
    return True


def canvas_nudge_selection(
    mut state: CanvasState, mut graph: Graph, delta: Vec2
) -> Int:
    _ensure_primary_in_selection(state)
    var moved = 0
    for i in range(graph.node_count()):
        if canvas_is_node_selected(state, graph.nodes[i].id) and not graph.nodes[i].pinned:
            graph.nodes[i].position = Vec2(
                graph.nodes[i].position.x + delta.x,
                graph.nodes[i].position.y + delta.y,
            )
            moved = moved + 1
    return moved


def canvas_copy_selection(mut state: CanvasState, graph: Graph) -> Int:
    _ensure_primary_in_selection(state)
    state.clipboard_nodes = List[Node]()
    state.clipboard_edges = List[Edge]()
    for i in range(graph.node_count()):
        if canvas_is_node_selected(state, graph.nodes[i].id):
            state.clipboard_nodes.append(graph.nodes[i].copy())
    for i in range(graph.edge_count()):
        var e = graph.edges[i].copy()
        if canvas_is_node_selected(state, e.from_node) and canvas_is_node_selected(
            state, e.to_node
        ):
            state.clipboard_edges.append(e^)
    return len(state.clipboard_nodes)


def canvas_paste_clipboard(
    mut state: CanvasState, mut graph: Graph, offset: Vec2
) raises -> Int:
    if len(state.clipboard_nodes) == 0:
        return 0
    var id_map = Dict[RetainedId, RetainedId]()
    canvas_clear_selection(state)
    for i in range(len(state.clipboard_nodes)):
        var clone = state.clipboard_nodes[i].copy()
        var old_id = clone.id
        clone.position = Vec2(clone.position.x + offset.x, clone.position.y + offset.y)
        var new_id = graph.add_built_node(clone)
        id_map[old_id] = new_id
        canvas_add_node_to_selection(state, new_id)
    for i in range(len(state.clipboard_edges)):
        var e = state.clipboard_edges[i].copy()
        if e.from_node in id_map and e.to_node in id_map:
            _ = graph.add_edge(
                id_map[e.from_node],
                e.from_port.copy(),
                id_map[e.to_node],
                e.to_port.copy(),
            )
    return len(state.clipboard_nodes)


def canvas_duplicate_selection(mut state: CanvasState, mut graph: Graph) raises -> Int:
    var copied = canvas_copy_selection(state, graph)
    if copied == 0:
        return 0
    return canvas_paste_clipboard(
        state, graph, Vec2(_PASTE_OFFSET_WORLD, _PASTE_OFFSET_WORLD)
    )


def canvas_delete_selection(mut state: CanvasState, mut graph: Graph) -> Int:
    if state.selected_edge >= Int32(0):
        graph.remove_edge_at(Int(state.selected_edge))
        state.selected_edge = Int32(-1)
        state.hovered_edge = Int32(-1)
        return 1
    _ensure_primary_in_selection(state)
    var removed = 0
    for i in range(len(state.selected_nodes)):
        var nid = state.selected_nodes[i]
        var idx = graph.find_node(nid)
        if idx >= 0 and not graph.nodes[idx].pinned:
            graph.remove_node(nid)
            removed = removed + 1
    if removed > 0:
        canvas_clear_selection(state)
        state.dragging_node = RET_ID_NONE
        state.resizing_node = RET_ID_NONE
        state.dragging_group = Int64(-1)
        _clear_wire_drag(state)
    return removed


def _group_index(state: CanvasState, group_id: Int64) -> Int:
    for i in range(len(state.groups)):
        if state.groups[i].id == group_id:
            return i
    return -1


def _group_member_has(group: CanvasGroup, node_id: RetainedId) -> Bool:
    for i in range(len(group.members)):
        if group.members[i] == node_id:
            return True
    return False


def _group_append_member(mut group: CanvasGroup, node_id: RetainedId) -> Bool:
    if node_id == RET_ID_NONE:
        return False
    if _group_member_has(group, node_id):
        return False
    group.members.append(node_id)
    return True


def canvas_group_has_node(state: CanvasState, group_id: Int64, node_id: RetainedId) -> Bool:
    var gi = _group_index(state, group_id)
    if gi < 0:
        return False
    return _group_member_has(state.groups[gi].copy(), node_id)


def canvas_group_node_count(state: CanvasState, group_id: Int64) -> Int:
    var gi = _group_index(state, group_id)
    if gi < 0:
        return 0
    return len(state.groups[gi].members)


def canvas_group_member_bounds(
    state: CanvasState, graph: Graph, group_id: Int64
) -> Tuple[Bool, Rect]:
    var gi = _group_index(state, group_id)
    if gi < 0:
        return (False, Rect())
    var found = False
    var bounds = Rect()
    for i in range(len(state.groups[gi].members)):
        var node_idx = graph.find_node(state.groups[gi].members[i])
        if node_idx < 0:
            continue
        var nr = _node_world_rect(graph.nodes[node_idx].copy())
        if not found:
            bounds = nr.copy()
            found = True
        else:
            bounds = bounds.union(nr.copy())
    return (found, bounds.copy())


def canvas_fit_group_to_members(
    mut state: CanvasState, graph: Graph, group_id: Int64
) -> Bool:
    var gi = _group_index(state, group_id)
    if gi < 0:
        return False
    var result = canvas_group_member_bounds(state, graph, group_id)
    if not result[0]:
        return False
    state.groups[gi].rect = result[1].inflate(_GROUP_PADDING, _GROUP_PADDING)
    return True


def canvas_bind_selection_to_group(
    mut state: CanvasState, graph: Graph, group_id: Int64
) -> Int:
    """Bind the current node selection to a canvas group.

    The group remains UI state, but membership is explicit by node id so
    group drag, select, and future mute/bypass/collapse controls can act
    on the intended nodes instead of guessing from geometry every frame.
    """
    var gi = _group_index(state, group_id)
    if gi < 0:
        return 0
    _ensure_primary_in_selection(state)
    var added = 0
    for i in range(graph.node_count()):
        var nid = graph.nodes[i].id
        if canvas_is_node_selected(state, nid):
            if _group_append_member(state.groups[gi], nid):
                added = added + 1
    _ = canvas_fit_group_to_members(state, graph, group_id)
    state.selected_group = group_id
    return added


def canvas_select_group_members(
    mut state: CanvasState, graph: Graph, group_id: Int64
) -> Int:
    """Select all nodes bound to a group.

    If an older group has no explicit members, fall back to selecting
    nodes intersecting the group rectangle.
    """
    var gi = _group_index(state, group_id)
    if gi < 0:
        return 0
    var group_rect = state.groups[gi].rect.copy()
    canvas_clear_selection(state)
    var selected = 0
    if len(state.groups[gi].members) > 0:
        for i in range(len(state.groups[gi].members)):
            var node_idx = graph.find_node(state.groups[gi].members[i])
            if node_idx >= 0:
                canvas_add_node_to_selection(state, graph.nodes[node_idx].id)
                selected = selected + 1
    else:
        for i in range(graph.node_count()):
            if group_rect.intersects(_node_world_rect(graph.nodes[i].copy())):
                canvas_add_node_to_selection(state, graph.nodes[i].id)
                selected = selected + 1
    state.selected_group = group_id
    return selected


def canvas_move_group(
    mut state: CanvasState,
    mut graph: Graph,
    group_id: Int64,
    delta: Vec2,
    move_members: Bool = True,
) -> Bool:
    var gi = _group_index(state, group_id)
    if gi < 0:
        return False
    state.groups[gi].rect = state.groups[gi].rect.offset(delta.x, delta.y)
    if move_members:
        for i in range(len(state.groups[gi].members)):
            var node_idx = graph.find_node(state.groups[gi].members[i])
            if node_idx >= 0 and not graph.nodes[node_idx].pinned:
                graph.nodes[node_idx].position = Vec2(
                    graph.nodes[node_idx].position.x + delta.x,
                    graph.nodes[node_idx].position.y + delta.y,
                )
    return True


def canvas_group_selection(
    mut state: CanvasState, graph: Graph, title: String = String("")
) -> Int64:
    var result = canvas_selection_bounds(state, graph)
    if not result[0]:
        return Int64(-1)
    var group_title = title.copy()
    if group_title.byte_length() == 0:
        group_title = String("Group ") + String(state.next_group_id)
    var group_rect = result[1].inflate(_GROUP_PADDING, _GROUP_PADDING)
    var group = CanvasGroup(
        state.next_group_id,
        group_title,
        group_rect,
        Color(96, 120, 180, 255),
    )
    for i in range(graph.node_count()):
        if canvas_is_node_selected(state, graph.nodes[i].id):
            _ = _group_append_member(group, graph.nodes[i].id)
    state.groups.append(group^)
    state.next_group_id = state.next_group_id + Int64(1)
    state.selected_group = state.next_group_id - Int64(1)
    return state.selected_group


def canvas_fit_group_to_selection(mut state: CanvasState, graph: Graph, group_id: Int64) -> Bool:
    var result = canvas_selection_bounds(state, graph)
    if not result[0]:
        return False
    for i in range(len(state.groups)):
        if state.groups[i].id == group_id:
            state.groups[i].rect = result[1].inflate(_GROUP_PADDING, _GROUP_PADDING)
            _ = canvas_bind_selection_to_group(state, graph, group_id)
            return True
    return False


def _group_node_index_list(state: CanvasState, graph: Graph, group_id: Int64) -> List[Int]:
    var indices = List[Int]()
    var gi = _group_index(state, group_id)
    if gi < 0:
        return indices^
    if len(state.groups[gi].members) > 0:
        for i in range(len(state.groups[gi].members)):
            var node_idx = graph.find_node(state.groups[gi].members[i])
            if node_idx >= 0:
                indices.append(node_idx)
        return indices^
    var group_rect = state.groups[gi].rect.copy()
    for i in range(graph.node_count()):
        if group_rect.intersects(_node_world_rect(graph.nodes[i].copy())):
            indices.append(i)
    return indices^


def canvas_toggle_group_nodes_mute(
    mut state: CanvasState, mut graph: Graph, group_id: Int64
) -> Int:
    """rgthree-style group fast toggle: if all member nodes are muted,
    unmute them; otherwise mute them all."""
    var indices = _group_node_index_list(state, graph, group_id)
    if len(indices) == 0:
        return 0
    var all_muted = True
    for i in range(len(indices)):
        all_muted = all_muted and graph.nodes[indices[i]].muted
    var next_muted = not all_muted
    for i in range(len(indices)):
        graph.nodes[indices[i]].muted = next_muted
    state.selected_group = group_id
    return len(indices)


def canvas_toggle_group_nodes_bypass(
    mut state: CanvasState, mut graph: Graph, group_id: Int64
) -> Int:
    """rgthree-style group fast toggle: if all member nodes are bypassed,
    enable them; otherwise bypass them all."""
    var indices = _group_node_index_list(state, graph, group_id)
    if len(indices) == 0:
        return 0
    var all_bypassed = True
    for i in range(len(indices)):
        all_bypassed = all_bypassed and graph.nodes[indices[i]].bypassed
    var next_bypassed = not all_bypassed
    for i in range(len(indices)):
        graph.nodes[indices[i]].bypassed = next_bypassed
    state.selected_group = group_id
    return len(indices)


def _node_has_outgoing_edges(graph: Graph, node_id: RetainedId) -> Bool:
    for i in range(graph.edge_count()):
        if graph.edges[i].from_node == node_id:
            return True
    return False


def _lower_ascii(s: String) -> String:
    var n = s.byte_length()
    var out = List[UInt8](capacity=n)
    var ptr = s.unsafe_ptr()
    for i in range(n):
        var b = ptr[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            b = b + UInt8(0x20)
        out.append(b)
    return String(unsafe_from_utf8=out)


def _contains_ascii(haystack: String, needle: String) -> Bool:
    var hn = haystack.byte_length()
    var nn = needle.byte_length()
    if nn == 0:
        return True
    if nn > hn:
        return False
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(hn - nn + 1):
        var matched = True
        for j in range(nn):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return True
    return False


def _node_is_output_sink(node: Node) -> Bool:
    var tid = _lower_ascii(node.type_id)
    var title = _lower_ascii(node.title)
    return (
        _contains_ascii(tid, String("save"))
        or _contains_ascii(tid, String("preview"))
        or _contains_ascii(title, String("save"))
        or _contains_ascii(title, String("preview"))
    )


def canvas_group_output_nodes(state: CanvasState, graph: Graph, group_id: Int64) -> List[RetainedId]:
    """Return group member output nodes for selective queueing.

    A node is treated as an output when it is an explicit save/preview sink
    or when it has no outgoing edges.
    """
    var out = List[RetainedId]()
    var indices = _group_node_index_list(state, graph, group_id)
    for i in range(len(indices)):
        var node = graph.nodes[indices[i]].copy()
        if _node_is_output_sink(node) or not _node_has_outgoing_edges(graph, node.id):
            out.append(node.id)
    return out^


def canvas_add_bookmark(
    mut state: CanvasState,
    title: String,
    shortcut: String,
    center: Vec2,
    zoom: Float32,
) -> Int64:
    var z = _clamp_zoom(zoom)
    var bookmark = CanvasBookmark(
        state.next_bookmark_id,
        title,
        shortcut,
        center,
        z,
    )
    state.bookmarks.append(bookmark^)
    state.next_bookmark_id = state.next_bookmark_id + Int64(1)
    return state.next_bookmark_id - Int64(1)


def _bookmark_index(state: CanvasState, bookmark_id: Int64) -> Int:
    for i in range(len(state.bookmarks)):
        if state.bookmarks[i].id == bookmark_id:
            return i
    return -1


def canvas_jump_to_bookmark(
    mut state: CanvasState,
    bookmark_id: Int64,
    viewport: Rect,
) -> Bool:
    var idx = _bookmark_index(state, bookmark_id)
    if idx < 0:
        return False
    state.zoom = _clamp_zoom(state.bookmarks[idx].zoom)
    state.pan = Vec2(
        viewport.x + viewport.w * Float32(0.5) - state.bookmarks[idx].center.x * state.zoom,
        viewport.y + viewport.h * Float32(0.5) - state.bookmarks[idx].center.y * state.zoom,
    )
    return True


def _toggle_node_flag(mut state: CanvasState, mut graph: Graph, flag: Int32) -> Int:
    _ensure_primary_in_selection(state)
    var changed = 0
    for i in range(graph.node_count()):
        if canvas_is_node_selected(state, graph.nodes[i].id):
            if flag == Int32(0):
                graph.nodes[i].muted = not graph.nodes[i].muted
            elif flag == Int32(1):
                graph.nodes[i].bypassed = not graph.nodes[i].bypassed
            elif flag == Int32(2):
                graph.nodes[i].collapsed = not graph.nodes[i].collapsed
            else:
                graph.nodes[i].pinned = not graph.nodes[i].pinned
            changed = changed + 1
    return changed


def canvas_toggle_selected_nodes_mute(mut state: CanvasState, mut graph: Graph) -> Int:
    return _toggle_node_flag(state, graph, Int32(0))


def canvas_toggle_selected_nodes_bypass(mut state: CanvasState, mut graph: Graph) -> Int:
    return _toggle_node_flag(state, graph, Int32(1))


def canvas_toggle_selected_nodes_collapse(mut state: CanvasState, mut graph: Graph) -> Int:
    return _toggle_node_flag(state, graph, Int32(2))


def canvas_toggle_selected_nodes_pin(mut state: CanvasState, mut graph: Graph) -> Int:
    return _toggle_node_flag(state, graph, Int32(3))


def canvas_insert_reroute_on_edge(
    mut state: CanvasState, mut graph: Graph, edge_index: Int, position: Vec2
) -> RetainedId:
    """Split `edge_index` with a compact `core/reroute` node.

    This mirrors Comfy/rgthree's practical reroute behavior at the graph
    model level: preserve the original edge type/name endpoints, insert a
    tiny pass-through node, then reconnect source -> reroute -> target.
    """
    if edge_index < 0 or edge_index >= graph.edge_count():
        return RET_ID_NONE
    var edge = graph.edges[edge_index].copy()
    var value_type = Int32(-1)
    var from_idx = graph.find_node(edge.from_node)
    if from_idx >= 0:
        for pi in range(len(graph.nodes[from_idx].outputs)):
            if graph.nodes[from_idx].outputs[pi].name == edge.from_port:
                value_type = graph.nodes[from_idx].outputs[pi].value_type
                break
    var rid = graph.add_node(String("core/reroute"), position.copy())
    var r_idx = graph.find_node(rid)
    if r_idx < 0:
        return RET_ID_NONE
    graph.nodes[r_idx].title = String("Reroute")
    graph.nodes[r_idx].size = Vec2(Float32(52.0), Float32(34.0))
    graph.nodes[r_idx].add_input(PortRef(String(""), value_type))
    graph.nodes[r_idx].add_output(PortRef(String(""), value_type))
    graph.remove_edge_at(edge_index)
    _ = graph.add_edge(edge.from_node, edge.from_port.copy(), rid, String(""))
    _ = graph.add_edge(rid, String(""), edge.to_node, edge.to_port.copy())
    canvas_set_single_selection(state, rid)
    state.hovered_edge = Int32(-1)
    return rid


def port_screen_pos(
    state: CanvasState, node: Node, port_index: Int, is_input: Bool
) -> Vec2:
    """Returns the on-screen anchor of port `port_index` on `node`.

    Layout: ports stack vertically inside the node's body, starting just
    below the title bar. Input ports anchor on the LEFT edge (x =
    `node.position.x`); output ports anchor on the RIGHT edge (x =
    `node.position.x + node.size.x`). Y coordinate is shared between
    inputs and outputs at the same index (visually rows the I/O pair).
    """
    var port_y_world = node.position.y + _TITLE_BAR_H * Float32(0.5)
    if not node.collapsed:
        port_y_world = (
            node.position.y
            + _TITLE_BAR_H
            + Float32(port_index) * _PORT_SPACING
            + _PORT_SPACING * Float32(0.5)
        )
    var port_x_world: Float32 = node.position.x
    if not is_input:
        port_x_world = port_x_world + node.size.x
    return canvas_world_to_screen(state, Vec2(port_x_world, port_y_world))


def _distance(a: Vec2, b: Vec2) -> Float32:
    var dx = a.x - b.x
    var dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)


def _point_hits_port(point: Vec2, port_pos: Vec2) -> Bool:
    return _distance(point, port_pos) <= _PORT_HIT_RADIUS


def _clear_wire_drag(mut state: CanvasState):
    state.wire_drag_from_node = RET_ID_NONE
    state.wire_drag_from_port = String("")
    state.wire_drag_from_is_output = False
    state.wire_drag_from_type = Int32(-1)


def _start_wire_drag(
    mut state: CanvasState,
    node_id: RetainedId,
    port_name: String,
    is_output: Bool,
    value_type: Int32,
):
    state.wire_drag_from_node = node_id
    state.wire_drag_from_port = port_name.copy()
    state.wire_drag_from_is_output = is_output
    state.wire_drag_from_type = value_type
    state.selected_node = node_id
    state.selected_edge = Int32(-1)


def _wire_drag_active(state: CanvasState) -> Bool:
    return state.wire_drag_from_node != RET_ID_NONE


def _try_commit_wire_drag(
    mut state: CanvasState,
    mut graph: Graph,
    target_node: RetainedId,
    target_port: String,
    target_is_output: Bool,
    target_type: Int32,
) -> Bool:
    if not _wire_drag_active(state):
        return False
    if target_node == state.wire_drag_from_node:
        return False
    if target_is_output == state.wire_drag_from_is_output:
        return False
    if target_type != state.wire_drag_from_type:
        return False

    var ok: Bool
    if state.wire_drag_from_is_output:
        ok = graph.add_edge(
            state.wire_drag_from_node,
            state.wire_drag_from_port.copy(),
            target_node,
            target_port.copy(),
        )
    else:
        ok = graph.add_edge(
            target_node,
            target_port.copy(),
            state.wire_drag_from_node,
            state.wire_drag_from_port.copy(),
        )
    return ok
