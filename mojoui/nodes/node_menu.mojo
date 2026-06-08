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

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.id import RetainedId, RET_ID_NONE
from mojoui.core.control import CTRL_ACTIVE, CTRL_HOVERED, CTRL_RELEASED, OPT_NONE
from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node, FieldValue
from mojoui.nodes.canvas import CanvasState


comptime NodeAction = Int32

comptime NODE_ACTION_NONE: NodeAction = -1
comptime NODE_ACTION_DELETE: NodeAction = 0
comptime NODE_ACTION_DUPLICATE: NodeAction = 1
comptime NODE_ACTION_RENAME: NodeAction = 2
comptime NODE_ACTION_COLOR: NodeAction = 3

comptime _MENU_WIDTH: Float32 = 230.0
"""Context-menu row width (px)."""

comptime _DUPLICATE_OFFSET: Float32 = 24.0
"""World-space x/y offset of a duplicated node from its source so the copy
is visibly distinct rather than perfectly overlapping."""

comptime _ACTION_ROW_COUNT: Int32 = 3
comptime _COLOR_COUNT: Int32 = 11


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

    var clicked = _node_context_menu_popup(ctx, id_str, state, graph)

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
    elif clicked >= _ACTION_ROW_COUNT:
        var idx = graph.find_node(target)
        if idx >= 0:
            graph.nodes[idx].fields[String("ui_color")] = FieldValue.string(
                node_ui_color_key(clicked - _ACTION_ROW_COUNT)
            )
        action = NODE_ACTION_COLOR

    # Once the widget has closed the menu (item-click or click-outside),
    # drop the stale target id so a future frame doesn't act on it.
    if not state.ctx_menu_open:
        state.ctx_menu_node = RET_ID_NONE

    return action


def node_ui_color_count() -> Int32:
    return _COLOR_COUNT


def node_ui_color_key(index: Int32) -> String:
    if index == 0:
        return String("default")
    if index == 1:
        return String("gold")
    if index == 2:
        return String("blue")
    if index == 3:
        return String("purple")
    if index == 4:
        return String("green")
    if index == 5:
        return String("teal")
    if index == 6:
        return String("gray")
    if index == 7:
        return String("accent")
    if index == 8:
        return String("success")
    if index == 9:
        return String("warning")
    if index == 10:
        return String("error")
    return String("default")


def node_ui_color_label(index: Int32) -> String:
    if index == 0:
        return String("Default")
    if index == 1:
        return String("Gold")
    if index == 2:
        return String("Blue")
    if index == 3:
        return String("Purple")
    if index == 4:
        return String("Green")
    if index == 5:
        return String("Teal")
    if index == 6:
        return String("Gray")
    if index == 7:
        return String("Theme Accent")
    if index == 8:
        return String("Theme Success")
    if index == 9:
        return String("Theme Warning")
    if index == 10:
        return String("Theme Error")
    return String("Default")


def _current_ui_color(node: Node) raises -> String:
    var current = String("default")
    if String("ui_color") in node.fields:
        var fv = node.fields[String("ui_color")].copy()
        if fv.str_val.byte_length() > 0:
            current = fv.str_val.copy()
    return current^


def _current_ui_color_index(node: Node) raises -> Int32:
    var current = _current_ui_color(node)
    for i in range(_COLOR_COUNT):
        if node_ui_color_key(i) == current:
            return i
    return 0


def _swatch_color(ctx: Context, key: String) -> Color:
    if key == String("gold"):
        return Color(232, 184, 72, 255)
    if key == String("blue"):
        return Color(110, 170, 255, 255)
    if key == String("purple"):
        return Color(184, 142, 245, 255)
    if key == String("green"):
        return Color(120, 210, 145, 255)
    if key == String("teal"):
        return Color(92, 205, 220, 255)
    if key == String("gray"):
        return Color(172, 176, 188, 255)
    if key == String("accent"):
        return ctx.theme.primary.copy()
    if key == String("success"):
        return ctx.theme.success_bg.copy()
    if key == String("warning"):
        return ctx.theme.warning_bg.copy()
    if key == String("error"):
        return ctx.theme.error_bg.copy()
    return ctx.theme.graph_node_bg.copy()


def _draw_popup_border(mut ctx: Context, rect: Rect, color: Color):
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, Float32(1.0)), color.copy())
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - Float32(1.0), rect.w, Float32(1.0)),
        color.copy(),
    )
    ctx.draw_rect(Rect(rect.x, rect.y, Float32(1.0), rect.h), color.copy())
    ctx.draw_rect(
        Rect(rect.x + rect.w - Float32(1.0), rect.y, Float32(1.0), rect.h),
        color.copy(),
    )


def _draw_swatch(mut ctx: Context, rect: Rect, color: Color, selected: Bool):
    ctx.draw_rect(rect.copy(), color.copy())
    var border = ctx.theme.border.copy()
    if selected:
        border = ctx.theme.text.copy()
    _draw_popup_border(ctx, rect, border^)


def _draw_menu_text(mut ctx: Context, rect: Rect, text: String):
    if ctx.theme.font_id == 0:
        return
    var pos = Vec2(
        rect.x,
        rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * Float32(0.5),
    )
    ctx.draw_text(
        ctx.theme.font_id,
        ctx.theme.font_size_pt,
        pos^,
        ctx.theme.text.copy(),
        text,
    )


def _node_context_menu_popup(
    mut ctx: Context,
    id_str: String,
    mut state: CanvasState,
    graph: Graph,
) raises -> Int32:
    if not state.ctx_menu_open:
        return -1

    var row_count = _ACTION_ROW_COUNT + _COLOR_COUNT
    var row_h = Float32(ctx.theme.row_height)
    var popup_rect = Rect(
        state.ctx_menu_anchor.x,
        state.ctx_menu_anchor.y,
        _MENU_WIDTH,
        row_h * Float32(row_count),
    )

    if ctx.control.mouse_pressed_this_frame:
        if not popup_rect.contains(ctx.control.mouse_pos.copy()):
            state.ctx_menu_open = False
            return -1

    var current_color_idx: Int32 = -1
    var node_idx = graph.find_node(state.ctx_menu_node)
    if node_idx >= 0:
        current_color_idx = _current_ui_color_index(graph.nodes[node_idx])

    ctx.begin_popup(popup_rect.copy())
    ctx.push_id_str(id_str)
    ctx.draw_rect(popup_rect.copy(), ctx.theme.bg.copy())
    _draw_popup_border(ctx, popup_rect.copy(), ctx.theme.border.copy())

    var clicked: Int32 = -1
    for row in range(row_count):
        var row_i = Int32(row)
        var row_rect = Rect(
            popup_rect.x,
            popup_rect.y + Float32(row_i) * row_h,
            popup_rect.w,
            row_h,
        )
        var row_id = ctx.get_id(String(row_i))
        var flags = ctx.update_control(row_id, row_rect.copy(), OPT_NONE)
        if (flags & CTRL_ACTIVE) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.active_bg.copy())
        elif (flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.hover_bg.copy())
        elif row_i >= _ACTION_ROW_COUNT and row_i - _ACTION_ROW_COUNT == current_color_idx:
            ctx.draw_rect(row_rect.copy(), ctx.theme.selection_bg.copy())

        var text_rect = Rect(
            row_rect.x + Float32(ctx.theme.padding),
            row_rect.y,
            row_rect.w - Float32(ctx.theme.padding * 2),
            row_rect.h,
        )
        if row_i == NODE_ACTION_DELETE:
            _draw_menu_text(ctx, text_rect.copy(), String("Delete"))
        elif row_i == NODE_ACTION_DUPLICATE:
            _draw_menu_text(ctx, text_rect.copy(), String("Duplicate"))
        elif row_i == NODE_ACTION_RENAME:
            _draw_menu_text(ctx, text_rect.copy(), String("Rename"))
        else:
            var color_idx = row_i - _ACTION_ROW_COUNT
            var swatch_size = row_h - Float32(ctx.theme.padding * 2)
            if swatch_size < Float32(12.0):
                swatch_size = Float32(12.0)
            if swatch_size > Float32(22.0):
                swatch_size = Float32(22.0)
            var swatch = Rect(
                row_rect.x + Float32(ctx.theme.padding),
                row_rect.y + (row_rect.h - swatch_size) * Float32(0.5),
                swatch_size,
                swatch_size,
            )
            var key = node_ui_color_key(color_idx)
            _draw_swatch(
                ctx,
                swatch,
                _swatch_color(ctx, key.copy()),
                color_idx == current_color_idx,
            )
            var label_rect = Rect(
                swatch.x + swatch.w + Float32(ctx.theme.padding),
                row_rect.y,
                row_rect.w - swatch.w - Float32(ctx.theme.padding * 3),
                row_rect.h,
            )
            _draw_menu_text(ctx, label_rect, node_ui_color_label(color_idx))

        if (flags & CTRL_RELEASED) != 0:
            clicked = row_i
            state.ctx_menu_open = False

    ctx.pop_id()
    ctx.end_popup()
    return clicked
