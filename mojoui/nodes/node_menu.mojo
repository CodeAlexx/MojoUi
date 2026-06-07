"""Per-node right-click context menu — Delete / Duplicate / Rename / Color.

The canvas (`begin_node_canvas`) detects a right-click over a node body and
records `state.ctx_menu_open` + `ctx_menu_node` + `ctx_menu_anchor`. This
module renders the resulting menu (on the popup layer, via the M5
`context_menu` widget) and applies the chosen action to the `Graph`:

  - **Delete**    → `graph.remove_node` (drops the node + every edge
                    touching it; clears selection if it was selected).
  - **Duplicate** → clone the node at a small offset with a fresh id
                    (`graph.add_built_node`); the copy carries fields +
                    ports but NO edges (standard node-editor behavior);
                    the copy becomes the new selection.
  - **Rename**    → set `state.renaming_node` and return. This module does
                    NOT draw a text field — `text_edit` reaches the FFI
                    input symbols which would taint the pure node layer's
                    `mojo run` tests (see implementation notes). A live app overlays a
                    `text_edit` bound to `graph.nodes[i].title` while
                    `renaming_node` is set, then clears it. Headless callers
                    just observe the flag.

Call AFTER `end_node_canvas` (it draws on the popup layer, which is
appended on top at `end_frame`). Mirrors the add-menu's overlay placement.

Returns the chosen `NODE_ACTION_*` this frame, or `NODE_ACTION_NONE`.
"""

from mojoui.core.types import Vec2
from mojoui.core.context import Context
from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node, FieldValue
from mojoui.nodes.canvas import CanvasState
from mojoui.widgets.context_menu import context_menu


comptime NodeAction = Int32

comptime NODE_ACTION_NONE: NodeAction = -1
comptime NODE_ACTION_DELETE: NodeAction = 0
comptime NODE_ACTION_DUPLICATE: NodeAction = 1
comptime NODE_ACTION_RENAME: NodeAction = 2
comptime NODE_ACTION_COLOR: NodeAction = 3

comptime _MENU_WIDTH: Float32 = 160.0
"""Context-menu row width (px)."""

comptime _DUPLICATE_OFFSET: Float32 = 24.0
"""World-space x/y offset of a duplicated node from its source so the copy
is visibly distinct rather than perfectly overlapping."""


def node_context_menu(
    mut ctx: Context,
    id_str: String,
    mut state: CanvasState,
    mut graph: Graph,
) raises -> NodeAction:
    """Render + handle the per-node context menu when `state.ctx_menu_open`.

    Returns the action taken this frame (`NODE_ACTION_*`), or
    `NODE_ACTION_NONE` when nothing was clicked. Closes the menu (via the
    `context_menu` widget) on item-click or click-outside, and resets
    `ctx_menu_node` to `RET_ID_NONE` once closed.

    `id_str` scopes the popup id — pass something distinct from the
    canvas's add-menu id (e.g. `"node_ctx"`).
    """
    if not state.ctx_menu_open:
        return NODE_ACTION_NONE

    var items = List[String]()
    items.append(String("Delete"))
    items.append(String("Duplicate"))
    items.append(String("Rename"))
    items.append(String("Cycle Color"))

    var clicked = context_menu(
        ctx,
        id_str,
        state.ctx_menu_anchor.copy(),
        items,
        _MENU_WIDTH,
        state.ctx_menu_open,
    )

    var target = state.ctx_menu_node
    var action = NODE_ACTION_NONE

    if clicked == NODE_ACTION_DELETE:
        if target != RET_ID_NONE:
            graph.remove_node(target)
            if state.selected_node == target:
                state.selected_node = RET_ID_NONE
            if state.dragging_node == target:
                state.dragging_node = RET_ID_NONE
        action = NODE_ACTION_DELETE
    elif clicked == NODE_ACTION_DUPLICATE:
        var idx = graph.find_node(target)
        if idx >= 0:
            var clone = graph.nodes[idx].copy()
            clone.position = Vec2(
                clone.position.x + _DUPLICATE_OFFSET,
                clone.position.y + _DUPLICATE_OFFSET,
            )
            var new_id = graph.add_built_node(clone)
            state.selected_node = new_id
        action = NODE_ACTION_DUPLICATE
    elif clicked == NODE_ACTION_RENAME:
        if target != RET_ID_NONE:
            state.renaming_node = target
        action = NODE_ACTION_RENAME
    elif clicked == NODE_ACTION_COLOR:
        var idx = graph.find_node(target)
        if idx >= 0:
            graph.nodes[idx].fields[String("ui_color")] = FieldValue.string(
                _next_ui_color(graph.nodes[idx])
            )
        action = NODE_ACTION_COLOR

    # Once the widget has closed the menu (item-click or click-outside),
    # drop the stale target id so a future frame doesn't act on it.
    if not state.ctx_menu_open:
        state.ctx_menu_node = RET_ID_NONE

    return action


def _next_ui_color(node: Node) raises -> String:
    var current = String("default")
    if String("ui_color") in node.fields:
        var fv = node.fields[String("ui_color")].copy()
        current = fv.str_val.copy()
    if current == String("default"):
        return String("gold")
    if current == String("gold"):
        return String("blue")
    if current == String("blue"):
        return String("purple")
    if current == String("purple"):
        return String("green")
    if current == String("green"):
        return String("teal")
    if current == String("teal"):
        return String("gray")
    return String("default")
