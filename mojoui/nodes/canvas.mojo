"""NodeCanvas — immediate-mode node-graph viewport (M2.5 chunk 39).

Renders a retained `Graph` (c36) inside a pan/zoom viewport: each `Node`'s
title bar + body + per-port dots are drawn, each `Edge` is drawn as a
cubic-bezier wire (c38), and the canvas drives node-drag + single-select
interaction directly mutating the caller-owned `CanvasState` + `Graph`.

Mirrors EriGui's `NodeGraph` widget (`erigui-widgets/src/node_graph/mod.rs`)
per EriGui node audit notes "Canvas / Visual Layer":

  - `pan: Vec2`, `zoom: Float32` — affine `screen = world * zoom + pan`.
  - `Interaction` variants — NodeDrag, Pan, LinkDrag, wire select/delete,
    background deselect, and selected-node delete.
  - Wires via `wires.draw_wire` — 24 segments, horizontal-tangent control
    points at `dx * 0.35` (c38).

Usage (microui begin/end container pattern, same as `scroll_area` c28 /
`window_panel` c30):

    var state = CanvasState()
    var graph = Graph()
    ...
    if begin_node_canvas(ctx, "main_canvas", state, graph):
        # state changed this frame — caller may invalidate caches.
        pass
    # caller overlays (debug HUD, add-menu) here.
    end_node_canvas(ctx)

`CanvasState` is RETAINED (Movable, not Copyable — copy semantics make
no sense for "active drag state"). Drag start sets `dragging_node` +
`selected_node` + `drag_offset`; each frame inverts the affine to
recompute the node's world position so the click point stays glued to
the cursor; drag ends on LEFT-button release. Held MIDDLE button pans
the viewport.

What this chunk deliberately does NOT do (M3+): multi-select / marquee,
mouse-wheel zoom (wheel-event FFI is M3), minimap, field-slider drags,
advanced connect-time schema checks beyond port direction + value type.

`.copy()` discipline: `Vec2`/`Rect`/`Color` are Copyable-not-
ImplicitlyCopyable (Mojo implementation notes c15) — every read into another call
needs `.copy()`. `Float32`/`Bool`/`UInt64` ARE ImplicitlyCopyable;
`String` is ImplicitlyCopyable per c29.
"""

from std.math import floor
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import (
    OPT_NONE,
    OPT_FOCUSABLE,
    CTRL_ACTIVE,
    CTRL_HOVERED,
    CTRL_RELEASED,
    CTRL_PRESSED,
)
from mojoui.core.id import ImmediateId, RetainedId, RET_ID_NONE
from mojoui.core.textedit import TextEditState
from mojoui.nodes.node import (
    Node,
    FieldValue,
    FK_STRING,
    FK_INT,
    FK_NUMBER,
    FK_BOOL,
)
from mojoui.nodes.graph import Graph
from mojoui.nodes.wires import (
    draw_wire,
    draw_wire_thick,
    wire_color_for_type,
    wire_distance_to_point,
    WIRE_THICKNESS,
)
from mojoui.nodes.node_body import draw_node_body
from mojoui.widgets.text_edit import text_edit
from mojoui.serde.json import (
    JsonValue,
    JK_ARRAY,
    JK_OBJECT,
    JK_NUMBER,
    JK_STRING,
    parse_json,
    emit_json,
)
from mojoui.nodes.canvas_model import (
    CanvasGroup,
    CanvasState,
    canvas_world_to_screen,
    canvas_screen_to_world,
    canvas_snap_world,
    canvas_zoom_at,
    canvas_reset_view,
    canvas_is_node_selected,
    canvas_selected_count,
    canvas_clear_selection,
    canvas_add_node_to_selection,
    canvas_remove_node_from_selection,
    canvas_toggle_node_selection,
    canvas_set_single_selection,
    canvas_select_all,
    canvas_selection_bounds,
    canvas_all_nodes_bounds,
    canvas_fit_rect,
    canvas_fit_selection,
    canvas_nudge_selection,
    canvas_copy_selection,
    canvas_paste_clipboard,
    canvas_duplicate_selection,
    canvas_delete_selection,
    canvas_group_has_node,
    canvas_group_node_count,
    canvas_group_member_bounds,
    canvas_fit_group_to_members,
    canvas_bind_selection_to_group,
    canvas_select_group_members,
    canvas_move_group,
    canvas_group_selection,
    canvas_fit_group_to_selection,
    canvas_toggle_group_nodes_mute,
    canvas_toggle_group_nodes_bypass,
    canvas_group_output_nodes,
    canvas_add_bookmark,
    canvas_jump_to_bookmark,
    canvas_toggle_selected_nodes_mute,
    canvas_toggle_selected_nodes_bypass,
    canvas_toggle_selected_nodes_collapse,
    canvas_toggle_selected_nodes_pin,
    canvas_insert_reroute_on_edge,
    port_screen_pos,
    _ensure_primary_in_selection,
    _rect_from_points,
    _node_world_rect,
    _point_hits_port,
    _clear_wire_drag,
    _start_wire_drag,
    _wire_drag_active,
    _try_commit_wire_drag,
)
from mojoui.render.tessellator import tess_circle, tess_drop_shadow, tess_rounded_rect
from mojoui.render.ffi import (
    MOJOUI_BTN_RIGHT,
    MOJOUI_KEY_DELETE,
    MOJOUI_KEY_RETURN,
    MOJOUI_KEY_ESCAPE,
    MOJOUI_KEY_A,
    MOJOUI_KEY_C,
    MOJOUI_KEY_D,
    MOJOUI_KEY_F,
    MOJOUI_KEY_G,
    MOJOUI_KEY_L,
    MOJOUI_KEY_R,
    MOJOUI_KEY_V,
    MOJOUI_KEY_0,
    MOJOUI_KEY_LEFT,
    MOJOUI_KEY_RIGHT,
    MOJOUI_KEY_UP,
    MOJOUI_KEY_DOWN,
    MOJOUI_KEY_LCTRL,
    MOJOUI_KEY_RCTRL,
)


# Title bar height (px) in WORLD space; multiplied by `state.zoom` when
# drawn. Matches `window_panel._TITLE_BAR_H` so a node title bar is the
# same visual height as a window title bar at zoom == 1.0.
comptime _TITLE_BAR_H: Float32 = 24.0

# Vertical pitch between port dots inside a node (world space).
comptime _PORT_SPACING: Float32 = 20.0

# On-screen diameter of the typed port fill circle (px).
comptime _PORT_DOT_SIZE: Float32 = 8.0
comptime _PORT_HIT_RADIUS: Float32 = 9.0
comptime _PORT_RING_RADIUS: Float32 = 6.0
comptime _NODE_RADIUS: Float32 = 8.0
comptime _NODE_SHADOW_BLUR: Float32 = 5.0
comptime _NODE_RESIZE_HANDLE: Float32 = 18.0
comptime _NODE_MIN_W: Float32 = 180.0
comptime _NODE_MIN_H: Float32 = 82.0
comptime _GRID_MINOR_WORLD: Float32 = 32.0
comptime _GRID_MAJOR_WORLD: Float32 = 128.0
comptime _SNAP_GRID_WORLD: Float32 = 20.0
comptime _PASTE_OFFSET_WORLD: Float32 = 24.0
comptime _NUDGE_SMALL_WORLD: Float32 = 10.0
comptime _ZOOM_MIN: Float32 = 0.20
comptime _ZOOM_MAX: Float32 = 3.00
comptime _ZOOM_STEP: Float32 = 1.12
comptime _FIT_PADDING: Float32 = 80.0
comptime _GROUP_PADDING: Float32 = 28.0
comptime _MARQUEE_MIN_DIST: Float32 = 4.0
comptime _MINIMAP_W: Float32 = 190.0
comptime _MINIMAP_H: Float32 = 126.0
comptime _MINIMAP_PAD: Float32 = 12.0
comptime _ACTION_BAR_X: Float32 = 14.0
comptime _ACTION_BAR_Y: Float32 = 10.0
comptime _ACTION_BAR_H: Float32 = 42.0
comptime _ACTION_BAR_PAD: Float32 = 6.0
comptime _ACTION_BAR_GAP: Float32 = 6.0
comptime _ACTION_GENERATE_W: Float32 = 114.0
comptime _ACTION_ADD_IMAGE_W: Float32 = 122.0
comptime _ACTION_IMPORT_W: Float32 = 134.0
comptime _ACTION_BAR_W: Float32 = (
    _ACTION_BAR_PAD * Float32(2.0)
    + _ACTION_GENERATE_W
    + _ACTION_ADD_IMAGE_W
    + _ACTION_IMPORT_W
    + _ACTION_BAR_GAP * Float32(2.0)
)

# Default node body fill (RGBA bytes packed into Color at runtime).
comptime _NODE_BG_R: Int = 40
comptime _NODE_BG_G: Int = 40
comptime _NODE_BG_B: Int = 50
comptime _NODE_BG_A: Int = 240

# Node body fill when selected — same hue as primary but darker so the
# title bar still pops against the body.
comptime _NODE_SEL_R: Int = 60
comptime _NODE_SEL_G: Int = 60
comptime _NODE_SEL_B: Int = 90

# Title bar fill (matches EriGui's "header" color shape — slightly
# brighter / cooler than the body fill).
comptime _TITLE_BG_R: Int = 60
comptime _TITLE_BG_G: Int = 70
comptime _TITLE_BG_B: Int = 110

# Canvas background — dark slate so the bright node colors pop. M3 reads
# from theme.
comptime _CANVAS_BG_R: Int = 15
comptime _CANVAS_BG_G: Int = 15
comptime _CANVAS_BG_B: Int = 18

# Default border (un-selected) — neutral grey.
comptime _BORDER_R: Int = 80
comptime _BORDER_G: Int = 80
comptime _BORDER_B: Int = 90

# Mouse-button indices (mirror `mojoui/render/ffi.mojo` MOJOUI_BTN_*).
comptime _BTN_LEFT: Int32 = 0
comptime _BTN_MIDDLE: Int32 = 2

# Max screen-space distance (px) from the cursor to a wire's bezier
# polyline for the wire to count as hovered/clickable. ~half the port-dot
# size gives a comfortable hit target without overlapping adjacent wires.
comptime _WIRE_HIT_DIST: Float32 = 6.0

# Stroke thickness for the hovered / selected wire (vs WIRE_THICKNESS for
# idle wires). Selected is thickest so it reads as "armed for delete".
comptime _WIRE_HOVER_THICKNESS: Float32 = 3.5
comptime _WIRE_SELECT_THICKNESS: Float32 = 4.5
comptime _FIELD_BODY_LINE_H: Float32 = 26.0
comptime _FIELD_BODY_PAD_X: Float32 = 14.0
comptime _FIELD_BODY_PAD_Y: Float32 = 8.0
comptime _FIELD_BODY_H: Float32 = 24.0
comptime _FIELD_BODY_GAP: Float32 = 3.0
comptime _BBOX_DRAG_NONE: Int32 = 0
comptime _BBOX_DRAG_MOVE: Int32 = 1
comptime _BBOX_DRAG_RESIZE_SE: Int32 = 2
comptime _BBOX_DRAG_RESIZE_NW: Int32 = 3
comptime _BBOX_DRAG_RESIZE_NE: Int32 = 4
comptime _BBOX_DRAG_RESIZE_SW: Int32 = 5
comptime _BBOX_DRAG_RESIZE_E: Int32 = 6
comptime _BBOX_DRAG_RESIZE_W: Int32 = 7
comptime _BBOX_DRAG_RESIZE_N: Int32 = 8
comptime _BBOX_DRAG_RESIZE_S: Int32 = 9
comptime _BBOX_HANDLE: Float32 = 14.0
comptime _BBOX_MIN_SIZE: Float32 = 0.035


struct _CanvasBBox(Copyable, Movable):
    var label: String
    var rect: Rect
    var color: Color

    def __init__(out self):
        self.label = String("")
        self.rect = Rect()
        self.color = Color(105, 190, 255, 225)

    def __init__(out self, label: String, rect: Rect, color: Color):
        self.label = label.copy()
        self.rect = rect.copy()
        self.color = color.copy()


# ============================================================================
# CanvasState and non-rendering canvas helpers live in `canvas_model.mojo`.
# This file keeps drawing and frame interaction focused.

def _draw_grid_layer(
    mut ctx: Context,
    rect: Rect,
    origin: Vec2,
    spacing: Float32,
    color: Color,
    thickness: Float32,
):
    if spacing <= Float32(0.0):
        return
    var start_x = origin.x + floor((rect.x - origin.x) / spacing) * spacing
    while start_x < rect.x:
        start_x = start_x + spacing
    var x = start_x
    while x <= rect.right():
        ctx.draw_rect(Rect(x, rect.y, thickness, rect.h), color.copy())
        x = x + spacing

    var start_y = origin.y + floor((rect.y - origin.y) / spacing) * spacing
    while start_y < rect.y:
        start_y = start_y + spacing
    var y = start_y
    while y <= rect.bottom():
        ctx.draw_rect(Rect(rect.x, y, rect.w, thickness), color.copy())
        y = y + spacing


def _draw_canvas_grid(mut ctx: Context, rect: Rect, state: CanvasState):
    ctx.draw_rect(rect.copy(), ctx.theme.graph_canvas_bg.copy())
    var origin = state.pan.copy()
    var minor = _GRID_MINOR_WORLD * state.zoom
    var major = _GRID_MAJOR_WORLD * state.zoom
    if minor >= Float32(8.0):
        _draw_grid_layer(
            ctx,
            rect.copy(),
            origin.copy(),
            minor,
            Color(255, 255, 255, 14),
            Float32(1.0),
        )
    if major >= Float32(24.0):
        _draw_grid_layer(
            ctx,
            rect.copy(),
            origin.copy(),
            major,
            Color(255, 255, 255, 28),
            Float32(1.0),
        )


def _canvas_action_bar_rect(viewport: Rect) -> Rect:
    return Rect(
        viewport.x + _ACTION_BAR_X,
        viewport.y + _ACTION_BAR_Y,
        _ACTION_BAR_W,
        _ACTION_BAR_H,
    )


def _canvas_action_anchor_world(state: CanvasState, viewport: Rect) -> Vec2:
    return canvas_screen_to_world(
        state,
        Vec2(
            viewport.x + viewport.w * Float32(0.50),
            viewport.y + viewport.h * Float32(0.50),
        ),
    )


def _canvas_action_button(
    mut ctx: Context,
    id_str: String,
    rect: Rect,
    label: String,
    primary: Bool,
) -> Bool:
    var id = ctx.get_id(id_str)
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)
    var fill = ctx.theme.control_bg.copy()
    if primary:
        fill = Color(37, 125, 215, 255)
    if (flags & CTRL_ACTIVE) != 0:
        if primary:
            fill = Color(24, 94, 172, 255)
        else:
            fill = Color(52, 55, 66, 255)
    elif (flags & CTRL_HOVERED) != 0:
        if primary:
            fill = Color(55, 145, 236, 255)
        else:
            fill = Color(67, 70, 84, 255)
    tess_rounded_rect(ctx, rect.copy(), Float32(6.0), fill.copy(), 6)
    _draw_rect_border(ctx, rect.copy(), Color(255, 255, 255, 34), Float32(1.0))
    if ctx.theme.font_id != 0:
        var text_color = Color(236, 242, 252, 255)
        var label_w = _text_w_est(label.copy(), ctx.theme.font_size_pt)
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(
                rect.x + (rect.w - label_w) * Float32(0.5),
                rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * Float32(0.62)) * Float32(0.5),
            ),
            text_color,
            label,
        )
    return (flags & CTRL_RELEASED) != 0


def _draw_canvas_action_bar(
    mut ctx: Context,
    mut state: CanvasState,
    viewport: Rect,
) -> Bool:
    var bar = _canvas_action_bar_rect(viewport.copy())
    tess_drop_shadow(
        ctx,
        bar.copy(),
        Float32(7.0),
        Float32(5.0),
        Float32(0.0),
        Float32(2.0),
        Color(0, 0, 0, 96),
    )
    tess_rounded_rect(ctx, bar.copy(), Float32(7.0), Color(24, 26, 32, 245), 6)
    _draw_rect_border(ctx, bar.copy(), Color(255, 255, 255, 28), Float32(1.0))

    var x = bar.x + _ACTION_BAR_PAD
    var y = bar.y + _ACTION_BAR_PAD
    var h = bar.h - _ACTION_BAR_PAD * Float32(2.0)
    var changed = False
    if _canvas_action_button(
        ctx,
        String("canvas_generate"),
        Rect(x, y, _ACTION_GENERATE_W, h),
        String("Generate"),
        True,
    ):
        state.generate_requested = True
        state.action_anchor_world = _canvas_action_anchor_world(state, viewport.copy())
        changed = True
    x = x + _ACTION_GENERATE_W + _ACTION_BAR_GAP
    if _canvas_action_button(
        ctx,
        String("canvas_add_image"),
        Rect(x, y, _ACTION_ADD_IMAGE_W, h),
        String("Add Image"),
        False,
    ):
        state.add_image_requested = True
        state.action_anchor_world = _canvas_action_anchor_world(state, viewport.copy())
        changed = True
    x = x + _ACTION_ADD_IMAGE_W + _ACTION_BAR_GAP
    if _canvas_action_button(
        ctx,
        String("canvas_import_json"),
        Rect(x, y, _ACTION_IMPORT_W, h),
        String("Import JSON"),
        False,
    ):
        state.import_json_requested = True
        state.action_anchor_world = _canvas_action_anchor_world(state, viewport.copy())
        changed = True
    return changed


def _screen_rect_from_world(state: CanvasState, world: Rect) -> Rect:
    var pos = canvas_world_to_screen(state, Vec2(world.x, world.y))
    return Rect(pos.x, pos.y, world.w * state.zoom, world.h * state.zoom)


def _draw_rect_border(mut ctx: Context, rect: Rect, color: Color, thickness: Float32):
    var t = thickness
    if t < Float32(1.0):
        t = Float32(1.0)
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, t), color.copy())
    ctx.draw_rect(Rect(rect.x, rect.y + rect.h - t, rect.w, t), color.copy())
    ctx.draw_rect(Rect(rect.x, rect.y + t, t, rect.h - t * Float32(2.0)), color.copy())
    ctx.draw_rect(
        Rect(rect.x + rect.w - t, rect.y + t, t, rect.h - t * Float32(2.0)),
        color.copy(),
    )


def _draw_group_regions(mut ctx: Context, state: CanvasState):
    for i in range(len(state.groups)):
        var group = state.groups[i].copy()
        var sr = _screen_rect_from_world(state, group.rect.copy())
        var fill_alpha = UInt8(32)
        var border_alpha = UInt8(150)
        if group.id == state.selected_group:
            fill_alpha = UInt8(48)
            border_alpha = UInt8(230)
        var fill = Color(group.color.r, group.color.g, group.color.b, fill_alpha)
        var border = Color(group.color.r, group.color.g, group.color.b, border_alpha)
        tess_rounded_rect(ctx, sr.copy(), Float32(7.0), fill, 5)
        _draw_rect_border(ctx, sr.copy(), border, Float32(1.0))
        if ctx.theme.font_id != 0:
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                Vec2(sr.x + Float32(10.0), sr.y + Float32(18.0)),
                Color(220, 225, 245, 220),
                group.title,
            )


def _group_header_rect_screen(state: CanvasState, group: CanvasGroup) -> Rect:
    var sr = _screen_rect_from_world(state, group.rect.copy())
    var header_h = Float32(28.0) * state.zoom
    if header_h < Float32(18.0):
        header_h = Float32(18.0)
    if header_h > Float32(36.0):
        header_h = Float32(36.0)
    return Rect(sr.x, sr.y, sr.w, header_h)


def _begin_group_drag_if_pressed(
    mut ctx: Context, mut state: CanvasState, mut graph: Graph
) -> Bool:
    if not ctx.control.mouse_pressed_this_frame:
        return False
    var ng = len(state.groups)
    for rev in range(ng):
        var i = ng - 1 - rev
        var header = _group_header_rect_screen(state, state.groups[i].copy())
        if header.contains(ctx.control.mouse_pos.copy()):
            state.selected_group = state.groups[i].id
            _ = canvas_select_group_members(state, graph, state.groups[i].id)
            if not state.locked:
                state.dragging_group = state.groups[i].id
                state.drag_group_last_world = canvas_screen_to_world(
                    state, ctx.control.mouse_pos.copy()
                )
            return True
    return False


def _update_group_drag(
    mut ctx: Context, mut state: CanvasState, mut graph: Graph
) -> Bool:
    if state.dragging_group < Int64(0):
        return False
    if ctx.control.mouse_pressed_this_frame:
        return False
    if not ctx.input.mouse_held(_BTN_LEFT):
        return False
    var now = canvas_screen_to_world(state, ctx.control.mouse_pos.copy())
    var delta = Vec2(
        now.x - state.drag_group_last_world.x,
        now.y - state.drag_group_last_world.y,
    )
    if delta.x == Float32(0.0) and delta.y == Float32(0.0):
        return False
    if canvas_move_group(state, graph, state.dragging_group, delta.copy(), True):
        state.drag_group_last_world = now.copy()
        return True
    return False


def _draw_marquee(mut ctx: Context, state: CanvasState):
    if not state.marquee_active:
        return
    var r = _rect_from_points(state.marquee_start.copy(), state.marquee_end.copy())
    if r.w < _MARQUEE_MIN_DIST and r.h < _MARQUEE_MIN_DIST:
        return
    ctx.draw_rect(r.copy(), Color(90, 130, 220, 42))
    _draw_rect_border(ctx, r.copy(), Color(135, 170, 255, 210), Float32(1.0))


def _text_w_est(text: String, size_pt: Int32) -> Float32:
    return Float32(text.byte_length()) * Float32(size_pt) * Float32(0.47)


def _truncate_for_width(text: String, width: Float32, font_size: Int32) -> String:
    if text.byte_length() <= 0:
        return String("")
    var approx_chars = Int(width / (Float32(font_size) * Float32(0.52)))
    if approx_chars < 4:
        approx_chars = 4
    if text.byte_length() <= approx_chars:
        return text.copy()
    var keep = approx_chars - 3
    if keep < 1:
        keep = 1
    if keep > text.byte_length():
        keep = text.byte_length()
    return String(text[byte=0:keep]) + String("...")


def _sorted_canvas_field_keys(node: Node) -> List[String]:
    var keys = List[String]()
    for k in node.fields.keys():
        keys.append(k.copy())
    var n = len(keys)
    for i in range(1, n):
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            var tmp = keys[j - 1].copy()
            keys[j - 1] = keys[j].copy()
            keys[j] = tmp^
            j = j - 1
    return keys^


def _field_value_edit_str(fv: FieldValue) -> String:
    if fv.kind == FK_STRING:
        return fv.str_val.copy()
    if fv.kind == FK_INT:
        return String(fv.int_val)
    if fv.kind == FK_NUMBER:
        return String(fv.num_val)
    if fv.kind == FK_BOOL:
        if fv.bool_val:
            return String("true")
        return String("false")
    return String("")


def _field_value_hidden(fv: FieldValue) -> Bool:
    return fv.kind == FK_STRING and fv.str_val.byte_length() == 0


def _field_row_rect_for_key(
    node: Node,
    node_rect: Rect,
    title_h_screen: Float32,
    key: String,
) raises -> Rect:
    var x = node_rect.x + _FIELD_BODY_PAD_X
    var row_w = node_rect.w - _FIELD_BODY_PAD_X * Float32(2.0)
    var y0 = node_rect.y + title_h_screen + _FIELD_BODY_PAD_Y
    var max_y = node_rect.y + node_rect.h - _FIELD_BODY_PAD_Y
    if row_w < Float32(24.0):
        return Rect()
    var keys = _sorted_canvas_field_keys(node)
    var rendered_rows = 0
    for i in range(len(keys)):
        var k = keys[i].copy()
        var fv = node.fields[k].copy()
        if _field_value_hidden(fv):
            continue
        var row_y = y0 + Float32(rendered_rows) * (_FIELD_BODY_LINE_H + _FIELD_BODY_GAP)
        if row_y + _FIELD_BODY_H > max_y:
            break
        if k == key:
            return Rect(x, row_y, row_w, _FIELD_BODY_H)
        rendered_rows = rendered_rows + 1
    return Rect()


def _field_value_edit_rect(row: Rect, font_size: Int32) -> Rect:
    var label_w = row.w * Float32(0.38)
    if label_w < Float32(78.0):
        label_w = Float32(78.0)
    if label_w > Float32(190.0):
        label_w = Float32(190.0)
    return Rect(
        row.x + label_w + Float32(4.0),
        row.y + Float32(1.0),
        row.w - label_w - Float32(8.0),
        row.h - Float32(2.0),
    )


def _field_key_at_point(
    node: Node,
    node_rect: Rect,
    title_h_screen: Float32,
    point: Vec2,
) raises -> String:
    var x = node_rect.x + _FIELD_BODY_PAD_X
    var row_w = node_rect.w - _FIELD_BODY_PAD_X * Float32(2.0)
    var y0 = node_rect.y + title_h_screen + _FIELD_BODY_PAD_Y
    var max_y = node_rect.y + node_rect.h - _FIELD_BODY_PAD_Y
    if row_w < Float32(24.0):
        return String("")
    var keys = _sorted_canvas_field_keys(node)
    var rendered_rows = 0
    for i in range(len(keys)):
        var key = keys[i].copy()
        var fv = node.fields[key].copy()
        if _field_value_hidden(fv):
            continue
        var row_y = y0 + Float32(rendered_rows) * (_FIELD_BODY_LINE_H + _FIELD_BODY_GAP)
        if row_y + _FIELD_BODY_H > max_y:
            break
        var r = Rect(x, row_y, row_w, _FIELD_BODY_H)
        if r.contains(point.copy()):
            return key^
        rendered_rows = rendered_rows + 1
    return String("")


def _node_media_rect_for_canvas(node: Node, node_rect: Rect, title_h_screen: Float32) raises -> Rect:
    var row_w = node_rect.w - _FIELD_BODY_PAD_X * Float32(2.0)
    if row_w < Float32(24.0):
        return Rect()
    var y0 = node_rect.y + title_h_screen + _FIELD_BODY_PAD_Y
    var max_y = node_rect.y + node_rect.h - _FIELD_BODY_PAD_Y
    var keys = _sorted_canvas_field_keys(node)
    var rendered_rows = 0
    var next_y = y0
    for i in range(len(keys)):
        var key = keys[i].copy()
        var fv = node.fields[key].copy()
        if _field_value_hidden(fv):
            continue
        var row_y = y0 + Float32(rendered_rows) * (_FIELD_BODY_LINE_H + _FIELD_BODY_GAP)
        if row_y + _FIELD_BODY_H > max_y:
            break
        next_y = row_y + _FIELD_BODY_H + Float32(10.0)
        rendered_rows = rendered_rows + 1
    return Rect(
        node_rect.x + _FIELD_BODY_PAD_X,
        next_y + Float32(2.0),
        row_w,
        max_y - next_y - Float32(2.0),
    )


def _bbox_stage_rect(media_rect: Rect) -> Rect:
    if media_rect.w < Float32(120.0) or media_rect.h < Float32(72.0):
        return Rect()
    return Rect(
        media_rect.x + Float32(10.0),
        media_rect.y + Float32(10.0),
        media_rect.w - Float32(20.0),
        media_rect.h - Float32(38.0),
    )


def _clamp01(v: Float32) -> Float32:
    if v < Float32(0.0):
        return Float32(0.0)
    if v > Float32(1.0):
        return Float32(1.0)
    return v


def _clamp_bbox_rect(r: Rect) -> Rect:
    var x = _clamp01(r.x)
    var y = _clamp01(r.y)
    var w = r.w
    var h = r.h
    if w < _BBOX_MIN_SIZE:
        w = _BBOX_MIN_SIZE
    if h < _BBOX_MIN_SIZE:
        h = _BBOX_MIN_SIZE
    if w > Float32(1.0):
        w = Float32(1.0)
    if h > Float32(1.0):
        h = Float32(1.0)
    if x + w > Float32(1.0):
        x = Float32(1.0) - w
    if y + h > Float32(1.0):
        y = Float32(1.0) - h
    if x < Float32(0.0):
        x = Float32(0.0)
    if y < Float32(0.0):
        y = Float32(0.0)
    return Rect(x, y, w, h)


def _resize_bbox_rect(start: Rect, dx: Float32, dy: Float32, mode: Int32) -> Rect:
    var left = start.x
    var top = start.y
    var right = start.x + start.w
    var bottom = start.y + start.h
    if (
        mode == _BBOX_DRAG_RESIZE_NW
        or mode == _BBOX_DRAG_RESIZE_SW
        or mode == _BBOX_DRAG_RESIZE_W
    ):
        left = left + dx
    if (
        mode == _BBOX_DRAG_RESIZE_NE
        or mode == _BBOX_DRAG_RESIZE_SE
        or mode == _BBOX_DRAG_RESIZE_E
    ):
        right = right + dx
    if (
        mode == _BBOX_DRAG_RESIZE_NW
        or mode == _BBOX_DRAG_RESIZE_NE
        or mode == _BBOX_DRAG_RESIZE_N
    ):
        top = top + dy
    if (
        mode == _BBOX_DRAG_RESIZE_SW
        or mode == _BBOX_DRAG_RESIZE_SE
        or mode == _BBOX_DRAG_RESIZE_S
    ):
        bottom = bottom + dy

    if left < Float32(0.0):
        left = Float32(0.0)
    if top < Float32(0.0):
        top = Float32(0.0)
    if right > Float32(1.0):
        right = Float32(1.0)
    if bottom > Float32(1.0):
        bottom = Float32(1.0)

    if right - left < _BBOX_MIN_SIZE:
        if (
            mode == _BBOX_DRAG_RESIZE_NW
            or mode == _BBOX_DRAG_RESIZE_SW
            or mode == _BBOX_DRAG_RESIZE_W
        ):
            left = right - _BBOX_MIN_SIZE
            if left < Float32(0.0):
                left = Float32(0.0)
                right = _BBOX_MIN_SIZE
        else:
            right = left + _BBOX_MIN_SIZE
            if right > Float32(1.0):
                right = Float32(1.0)
                left = Float32(1.0) - _BBOX_MIN_SIZE
    if bottom - top < _BBOX_MIN_SIZE:
        if (
            mode == _BBOX_DRAG_RESIZE_NW
            or mode == _BBOX_DRAG_RESIZE_NE
            or mode == _BBOX_DRAG_RESIZE_N
        ):
            top = bottom - _BBOX_MIN_SIZE
            if top < Float32(0.0):
                top = Float32(0.0)
                bottom = _BBOX_MIN_SIZE
        else:
            bottom = top + _BBOX_MIN_SIZE
            if bottom > Float32(1.0):
                bottom = Float32(1.0)
                top = Float32(1.0) - _BBOX_MIN_SIZE
    return Rect(left, top, right - left, bottom - top)


def _bbox_screen_rect(stage: Rect, bbox: _CanvasBBox) -> Rect:
    return Rect(
        stage.x + bbox.rect.x * stage.w,
        stage.y + bbox.rect.y * stage.h,
        bbox.rect.w * stage.w,
        bbox.rect.h * stage.h,
    )


def _bbox_handle_rect_at(r: Rect, mode: Int32) -> Rect:
    var s = _BBOX_HANDLE
    var cx = r.x + r.w
    var cy = r.y + r.h
    if mode == _BBOX_DRAG_RESIZE_NW:
        cx = r.x
        cy = r.y
    elif mode == _BBOX_DRAG_RESIZE_NE:
        cx = r.x + r.w
        cy = r.y
    elif mode == _BBOX_DRAG_RESIZE_SW:
        cx = r.x
        cy = r.y + r.h
    elif mode == _BBOX_DRAG_RESIZE_E:
        cx = r.x + r.w
        cy = r.y + r.h * Float32(0.5)
    elif mode == _BBOX_DRAG_RESIZE_W:
        cx = r.x
        cy = r.y + r.h * Float32(0.5)
    elif mode == _BBOX_DRAG_RESIZE_N:
        cx = r.x + r.w * Float32(0.5)
        cy = r.y
    elif mode == _BBOX_DRAG_RESIZE_S:
        cx = r.x + r.w * Float32(0.5)
        cy = r.y + r.h
    return Rect(cx - s * Float32(0.5), cy - s * Float32(0.5), s, s)


def _bbox_color_for_index(index: Int) -> Color:
    if index == 1:
        return Color(255, 145, 220, 225)
    if index == 2:
        return Color(135, 230, 150, 225)
    if index == 3:
        return Color(255, 205, 100, 225)
    if index == 4:
        return Color(165, 145, 255, 225)
    return Color(105, 190, 255, 225)


def _bbox_label_rect(r: Rect, label: String, font_size: Int32) -> Rect:
    var label_size = font_size - 5
    if label_size < 9:
        label_size = 9
    var chip_h = Float32(label_size) + Float32(7.0)
    var w = _text_w_est(label.copy(), label_size) + Float32(18.0)
    if w < Float32(64.0):
        w = Float32(64.0)
    if w > r.w:
        w = r.w
    return Rect(r.x, r.y, w, chip_h)


def _json_number_field(obj: JsonValue, key: String, default_value: Float32) -> Float32:
    if obj.kind != JK_OBJECT:
        return default_value
    var v = obj.get_object_field(key)
    if v.kind == JK_NUMBER:
        return Float32(v.num_val)
    return default_value


def _json_string_field(obj: JsonValue, key: String, default_value: String) -> String:
    if obj.kind != JK_OBJECT:
        return default_value.copy()
    var v = obj.get_object_field(key)
    if v.kind == JK_STRING:
        return v.str_val.copy()
    return default_value.copy()


def _default_bboxes() -> List[_CanvasBBox]:
    var boxes = List[_CanvasBBox]()
    boxes.append(
        _CanvasBBox(
            String("subject"),
            Rect(Float32(0.16), Float32(0.12), Float32(0.42), Float32(0.72)),
            Color(105, 190, 255, 225),
        )
    )
    boxes.append(
        _CanvasBBox(
            String("motion cue"),
            Rect(Float32(0.58), Float32(0.25), Float32(0.26), Float32(0.30)),
            Color(255, 145, 220, 225),
        )
    )
    return boxes^


def _load_bboxes_from_node(node: Node) raises -> List[_CanvasBBox]:
    if not (String("elements_data") in node.fields):
        return _default_bboxes()
    var fv = node.fields[String("elements_data")].copy()
    if fv.kind != FK_STRING or fv.str_val.byte_length() == 0:
        return _default_bboxes()
    try:
        var root = parse_json(fv.str_val.copy())
        if root.kind != JK_ARRAY:
            return _default_bboxes()
        var boxes = List[_CanvasBBox]()
        for i in range(len(root.arr_val)):
            var obj = root.arr_val[i].copy()
            if obj.kind != JK_OBJECT:
                continue
            var label = _json_string_field(obj.copy(), String("label"), String("box ") + String(i + 1))
            var x = _json_number_field(obj.copy(), String("x"), Float32(0.10))
            var y = _json_number_field(obj.copy(), String("y"), Float32(0.10))
            var w = _json_number_field(obj.copy(), String("w"), Float32(0.30))
            var h = _json_number_field(obj.copy(), String("h"), Float32(0.30))
            var color = _bbox_color_for_index(i)
            boxes.append(_CanvasBBox(label^, _clamp_bbox_rect(Rect(x, y, w, h)), color^))
        if len(boxes) == 0 and len(root.arr_val) == 0:
            return boxes^
        if len(boxes) == 0:
            return _default_bboxes()
        return boxes^
    except e:
        return _default_bboxes()


def _store_bboxes_to_node(mut graph: Graph, node_idx: Int, boxes: List[_CanvasBBox]):
    var items = List[JsonValue]()
    for i in range(len(boxes)):
        var obj = JsonValue.empty_object()
        obj.set_object_field(String("label"), JsonValue.string(boxes[i].label.copy()))
        obj.set_object_field(String("x"), JsonValue.number(Float64(boxes[i].rect.x)))
        obj.set_object_field(String("y"), JsonValue.number(Float64(boxes[i].rect.y)))
        obj.set_object_field(String("w"), JsonValue.number(Float64(boxes[i].rect.w)))
        obj.set_object_field(String("h"), JsonValue.number(Float64(boxes[i].rect.h)))
        items.append(obj^)
    graph.nodes[node_idx].fields[String("elements_data")] = FieldValue.string(
        emit_json(JsonValue.array(items^))
    )


def _clear_bbox_edit(mut state: CanvasState):
    state.bbox_edit_node = RET_ID_NONE
    state.bbox_edit_index = Int64(-1)
    state.bbox_edit_buffer = String("")
    state.bbox_edit_state = TextEditState(single_line=True)


def _begin_bbox_label_edit(
    mut state: CanvasState,
    node_id: RetainedId,
    idx: Int64,
    label: String,
):
    state.bbox_selected_node = node_id
    state.bbox_selected_index = idx
    state.bbox_drag_node = RET_ID_NONE
    state.bbox_drag_index = Int64(-1)
    state.bbox_drag_mode = _BBOX_DRAG_NONE
    state.bbox_edit_node = node_id
    state.bbox_edit_index = idx
    state.bbox_edit_buffer = label.copy()
    state.bbox_edit_state = TextEditState(single_line=True)


def _commit_bbox_edit(mut state: CanvasState, mut graph: Graph) raises -> Bool:
    if state.bbox_edit_node == RET_ID_NONE:
        return False
    var node_idx = graph.find_node(state.bbox_edit_node)
    if node_idx < 0:
        _clear_bbox_edit(state)
        return False
    var boxes = _load_bboxes_from_node(graph.nodes[node_idx].copy())
    var idx = Int(state.bbox_edit_index)
    if idx < 0 or idx >= len(boxes):
        _clear_bbox_edit(state)
        return False
    boxes[idx].label = state.bbox_edit_buffer.copy()
    _store_bboxes_to_node(graph, node_idx, boxes^)
    _clear_bbox_edit(state)
    return True


def _delete_selected_bbox(mut state: CanvasState, mut graph: Graph) raises -> Bool:
    if state.bbox_selected_node == RET_ID_NONE or state.bbox_selected_index < Int64(0):
        return False
    var node_idx = graph.find_node(state.bbox_selected_node)
    if node_idx < 0:
        state.bbox_selected_node = RET_ID_NONE
        state.bbox_selected_index = Int64(-1)
        _clear_bbox_edit(state)
        return False
    var boxes = _load_bboxes_from_node(graph.nodes[node_idx].copy())
    var selected = Int(state.bbox_selected_index)
    if selected < 0 or selected >= len(boxes):
        return False
    var next = List[_CanvasBBox]()
    for i in range(len(boxes)):
        if i != selected:
            next.append(boxes[i].copy())
    _store_bboxes_to_node(graph, node_idx, next^)
    state.bbox_selected_node = RET_ID_NONE
    state.bbox_selected_index = Int64(-1)
    state.bbox_drag_node = RET_ID_NONE
    state.bbox_drag_index = Int64(-1)
    state.bbox_drag_mode = _BBOX_DRAG_NONE
    _clear_bbox_edit(state)
    return True


def _bbox_hit_test(boxes: List[_CanvasBBox], stage: Rect, point: Vec2) -> Tuple[Int64, Int32]:
    for rev in range(len(boxes)):
        var i = len(boxes) - 1 - rev
        var r = _bbox_screen_rect(stage.copy(), boxes[i].copy())
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_SE).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_SE)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_NW).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_NW)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_NE).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_NE)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_SW).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_SW)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_E).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_E)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_W).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_W)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_N).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_N)
        if _bbox_handle_rect_at(r.copy(), _BBOX_DRAG_RESIZE_S).contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_RESIZE_S)
        if r.contains(point.copy()):
            return (Int64(i), _BBOX_DRAG_MOVE)
    return (Int64(-1), _BBOX_DRAG_NONE)


def _begin_bbox_drag_if_pressed(
    mut ctx: Context,
    mut state: CanvasState,
    mut graph: Graph,
    node: Node,
    node_rect: Rect,
) raises -> Bool:
    if not ctx.control.mouse_pressed_this_frame:
        return False
    if node.type_id != String("core/ideogram4_prompt_builder"):
        return False
    var media_rect = _node_media_rect_for_canvas(node, node_rect.copy(), _TITLE_BAR_H * state.zoom)
    var stage = _bbox_stage_rect(media_rect.copy())
    if stage.w <= Float32(0.0) or stage.h <= Float32(0.0):
        return False
    if not stage.contains(ctx.control.mouse_pos.copy()):
        return False
    var node_idx = graph.find_node(node.id)
    if node_idx < 0:
        return False
    var boxes = _load_bboxes_from_node(node)
    for rev in range(len(boxes)):
        var label_i = len(boxes) - 1 - rev
        var sr = _bbox_screen_rect(stage.copy(), boxes[label_i].copy())
        var lr = _bbox_label_rect(sr.copy(), boxes[label_i].label.copy(), ctx.theme.font_size_pt)
        if lr.contains(ctx.control.mouse_pos.copy()):
            _begin_bbox_label_edit(
                state,
                node.id,
                Int64(label_i),
                boxes[label_i].label.copy(),
            )
            _clear_field_edit(state)
            return True
    var hit = _bbox_hit_test(boxes, stage.copy(), ctx.control.mouse_pos.copy())
    var selected_idx = hit[0]
    var drag_mode = hit[1]
    if selected_idx < Int64(0):
        var nx = (ctx.control.mouse_pos.x - stage.x) / stage.w
        var ny = (ctx.control.mouse_pos.y - stage.y) / stage.h
        var new_rect = _clamp_bbox_rect(
            Rect(
                nx - Float32(0.11),
                ny - Float32(0.10),
                Float32(0.22),
                Float32(0.20),
            )
        )
        var label = String("box ") + String(len(boxes) + 1)
        var color = _bbox_color_for_index(len(boxes))
        boxes.append(_CanvasBBox(label^, new_rect.copy(), color^))
        selected_idx = Int64(len(boxes) - 1)
        drag_mode = _BBOX_DRAG_MOVE
        _store_bboxes_to_node(graph, node_idx, boxes.copy())
    state.bbox_selected_node = node.id
    state.bbox_selected_index = selected_idx
    state.bbox_drag_node = node.id
    state.bbox_drag_index = selected_idx
    state.bbox_drag_mode = drag_mode
    state.bbox_drag_start_mouse = ctx.control.mouse_pos.copy()
    state.bbox_drag_start_rect = boxes[Int(selected_idx)].rect.copy()
    _clear_field_edit(state)
    _clear_bbox_edit(state)
    return True


def _update_bbox_drag(mut ctx: Context, mut state: CanvasState, mut graph: Graph) raises -> Bool:
    if state.bbox_drag_node == RET_ID_NONE:
        return False
    if ctx.control.mouse_released_this_frame:
        state.bbox_drag_node = RET_ID_NONE
        state.bbox_drag_index = Int64(-1)
        state.bbox_drag_mode = _BBOX_DRAG_NONE
        return True
    if not ctx.input.mouse_held(_BTN_LEFT):
        return False
    var node_idx = graph.find_node(state.bbox_drag_node)
    if node_idx < 0:
        state.bbox_drag_node = RET_ID_NONE
        return True
    var node = graph.nodes[node_idx].copy()
    var screen_pos = canvas_world_to_screen(state, node.position.copy())
    var node_rect = Rect(screen_pos.x, screen_pos.y, node.size.x * state.zoom, node.size.y * state.zoom)
    var media_rect = _node_media_rect_for_canvas(node, node_rect.copy(), _TITLE_BAR_H * state.zoom)
    var stage = _bbox_stage_rect(media_rect.copy())
    if stage.w <= Float32(0.0) or stage.h <= Float32(0.0):
        return False
    var boxes = _load_bboxes_from_node(node)
    var idx = Int(state.bbox_drag_index)
    if idx < 0 or idx >= len(boxes):
        return False
    var dx = (ctx.control.mouse_pos.x - state.bbox_drag_start_mouse.x) / stage.w
    var dy = (ctx.control.mouse_pos.y - state.bbox_drag_start_mouse.y) / stage.h
    var next = state.bbox_drag_start_rect.copy()
    if state.bbox_drag_mode == _BBOX_DRAG_MOVE:
        next.x = next.x + dx
        next.y = next.y + dy
        next = _clamp_bbox_rect(next.copy())
    else:
        next = _resize_bbox_rect(next.copy(), dx, dy, state.bbox_drag_mode)
    boxes[idx].rect = next.copy()
    _store_bboxes_to_node(graph, node_idx, boxes^)
    return True


def _draw_bbox_handle(
    mut ctx: Context,
    r: Rect,
    mode: Int32,
    color: Color,
    selected: Bool,
):
    var handle = _bbox_handle_rect_at(r.copy(), mode)
    var alpha = UInt8(178)
    if selected:
        alpha = UInt8(238)
    ctx.draw_rect(handle.copy(), Color(color.r, color.g, color.b, alpha))
    _draw_rect_border(ctx, handle.copy(), Color(5, 8, 14, 190), Float32(1.0))


def _draw_bbox_handles(mut ctx: Context, r: Rect, color: Color, selected: Bool):
    _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_NW, color.copy(), selected)
    _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_NE, color.copy(), selected)
    _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_SW, color.copy(), selected)
    _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_SE, color.copy(), selected)
    if selected:
        _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_N, color.copy(), selected)
        _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_S, color.copy(), selected)
        _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_E, color.copy(), selected)
        _draw_bbox_handle(ctx, r.copy(), _BBOX_DRAG_RESIZE_W, color.copy(), selected)


def _draw_bbox_editor(
    mut ctx: Context,
    state: CanvasState,
    node: Node,
    node_rect: Rect,
) raises:
    if node.type_id != String("core/ideogram4_prompt_builder"):
        return
    var media_rect = _node_media_rect_for_canvas(node, node_rect.copy(), _TITLE_BAR_H * state.zoom)
    var stage = _bbox_stage_rect(media_rect.copy())
    if stage.w <= Float32(0.0) or stage.h <= Float32(0.0):
        return
    var boxes = _load_bboxes_from_node(node)
    for i in range(len(boxes)):
        var r = _bbox_screen_rect(stage.copy(), boxes[i].copy())
        var selected = (
            state.bbox_selected_node == node.id
            and state.bbox_selected_index == Int64(i)
        )
        var fill_alpha = UInt8(36)
        var border_alpha = UInt8(225)
        var line = Float32(1.0)
        if selected:
            fill_alpha = UInt8(62)
            border_alpha = UInt8(255)
            line = Float32(2.0)
        ctx.draw_rect(r.copy(), Color(boxes[i].color.r, boxes[i].color.g, boxes[i].color.b, fill_alpha))
        var border = Color(boxes[i].color.r, boxes[i].color.g, boxes[i].color.b, border_alpha)
        ctx.draw_rect(Rect(r.x, r.y, r.w, line), border.copy())
        ctx.draw_rect(Rect(r.x, r.y + r.h - line, r.w, line), border.copy())
        ctx.draw_rect(Rect(r.x, r.y, line, r.h), border.copy())
        ctx.draw_rect(Rect(r.x + r.w - line, r.y, line, r.h), border.copy())
        _draw_bbox_handles(ctx, r.copy(), boxes[i].color.copy(), selected)
        if ctx.theme.font_id != 0 and boxes[i].label.byte_length() > 0:
            var label_size = ctx.theme.font_size_pt - 5
            if label_size < 9:
                label_size = 9
            var label = _truncate_for_width(boxes[i].label.copy(), r.w - Float32(8.0), label_size)
            var label_rect = _bbox_label_rect(r.copy(), label.copy(), ctx.theme.font_size_pt)
            var label_bg = Color(7, 9, 13, 218)
            if selected:
                label_bg = Color(10, 16, 26, 240)
            ctx.draw_rect(label_rect.copy(), label_bg)
            ctx.draw_text(
                ctx.theme.font_id,
                label_size,
                Vec2(r.x + Float32(4.0), r.y + Float32(label_size) + Float32(2.0)),
                border.copy(),
                label,
            )


def _draw_bbox_edit_overlay(
    mut ctx: Context,
    mut state: CanvasState,
    mut graph: Graph,
    node: Node,
    node_rect: Rect,
) raises -> Bool:
    if state.bbox_edit_node != node.id:
        return False
    var media_rect = _node_media_rect_for_canvas(node, node_rect.copy(), _TITLE_BAR_H * state.zoom)
    var stage = _bbox_stage_rect(media_rect.copy())
    if stage.w <= Float32(0.0) or stage.h <= Float32(0.0):
        _clear_bbox_edit(state)
        return False
    var boxes = _load_bboxes_from_node(node)
    var idx = Int(state.bbox_edit_index)
    if idx < 0 or idx >= len(boxes):
        _clear_bbox_edit(state)
        return False
    var sr = _bbox_screen_rect(stage.copy(), boxes[idx].copy())
    var edit_rect = _bbox_label_rect(sr.copy(), boxes[idx].label.copy(), ctx.theme.font_size_pt)
    if edit_rect.w < Float32(110.0):
        edit_rect.w = Float32(110.0)
    if edit_rect.x + edit_rect.w > stage.x + stage.w:
        edit_rect.x = stage.x + stage.w - edit_rect.w
    if edit_rect.x < stage.x:
        edit_rect.x = stage.x
    ctx.begin_panel(edit_rect.copy())
    var widths = List[Int32]()
    widths.append(Int32(Int(edit_rect.w)))
    ctx.layout_row(widths^, Int32(Int(edit_rect.h)))
    _ = text_edit(
        ctx,
        String("bbox_label_edit_") + String(node.id) + String("_") + String(idx),
        state.bbox_edit_buffer,
        state.bbox_edit_state,
    )
    ctx.end_panel()
    if ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
        _clear_bbox_edit(state)
        return False
    if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
        return _commit_bbox_edit(state, graph)
    return False


def _begin_field_edit(
    mut state: CanvasState,
    node_id: RetainedId,
    field_name: String,
    fv: FieldValue,
):
    state.editing_field_node = node_id
    state.editing_field_name = field_name.copy()
    state.editing_field_buffer = _field_value_edit_str(fv)
    state.editing_field_kind = fv.kind
    state.editing_field_state = TextEditState(single_line=True)
    _clear_bbox_edit(state)


def _clear_field_edit(mut state: CanvasState):
    state.editing_field_node = RET_ID_NONE
    state.editing_field_name = String("")
    state.editing_field_buffer = String("")
    state.editing_field_kind = Int32(0)
    state.editing_field_state = TextEditState(single_line=True)


def _is_space_byte(c: UInt8) -> Bool:
    return c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13)


def _trim_bounds(text: String) -> Tuple[Int, Int]:
    var n = text.byte_length()
    var start = 0
    var end = n
    var ptr = text.unsafe_ptr()
    while start < end and _is_space_byte(ptr[start]):
        start = start + 1
    while end > start and _is_space_byte(ptr[end - 1]):
        end = end - 1
    return (start, end)


def _parse_i64(text: String) -> Tuple[Bool, Int64]:
    var bounds = _trim_bounds(text)
    var i = bounds[0]
    var end = bounds[1]
    if i >= end:
        return (False, Int64(0))
    var ptr = text.unsafe_ptr()
    var sign = Int64(1)
    if ptr[i] == UInt8(45):
        sign = Int64(-1)
        i = i + 1
    elif ptr[i] == UInt8(43):
        i = i + 1
    if i >= end:
        return (False, Int64(0))
    var value = Int64(0)
    while i < end:
        var c = ptr[i]
        if c < UInt8(48) or c > UInt8(57):
            return (False, Int64(0))
        value = value * Int64(10) + Int64(c - UInt8(48))
        i = i + 1
    return (True, value * sign)


def _parse_f64(text: String) -> Tuple[Bool, Float64]:
    var bounds = _trim_bounds(text)
    var i = bounds[0]
    var end = bounds[1]
    if i >= end:
        return (False, Float64(0.0))
    var ptr = text.unsafe_ptr()
    var sign = Float64(1.0)
    if ptr[i] == UInt8(45):
        sign = Float64(-1.0)
        i = i + 1
    elif ptr[i] == UInt8(43):
        i = i + 1
    var value = Float64(0.0)
    var seen_digit = False
    while i < end:
        var c = ptr[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        value = value * Float64(10.0) + Float64(c - UInt8(48))
        seen_digit = True
        i = i + 1
    if i < end and ptr[i] == UInt8(46):
        i = i + 1
        var place = Float64(0.1)
        while i < end:
            var c = ptr[i]
            if c < UInt8(48) or c > UInt8(57):
                return (False, Float64(0.0))
            value = value + Float64(c - UInt8(48)) * place
            place = place * Float64(0.1)
            seen_digit = True
            i = i + 1
    if not seen_digit or i != end:
        return (False, Float64(0.0))
    return (True, value * sign)


def _parse_bool(text: String) -> Tuple[Bool, Bool]:
    var bounds = _trim_bounds(text)
    var start = bounds[0]
    var end = bounds[1]
    if start >= end:
        return (False, False)
    var trimmed = String(text[byte=start:end])
    if trimmed == String("true") or trimmed == String("1") or trimmed == String("on"):
        return (True, True)
    if trimmed == String("false") or trimmed == String("0") or trimmed == String("off"):
        return (True, False)
    return (False, False)


def _commit_field_edit(mut state: CanvasState, mut graph: Graph) raises -> Bool:
    if state.editing_field_node == RET_ID_NONE:
        return False
    var idx = graph.find_node(state.editing_field_node)
    if idx < 0:
        _clear_field_edit(state)
        return False
    var key = state.editing_field_name.copy()
    if not (key in graph.nodes[idx].fields):
        _clear_field_edit(state)
        return False
    if state.editing_field_kind == FK_INT:
        var parsed = _parse_i64(state.editing_field_buffer.copy())
        if not parsed[0]:
            return False
        graph.nodes[idx].fields[key] = FieldValue.int_(parsed[1])
    elif state.editing_field_kind == FK_NUMBER:
        var parsed = _parse_f64(state.editing_field_buffer.copy())
        if not parsed[0]:
            return False
        graph.nodes[idx].fields[key] = FieldValue.number(parsed[1])
    elif state.editing_field_kind == FK_BOOL:
        var parsed = _parse_bool(state.editing_field_buffer.copy())
        if not parsed[0]:
            return False
        graph.nodes[idx].fields[key] = FieldValue.bool_(parsed[1])
    else:
        graph.nodes[idx].fields[key] = FieldValue.string(state.editing_field_buffer.copy())
    _clear_field_edit(state)
    return True


def _is_checkpoint_visual_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/load_checkpoint")
        or node.type_id == String("CheckpointLoaderSimple")
        or node.title == String("Load Diffusion Model")
        or node.title == String("Load Klein 9B Checkpoint")
    )


def _is_clip_visual_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/encode_prompt")
        or node.type_id == String("CLIPTextEncode")
        or node.title == String("Load CLIP")
        or node.title == String("Positive Prompt")
        or node.title == String("Negative Prompt")
    )


def _is_latent_visual_node(node: Node) -> Bool:
    return node.type_id == String("EmptyLatentImage")


def _is_sampler_visual_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/k_sampler")
        or node.type_id == String("KSampler")
        or node.title == String("Load LoRA")
        or node.title == String("K-Sampler")
    )


def _is_vae_visual_node(node: Node) -> Bool:
    return (
        node.type_id == String("core/vae_decode")
        or node.type_id == String("VAEDecode")
        or node.title == String("Load VAE")
        or node.title == String("VAE Decode")
    )


def _is_save_image_visual_node(node: Node) -> Bool:
    return node.type_id == String("core/save_image") or node.type_id == String("SaveImage")


def _node_ui_color(node: Node) raises -> String:
    if String("ui_color") in node.fields:
        var fv = node.fields[String("ui_color")].copy()
        if fv.kind == FK_STRING and fv.str_val.byte_length() > 0:
            return fv.str_val.copy()
    return String("default")


def _node_body_color(node: Node, selected: Bool) raises -> Color:
    var override = _node_ui_color(node)
    if override == String("gold"):
        return Color(112, 95, 48, 246) if selected else Color(96, 82, 42, 238)
    if override == String("blue"):
        return Color(44, 76, 116, 246) if selected else Color(34, 56, 88, 238)
    if override == String("purple"):
        return Color(75, 62, 116, 246) if selected else Color(55, 46, 88, 238)
    if override == String("green"):
        return Color(52, 92, 64, 246) if selected else Color(38, 68, 48, 238)
    if override == String("teal"):
        return Color(42, 88, 96, 246) if selected else Color(32, 66, 74, 238)
    if override == String("gray"):
        return Color(68, 70, 78, 246) if selected else Color(50, 52, 60, 238)
    if node.type_id == String("core/load_image"):
        if selected:
            return Color(46, 82, 62, 246)
        return Color(34, 58, 46, 238)
    if node.type_id == String("core/load_video") or node.type_id == String("core/preview_video"):
        if selected:
            return Color(38, 76, 90, 246)
        return Color(30, 56, 66, 238)
    if node.type_id == String("core/ideogram4_prompt_builder"):
        if selected:
            return Color(50, 62, 96, 246)
        return Color(37, 46, 70, 238)
    if node.type_id == String("core/ideogram4_magic_prompt") or node.type_id == String("core/ideogram4_generate"):
        if selected:
            return Color(62, 58, 94, 246)
        return Color(45, 43, 68, 238)
    if _is_checkpoint_visual_node(node):
        if selected:
            return Color(112, 95, 48, 246)
        return Color(96, 82, 42, 238)
    if _is_vae_visual_node(node):
        if selected:
            return Color(46, 90, 98, 246)
        return Color(35, 68, 76, 238)
    if _is_clip_visual_node(node):
        if selected:
            return Color(108, 84, 46, 246)
        return Color(89, 70, 39, 238)
    if _is_latent_visual_node(node):
        if selected:
            return Color(42, 76, 92, 246)
        return Color(32, 58, 72, 238)
    if _is_sampler_visual_node(node):
        if selected:
            return Color(61, 60, 108, 246)
        return Color(49, 49, 88, 238)
    if _is_save_image_visual_node(node):
        if selected:
            return Color(52, 84, 62, 246)
        return Color(38, 64, 48, 238)
    if selected:
        return Color(58, 60, 88, 246)
    return Color(42, 43, 52, 238)


def _node_title_color(node: Node) raises -> Color:
    var override = _node_ui_color(node)
    if override == String("gold"):
        return Color(72, 52, 30, 255)
    if override == String("blue"):
        return Color(24, 48, 82, 255)
    if override == String("purple"):
        return Color(42, 32, 78, 255)
    if override == String("green"):
        return Color(24, 62, 36, 255)
    if override == String("teal"):
        return Color(22, 58, 66, 255)
    if override == String("gray"):
        return Color(44, 44, 50, 255)
    if node.type_id == String("core/load_image"):
        return Color(30, 72, 46, 255)
    if node.type_id == String("core/load_video") or node.type_id == String("core/preview_video"):
        return Color(28, 68, 82, 255)
    if node.type_id == String("core/ideogram4_prompt_builder"):
        return Color(34, 52, 92, 255)
    if node.type_id == String("core/ideogram4_magic_prompt") or node.type_id == String("core/ideogram4_generate"):
        return Color(50, 42, 86, 255)
    if _is_checkpoint_visual_node(node):
        return Color(62, 46, 34, 255)
    if _is_vae_visual_node(node):
        return Color(24, 58, 66, 255)
    if _is_clip_visual_node(node):
        return Color(62, 46, 34, 255)
    if _is_latent_visual_node(node):
        return Color(22, 52, 66, 255)
    if _is_sampler_visual_node(node):
        return Color(31, 30, 55, 255)
    if _is_save_image_visual_node(node):
        return Color(28, 58, 38, 255)
    return Color(36, 38, 48, 255)


def _node_socket_glyph_color(node: Node) raises -> Color:
    var override = _node_ui_color(node)
    if override == String("gold"):
        return Color(232, 184, 72, 255)
    if override == String("blue"):
        return Color(110, 170, 255, 255)
    if override == String("purple"):
        return Color(184, 142, 245, 255)
    if override == String("green"):
        return Color(120, 210, 145, 255)
    if override == String("teal"):
        return Color(92, 205, 220, 255)
    if override == String("gray"):
        return Color(172, 176, 188, 255)
    if node.type_id == String("core/load_image"):
        return Color(104, 210, 142, 255)
    if node.type_id == String("core/load_video") or node.type_id == String("core/preview_video"):
        return Color(92, 185, 245, 255)
    if node.type_id == String("core/ideogram4_prompt_builder"):
        return Color(116, 165, 245, 255)
    if node.type_id == String("core/ideogram4_magic_prompt") or node.type_id == String("core/ideogram4_generate"):
        return Color(184, 142, 245, 255)
    if _is_sampler_visual_node(node):
        return Color(116, 112, 164, 255)
    if _is_save_image_visual_node(node):
        return Color(120, 210, 145, 255)
    if _is_checkpoint_visual_node(node) or _is_clip_visual_node(node):
        return Color(218, 178, 88, 255)
    if _is_latent_visual_node(node) or _is_vae_visual_node(node):
        return Color(92, 185, 220, 255)
    return Color(122, 110, 82, 255)


def _draw_node_shell(
    mut ctx: Context,
    node_rect: Rect,
    title_rect: Rect,
    body_color: Color,
    title_color: Color,
    border_color: Color,
    selected: Bool,
    zoom: Float32,
):
    var radius = _NODE_RADIUS * zoom
    if radius < Float32(4.0):
        radius = Float32(4.0)
    if radius > Float32(12.0):
        radius = Float32(12.0)
    tess_drop_shadow(
        ctx,
        node_rect.copy(),
        radius,
        _NODE_SHADOW_BLUR,
        Float32(0.0),
        Float32(2.0),
        Color(0, 0, 0, 78),
    )
    tess_rounded_rect(ctx, node_rect.copy(), radius, body_color.copy(), 5)
    tess_rounded_rect(ctx, title_rect.copy(), radius, title_color.copy(), 5)
    ctx.draw_rect(
        Rect(
            title_rect.x,
            title_rect.y + title_rect.h - radius,
            title_rect.w,
            radius,
        ),
        title_color.copy(),
    )
    var border_t = Float32(1.0)
    if selected:
        border_t = Float32(2.0)
        ctx.draw_rect(Rect(node_rect.x, node_rect.y, Float32(4.0), node_rect.h), border_color.copy())
    _draw_rect_border(ctx, node_rect.copy(), border_color.copy(), border_t)


def _draw_port_label(
    mut ctx: Context,
    pos: Vec2,
    name: String,
    is_input: Bool,
):
    if ctx.theme.font_id == 0:
        return
    var port_font = ctx.theme.font_size_pt + 2
    var y = pos.y + Float32(4.0)
    var col = Color(190, 192, 205, 230)
    if is_input:
        var label = _truncate_for_width(name.copy(), Float32(132.0), port_font)
        ctx.draw_text(
            ctx.theme.font_id,
            port_font,
            Vec2(pos.x + Float32(11.0), y),
            col,
            label,
        )
    else:
        var label = _truncate_for_width(name.copy(), Float32(132.0), port_font)
        var w = _text_w_est(label, port_font)
        ctx.draw_text(
            ctx.theme.font_id,
            port_font,
            Vec2(pos.x - w - Float32(11.0), y),
            col,
            label,
        )


def _draw_port(mut ctx: Context, pos: Vec2, color: Color, active: Bool):
    var ring_color = Color(12, 13, 18, 255)
    if active:
        ring_color = Color(255, 255, 255, 220)
    tess_circle(ctx, pos.copy(), _PORT_RING_RADIUS, ring_color, 20)
    tess_circle(ctx, pos.copy(), _PORT_DOT_SIZE * Float32(0.5), color.copy(), 20)


def _node_resize_handle_rect(node_rect: Rect) -> Rect:
    return Rect(
        node_rect.x + node_rect.w - _NODE_RESIZE_HANDLE,
        node_rect.y + node_rect.h - _NODE_RESIZE_HANDLE,
        _NODE_RESIZE_HANDLE,
        _NODE_RESIZE_HANDLE,
    )


def _draw_node_resize_handle(mut ctx: Context, rect: Rect, active: Bool):
    var fill = Color(70, 78, 98, 230)
    var stroke = Color(150, 165, 205, 230)
    if active:
        fill = Color(90, 132, 190, 240)
        stroke = Color(220, 235, 255, 245)
    tess_rounded_rect(ctx, rect.copy(), Float32(4.0), fill.copy(), 4)
    ctx.draw_rect(Rect(rect.x + rect.w - Float32(5.0), rect.y + Float32(5.0), Float32(2.0), rect.h - Float32(8.0)), stroke.copy())
    ctx.draw_rect(Rect(rect.x + Float32(5.0), rect.y + rect.h - Float32(5.0), rect.w - Float32(8.0), Float32(2.0)), stroke.copy())


def _draw_field_edit_overlay(
    mut ctx: Context,
    mut state: CanvasState,
    mut graph: Graph,
    node: Node,
    node_rect: Rect,
) raises -> Bool:
    if state.editing_field_node != node.id:
        return False
    var row = _field_row_rect_for_key(
        node,
        node_rect.copy(),
        _TITLE_BAR_H * state.zoom,
        state.editing_field_name.copy(),
    )
    if row.w <= Float32(0.0) or row.h <= Float32(0.0):
        _clear_field_edit(state)
        return False
    var edit_rect = _field_value_edit_rect(row.copy(), ctx.theme.font_size_pt)
    if edit_rect.w < Float32(36.0):
        edit_rect = row.copy()
    ctx.begin_panel(edit_rect.copy())
    var widths = List[Int32]()
    widths.append(Int32(Int(edit_rect.w)))
    ctx.layout_row(widths^, Int32(Int(edit_rect.h)))
    _ = text_edit(
        ctx,
        String("field_edit_") + String(node.id) + String("_") + state.editing_field_name,
        state.editing_field_buffer,
        state.editing_field_state,
    )
    ctx.end_panel()
    if ctx.input.key_pressed(MOJOUI_KEY_ESCAPE):
        _clear_field_edit(state)
        return False
    if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
        return _commit_field_edit(state, graph)
    return False


def _draw_badge(
    mut ctx: Context,
    title_rect: Rect,
    mut x_right: Float32,
    label: String,
    fill: Color,
) -> Float32:
    if ctx.theme.font_id == 0:
        return x_right
    var w = _text_w_est(label, ctx.theme.font_size_pt) + Float32(10.0)
    var r = Rect(x_right - w, title_rect.y + Float32(4.0), w, Float32(16.0))
    tess_rounded_rect(ctx, r.copy(), Float32(4.0), fill.copy(), 4)
    ctx.draw_text(
        ctx.theme.font_id,
        ctx.theme.font_size_pt,
        Vec2(r.x + Float32(5.0), r.y + Float32(12.0)),
        Color(245, 245, 250, 240),
        label,
    )
    return r.x - Float32(4.0)


def _draw_node_status_badges(mut ctx: Context, node: Node, title_rect: Rect):
    var x = title_rect.x + title_rect.w - Float32(8.0)
    if node.pinned:
        x = _draw_badge(ctx, title_rect.copy(), x, String("PIN"), Color(65, 96, 126, 230))
    if node.collapsed:
        x = _draw_badge(ctx, title_rect.copy(), x, String("COL"), Color(78, 78, 86, 230))
    if node.bypassed:
        x = _draw_badge(ctx, title_rect.copy(), x, String("BYP"), Color(112, 72, 34, 230))
    if node.muted:
        _ = _draw_badge(ctx, title_rect.copy(), x, String("MUTE"), Color(116, 42, 48, 230))


def _draw_minimap(mut ctx: Context, viewport: Rect, state: CanvasState, graph: Graph):
    if not state.show_minimap:
        return
    var bounds_result = canvas_all_nodes_bounds(graph)
    if not bounds_result[0]:
        return
    var world = bounds_result[1].inflate(Float32(80.0), Float32(80.0))
    for gi in range(len(state.groups)):
        world = world.union(state.groups[gi].rect.copy())

    var mm = Rect(
        viewport.x + viewport.w - _MINIMAP_W - _MINIMAP_PAD,
        viewport.y + viewport.h - _MINIMAP_H - _MINIMAP_PAD,
        _MINIMAP_W,
        _MINIMAP_H,
    )
    var inner = mm.inflate(Float32(-8.0), Float32(-8.0))
    tess_rounded_rect(ctx, mm.copy(), Float32(7.0), Color(16, 18, 24, 220), 5)
    _draw_rect_border(ctx, mm.copy(), Color(120, 130, 150, 125), Float32(1.0))

    var sx = inner.w / world.w
    var sy = inner.h / world.h
    var scale = sx
    if sy < scale:
        scale = sy
    if scale <= Float32(0.0):
        return
    var off_x = inner.x + (inner.w - world.w * scale) * Float32(0.5) - world.x * scale
    var off_y = inner.y + (inner.h - world.h * scale) * Float32(0.5) - world.y * scale

    for gi in range(len(state.groups)):
        var gr = state.groups[gi].rect.copy()
        var mr = Rect(
            off_x + gr.x * scale,
            off_y + gr.y * scale,
            gr.w * scale,
            gr.h * scale,
        )
        ctx.draw_rect(mr.copy(), Color(86, 112, 170, 58))
    for ni in range(graph.node_count()):
        var nr = _node_world_rect(graph.nodes[ni].copy())
        var mr = Rect(
            off_x + nr.x * scale,
            off_y + nr.y * scale,
            nr.w * scale,
            nr.h * scale,
        )
        var col = Color(124, 128, 150, 210)
        if canvas_is_node_selected(state, graph.nodes[ni].id):
            col = Color(120, 185, 255, 240)
        ctx.draw_rect(mr.copy(), col)
    var view_world_min = canvas_screen_to_world(state, viewport.min())
    var view_world_max = canvas_screen_to_world(state, viewport.max())
    var vr_world = _rect_from_points(view_world_min.copy(), view_world_max.copy())
    var vr = Rect(
        off_x + vr_world.x * scale,
        off_y + vr_world.y * scale,
        vr_world.w * scale,
        vr_world.h * scale,
    )
    _draw_rect_border(ctx, vr.copy(), Color(230, 235, 255, 210), Float32(1.0))


def _begin_port_drag_if_pressed(
    mut ctx: Context, mut state: CanvasState, node: Node
) -> Bool:
    if not ctx.control.mouse_pressed_this_frame:
        return False
    var mouse = ctx.control.mouse_pos.copy()
    var n_inputs = len(node.inputs)
    for pi in range(n_inputs):
        var p = node.inputs[pi].copy()
        var pos = port_screen_pos(state, node, pi, True)
        if _point_hits_port(mouse.copy(), pos.copy()):
            _start_wire_drag(state, node.id, p.name.copy(), False, p.value_type)
            return True
    var n_outputs = len(node.outputs)
    for pi in range(n_outputs):
        var p = node.outputs[pi].copy()
        var pos = port_screen_pos(state, node, pi, False)
        if _point_hits_port(mouse.copy(), pos.copy()):
            _start_wire_drag(state, node.id, p.name.copy(), True, p.value_type)
            return True
    return False


def _finish_port_drag_if_released(
    mut ctx: Context, mut state: CanvasState, mut graph: Graph, node: Node
) -> Bool:
    if not ctx.control.mouse_released_this_frame:
        return False
    if not _wire_drag_active(state):
        return False
    var mouse = ctx.control.mouse_pos.copy()
    var n_inputs = len(node.inputs)
    for pi in range(n_inputs):
        var p = node.inputs[pi].copy()
        var pos = port_screen_pos(state, node, pi, True)
        if _point_hits_port(mouse.copy(), pos.copy()):
            return _try_commit_wire_drag(state, graph, node.id, p.name.copy(), False, p.value_type)
    var n_outputs = len(node.outputs)
    for pi in range(n_outputs):
        var p = node.outputs[pi].copy()
        var pos = port_screen_pos(state, node, pi, False)
        if _point_hits_port(mouse.copy(), pos.copy()):
            return _try_commit_wire_drag(state, graph, node.id, p.name.copy(), True, p.value_type)
    return False


def _draw_wire_drag_preview(mut ctx: Context, state: CanvasState, graph: Graph):
    if not _wire_drag_active(state):
        return
    var idx = graph.find_node(state.wire_drag_from_node)
    if idx < 0:
        return
    var node = graph.nodes[idx].copy()
    var from_port_idx: Int = -1
    if state.wire_drag_from_is_output:
        for pi in range(len(node.outputs)):
            if node.outputs[pi].name == state.wire_drag_from_port:
                from_port_idx = pi
                break
    else:
        for pi in range(len(node.inputs)):
            if node.inputs[pi].name == state.wire_drag_from_port:
                from_port_idx = pi
                break
    if from_port_idx < 0:
        return
    var from_pos = port_screen_pos(
        state, node, from_port_idx, not state.wire_drag_from_is_output
    )
    var mouse = ctx.control.mouse_pos.copy()
    var col = wire_color_for_type(state.wire_drag_from_type)
    if state.wire_drag_from_is_output:
        draw_wire_thick(ctx, from_pos.copy(), mouse.copy(), col^, _WIRE_HOVER_THICKNESS)
    else:
        draw_wire_thick(ctx, mouse.copy(), from_pos.copy(), col^, _WIRE_HOVER_THICKNESS)


def hovered_edge(
    state: CanvasState, graph: Graph, point: Vec2, threshold: Float32
) -> Int32:
    """Return the list index of the edge whose drawn bezier passes closest
    to `point` (screen space), provided that distance is within
    `threshold` px; otherwise -1.

    Resolves each edge's endpoints exactly as the wire-draw loop does
    (port-index-by-NAME, then `port_screen_pos`) so the clickable region
    matches the rendered curve. Edges referencing a missing node/port are
    skipped. Pure (non-raising) so tests can call it directly with a known
    on-curve point.
    """
    var best_idx: Int32 = -1
    var best_dist = threshold
    var ne = graph.edge_count()
    for ei in range(ne):
        var edge = graph.edges[ei].copy()
        var from_idx = graph.find_node(edge.from_node)
        var to_idx = graph.find_node(edge.to_node)
        if from_idx < 0 or to_idx < 0:
            continue
        var from_node = graph.nodes[from_idx].copy()
        var to_node = graph.nodes[to_idx].copy()

        var from_port_idx: Int = -1
        var nfo = len(from_node.outputs)
        for pi in range(nfo):
            if from_node.outputs[pi].name == edge.from_port:
                from_port_idx = pi
                break
        var to_port_idx: Int = -1
        var nti = len(to_node.inputs)
        for pi in range(nti):
            if to_node.inputs[pi].name == edge.to_port:
                to_port_idx = pi
                break
        if from_port_idx < 0 or to_port_idx < 0:
            continue

        var from_pos = port_screen_pos(state, from_node, from_port_idx, False)
        var to_pos = port_screen_pos(state, to_node, to_port_idx, True)
        var d = wire_distance_to_point(
            from_pos.copy(), to_pos.copy(), point.copy()
        )
        if d <= best_dist:
            best_dist = d
            best_idx = Int32(ei)
    return best_idx


def _ctrl_held(ctx: Context) -> Bool:
    return ctx.input.key_held(MOJOUI_KEY_LCTRL) or ctx.input.key_held(MOJOUI_KEY_RCTRL)


def _apply_marquee_selection(mut state: CanvasState, graph: Graph):
    var sr = _rect_from_points(state.marquee_start.copy(), state.marquee_end.copy())
    if sr.w < _MARQUEE_MIN_DIST and sr.h < _MARQUEE_MIN_DIST:
        return
    var w0 = canvas_screen_to_world(state, Vec2(sr.x, sr.y))
    var w1 = canvas_screen_to_world(state, Vec2(sr.right(), sr.bottom()))
    var wr = _rect_from_points(w0.copy(), w1.copy())
    canvas_clear_selection(state)
    for i in range(graph.node_count()):
        if wr.intersects(_node_world_rect(graph.nodes[i].copy())):
            canvas_add_node_to_selection(state, graph.nodes[i].id)


def _handle_canvas_shortcuts(
    mut ctx: Context,
    mut state: CanvasState,
    mut graph: Graph,
    viewport: Rect,
) raises -> Bool:
    var changed = False
    var ctrl = _ctrl_held(ctx)
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_A):
        _ = canvas_select_all(state, graph)
        changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_C):
        _ = canvas_copy_selection(state, graph)
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_V) and not state.locked:
        if canvas_paste_clipboard(
            state, graph, Vec2(_PASTE_OFFSET_WORLD, _PASTE_OFFSET_WORLD)
        ) > 0:
            changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_D) and not state.locked:
        if canvas_duplicate_selection(state, graph) > 0:
            changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_F):
        _ = canvas_fit_selection(state, graph, viewport.copy())
        changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_0):
        canvas_reset_view(state)
        changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_L):
        state.show_links = not state.show_links
        changed = True
    if ctrl and ctx.input.key_pressed(MOJOUI_KEY_G) and not state.locked:
        if canvas_group_selection(state, graph) >= Int64(0):
            changed = True
    if ctx.input.key_pressed(MOJOUI_KEY_R) and state.selected_edge >= Int32(0) and not state.locked:
        var pos = canvas_screen_to_world(state, ctx.control.mouse_pos.copy())
        if canvas_insert_reroute_on_edge(state, graph, Int(state.selected_edge), pos.copy()) != RET_ID_NONE:
            changed = True

    var nudge = Vec2.zero()
    if ctx.input.key_pressed(MOJOUI_KEY_LEFT):
        nudge.x = nudge.x - _NUDGE_SMALL_WORLD
    if ctx.input.key_pressed(MOJOUI_KEY_RIGHT):
        nudge.x = nudge.x + _NUDGE_SMALL_WORLD
    if ctx.input.key_pressed(MOJOUI_KEY_UP):
        nudge.y = nudge.y - _NUDGE_SMALL_WORLD
    if ctx.input.key_pressed(MOJOUI_KEY_DOWN):
        nudge.y = nudge.y + _NUDGE_SMALL_WORLD
    if nudge.x != Float32(0.0) or nudge.y != Float32(0.0):
        if ctx.control.shift_held:
            nudge = Vec2(
                nudge.x / _NUDGE_SMALL_WORLD * state.snap_grid,
                nudge.y / _NUDGE_SMALL_WORLD * state.snap_grid,
            )
        if not state.locked and canvas_nudge_selection(state, graph, nudge.copy()) > 0:
            changed = True
    return changed


# ============================================================================
# begin_node_canvas / end_node_canvas
# ============================================================================


def begin_node_canvas(
    mut ctx: Context,
    id_str: String,
    mut state: CanvasState,
    mut graph: Graph,
) raises -> Bool:
    """Render the canvas viewport. Returns True iff `state` or `graph`
    were mutated this frame (drag, selection, pan, wire-select/delete,
    right-click-to-open-context-menu).

    JUMP semantics: does NOT emit `CMD_JUMP`. Uses the layout flow's
    current slot and clips children with a single `CMD_CLIP`.
    Caller contract: title text only renders when `ctx.theme.font_id != 0`
    (FRAGILE #5).

    `raises`: the per-node body renderer (`draw_node_body`) reads the
    node's `fields` Dict (getitem raises in current beta). All existing
    callers are already in `raises` contexts.

    Companion overlays — call AFTER `end_node_canvas`:
      - `node_menu.node_context_menu` — handles the right-click menu this
        function opens via `state.ctx_menu_*`.
      - `progress.draw_progress_overlay` — per-node status badges.
    """
    # 1. id, outer slot, update_control. Pan/drag are driven off
    #    `ctx.input.mouse_held(...)` directly so the returned flags are
    #    only reserved for future hover feedback.
    var id = ctx.get_id(id_str)
    var rect = ctx.layout_next()
    var _viewport_flags = ctx.update_control(id, rect.copy(), OPT_NONE)
    var changed: Bool = False
    state.generate_requested = False
    state.add_image_requested = False
    state.import_json_requested = False

    # Push an id_stack scope so per-node ids derived below (`"node_<N>"`)
    # don't collide between two canvases on the same Context. Paired with
    # `ctx.pop_id()` in `end_node_canvas`. Matches the scroll_area /
    # window_panel convention from the M2 bugfix (regression notes
    # FRAGILE #3); re-applied here per M2.5 skeptic FRAGILE #1.
    ctx.push_id_str(id_str)

    # 2. Clip to viewport (one CMD_CLIP; restored by end_node_canvas).
    ctx.draw_clip(rect.copy())

    # 3. Canvas background + panned grid.
    _draw_canvas_grid(ctx, rect.copy(), state)
    _draw_group_regions(ctx, state)
    var action_bar_blocks_press = (
        ctx.control.mouse_pressed_this_frame
        and _canvas_action_bar_rect(rect.copy()).contains(ctx.control.mouse_pos.copy())
    )

    if rect.contains(ctx.control.mouse_pos.copy()):
        var wheel_y = ctx.input.scroll_delta.y
        if wheel_y != Float32(0.0):
            var factor = _ZOOM_STEP
            if wheel_y < Float32(0.0):
                factor = Float32(1.0) / _ZOOM_STEP
            if canvas_zoom_at(state, ctx.control.mouse_pos.copy(), factor):
                changed = True

    if state.editing_field_node == RET_ID_NONE and state.bbox_edit_node == RET_ID_NONE:
        if _handle_canvas_shortcuts(ctx, state, graph, rect.copy()):
            changed = True

    # A fresh left-press must re-arm drag ownership from the widget under
    # the cursor. This avoids stale retained drag ids moving nodes/groups
    # on the same frame as a new click.
    if ctx.control.mouse_pressed_this_frame:
        state.dragging_node = RET_ID_NONE
        state.resizing_node = RET_ID_NONE
        state.dragging_group = Int64(-1)

    var group_left_pressed = False
    if not action_bar_blocks_press:
        group_left_pressed = _begin_group_drag_if_pressed(ctx, state, graph)
    if group_left_pressed:
        changed = True

    if _update_group_drag(ctx, state, graph):
        changed = True

    if _update_bbox_drag(ctx, state, graph):
        changed = True

    # 4. Pan — middle-button hold drags the viewport (EriGui Interaction::Pan).
    if ctx.input.mouse_held(_BTN_MIDDLE):
        var pan_dx = ctx.input.mouse_delta.x
        var pan_dy = ctx.input.mouse_delta.y
        if pan_dx != Float32(0.0) or pan_dy != Float32(0.0):
            state.pan.x = state.pan.x + pan_dx
            state.pan.y = state.pan.y + pan_dy
            changed = True

    # 5. Walk every node — draw body + title + border + port dots and
    #    handle press for select-and-start-drag. Iterate by integer
    #    index (no direct `for n in graph.nodes` in current beta).
    # `node_left_pressed` records whether a node claimed the left-press
    # this frame; the wire-select pass below uses it to avoid stealing a
    # click that landed on a node.
    var node_left_pressed: Bool = group_left_pressed or action_bar_blocks_press
    var drag_started_this_frame: Bool = False
    var link_finished: Bool = False
    var nn = graph.node_count()
    for i in range(nn):
        var node = graph.nodes[i].copy()
        var node_pos_world = node.position.copy()
        var screen_pos = canvas_world_to_screen(state, node_pos_world.copy())
        var visual_h = node.size.y
        if node.collapsed:
            visual_h = _TITLE_BAR_H + Float32(8.0)
        var screen_size = Vec2(
            node.size.x * state.zoom, visual_h * state.zoom
        )
        var node_rect = Rect(
            screen_pos.x, screen_pos.y, screen_size.x, screen_size.y
        )

        # Per-node ID derived from the RetainedId.
        var node_id_str = String("node_") + String(node.id)
        var node_id = ctx.get_id(node_id_str)
        var node_flags = ctx.update_control(
            node_id, node_rect.copy(), OPT_NONE
        )

        var port_left_pressed = False
        if not state.locked and not action_bar_blocks_press:
            port_left_pressed = _begin_port_drag_if_pressed(ctx, state, node)
        if port_left_pressed:
            node_left_pressed = True
            state.dragging_node = RET_ID_NONE
            changed = True

        var resize_left_pressed = False
        var resize_handle = _node_resize_handle_rect(node_rect.copy())
        if (
            ctx.control.mouse_pressed_this_frame
            and not port_left_pressed
            and not group_left_pressed
            and not action_bar_blocks_press
            and not node.collapsed
            and not state.locked
            and resize_handle.contains(ctx.control.mouse_pos.copy())
        ):
            if not canvas_is_node_selected(state, node.id):
                canvas_set_single_selection(state, node.id)
            else:
                state.selected_node = node.id
                state.selected_edge = Int32(-1)
            state.resizing_node = node.id
            state.resize_start_mouse_world = canvas_screen_to_world(state, ctx.control.mouse_pos.copy())
            state.resize_start_size = node.size.copy()
            state.dragging_node = RET_ID_NONE
            node_left_pressed = True
            resize_left_pressed = True
            changed = True

        var bbox_left_pressed = False
        if (
            not port_left_pressed
            and not group_left_pressed
            and not action_bar_blocks_press
            and not resize_left_pressed
            and not node.collapsed
            and not state.locked
        ):
            bbox_left_pressed = _begin_bbox_drag_if_pressed(ctx, state, graph, node, node_rect.copy())
        if bbox_left_pressed:
            if not canvas_is_node_selected(state, node.id):
                canvas_set_single_selection(state, node.id)
            else:
                state.selected_node = node.id
                state.selected_edge = Int32(-1)
            state.dragging_node = RET_ID_NONE
            node_left_pressed = True
            changed = True

        var field_left_pressed = False
        if (
            ctx.control.mouse_pressed_this_frame
            and not port_left_pressed
            and not group_left_pressed
            and not action_bar_blocks_press
            and not bbox_left_pressed
            and not resize_left_pressed
            and not node.collapsed
            and not state.locked
        ):
            var field_key = _field_key_at_point(
                node,
                node_rect.copy(),
                _TITLE_BAR_H * state.zoom,
                ctx.control.mouse_pos.copy(),
            )
            if field_key.byte_length() > 0:
                _begin_field_edit(
                    state,
                    node.id,
                    field_key.copy(),
                    node.fields[field_key].copy(),
                )
                if not canvas_is_node_selected(state, node.id):
                    canvas_set_single_selection(state, node.id)
                else:
                    state.selected_node = node.id
                    state.selected_edge = Int32(-1)
                state.dragging_node = RET_ID_NONE
                node_left_pressed = True
                field_left_pressed = True
                changed = True

        if (not state.locked) and (not link_finished) and _finish_port_drag_if_released(
            ctx, state, graph, node
        ):
            link_finished = True
            changed = True

        # Drag start on press — claim selection + drag, remember the
        # click offset within the node so cursor stays glued to it.
        if (node_flags & CTRL_PRESSED) != 0 and not port_left_pressed and not group_left_pressed and not action_bar_blocks_press and not field_left_pressed and not bbox_left_pressed and not resize_left_pressed:
            if ctx.control.shift_held:
                canvas_toggle_node_selection(state, node.id)
            elif not canvas_is_node_selected(state, node.id):
                canvas_set_single_selection(state, node.id)
            else:
                state.selected_node = node.id
                state.selected_edge = Int32(-1)
            if not state.locked and not node.pinned:
                state.dragging_node = node.id
                state.drag_last_world = node.position.copy()
                drag_started_this_frame = True
            else:
                state.dragging_node = RET_ID_NONE
            node_left_pressed = True
            state.drag_offset = Vec2(
                ctx.control.mouse_pos.x - screen_pos.x,
                ctx.control.mouse_pos.y - screen_pos.y,
            )
            changed = True

        # Right-click over a node body → open the per-node context menu.
        # `mouse_pressed` is a pure struct read (no FFI; the FFI lives in
        # input.poll upstream), so this is safe under `mojo run` tests.
        # Last matching node in iteration order wins (= topmost).
        if ctx.input.mouse_pressed(MOJOUI_BTN_RIGHT) and node_rect.contains(
            ctx.control.mouse_pos.copy()
        ):
            if not canvas_is_node_selected(state, node.id):
                canvas_set_single_selection(state, node.id)
            else:
                state.selected_node = node.id
            state.ctx_menu_open = True
            state.ctx_menu_node = node.id
            state.ctx_menu_anchor = ctx.control.mouse_pos.copy()
            changed = True

        # Body fill — brighter shade when selected.
        var is_selected = canvas_is_node_selected(state, node.id)
        var body_color = _node_body_color(node, is_selected)

        # Title bar — height scales with zoom.
        var title_rect = Rect(
            node_rect.x,
            node_rect.y,
            node_rect.w,
            _TITLE_BAR_H * state.zoom,
        )
        var title_color = _node_title_color(node)
        var border_color: Color
        if is_selected:
            border_color = ctx.theme.primary.copy()
        else:
            border_color = ctx.theme.border_strong.copy()
        _draw_node_shell(
            ctx,
            node_rect.copy(),
            title_rect.copy(),
            body_color^,
            title_color^,
            border_color.copy(),
            is_selected,
            state.zoom,
        )

        # Title text (FRAGILE #5 — only when font loaded).
        if ctx.theme.font_id != 0:
            var title_font = ctx.theme.font_size_pt + 4
            var title_y = title_rect.y + (title_rect.h + Float32(title_font) * Float32(0.60)) * Float32(0.5)
            var socket_glyph = _node_socket_glyph_color(node)
            tess_circle(
                ctx,
                Vec2(title_rect.x + Float32(16.0), title_rect.y + title_rect.h * Float32(0.5)),
                Float32(5.2),
                socket_glyph,
                16,
            )
            var title_pos = Vec2(
                title_rect.x + Float32(32.0),
                title_y,
            )
            var title_label = _truncate_for_width(
                node.title.copy(),
                title_rect.w - Float32(104.0),
                title_font,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                title_font,
                title_pos^,
                ctx.theme.text.copy(),
                title_label,
            )
            var badge = String("#") + String(node.id)
            var badge_font = ctx.theme.font_size_pt + 2
            var badge_w = _text_w_est(badge, badge_font)
            ctx.draw_text(
                ctx.theme.font_id,
                badge_font,
                Vec2(title_rect.x + title_rect.w - badge_w - Float32(10.0), title_y),
                Color(196, 220, 206, 230),
                badge,
            )
            _draw_node_status_badges(ctx, node, title_rect.copy())

        # Body — per-node field rows (the draw_body hook seam). Default
        # renderer lists `name: value` for each field below the title bar.
        # No-op when font_id == 0 (headless).
        if not node.collapsed:
            draw_node_body(ctx, node, node_rect.copy(), _TITLE_BAR_H * state.zoom)
            _draw_bbox_editor(ctx, state, node, node_rect.copy())
            if _draw_bbox_edit_overlay(ctx, state, graph, node, node_rect.copy()):
                changed = True
            if is_selected or (node_flags & CTRL_HOVERED) != 0:
                _draw_node_resize_handle(
                    ctx,
                    resize_handle.copy(),
                    state.resizing_node == node.id,
                )

        # Port dots — circular sockets with dark rings + typed fill.
        var n_inputs = len(node.inputs)
        for pi in range(n_inputs):
            var p = node.inputs[pi].copy()
            var pos = port_screen_pos(state, node, pi, True)
            var port_color = wire_color_for_type(p.value_type)
            var active_port = (
                _wire_drag_active(state)
                and state.wire_drag_from_node == node.id
                and state.wire_drag_from_port == p.name
                and not state.wire_drag_from_is_output
            )
            _draw_port(ctx, pos^, port_color^, active_port)
            if not node.collapsed:
                _draw_port_label(ctx, pos.copy(), p.name.copy(), True)
        var n_outputs = len(node.outputs)
        for pi in range(n_outputs):
            var p = node.outputs[pi].copy()
            var pos = port_screen_pos(state, node, pi, False)
            var port_color = wire_color_for_type(p.value_type)
            var active_port = (
                _wire_drag_active(state)
                and state.wire_drag_from_node == node.id
                and state.wire_drag_from_port == p.name
                and state.wire_drag_from_is_output
            )
            _draw_port(ctx, pos^, port_color^, active_port)
            if not node.collapsed:
                _draw_port_label(ctx, pos.copy(), p.name.copy(), False)

        if _draw_field_edit_overlay(ctx, state, graph, node, node_rect.copy()):
            changed = True

    if state.resizing_node != RET_ID_NONE:
        var ridx = graph.find_node(state.resizing_node)
        if ridx >= 0 and ctx.input.mouse_held(_BTN_LEFT):
            var now_world = canvas_screen_to_world(state, ctx.control.mouse_pos.copy())
            var next_w = state.resize_start_size.x + (now_world.x - state.resize_start_mouse_world.x)
            var next_h = state.resize_start_size.y + (now_world.y - state.resize_start_mouse_world.y)
            if state.snap_to_grid or ctx.control.shift_held:
                next_w = canvas_snap_world(Vec2(next_w, Float32(0.0)), state.snap_grid).x
                next_h = canvas_snap_world(Vec2(Float32(0.0), next_h), state.snap_grid).y
            if next_w < _NODE_MIN_W:
                next_w = _NODE_MIN_W
            if next_h < _NODE_MIN_H:
                next_h = _NODE_MIN_H
            if graph.nodes[ridx].size.x != next_w or graph.nodes[ridx].size.y != next_h:
                graph.nodes[ridx].size = Vec2(next_w, next_h)
                changed = True
        if ctx.input.mouse_released(_BTN_LEFT) or ctx.control.mouse_released_this_frame:
            state.resizing_node = RET_ID_NONE

    # 6. NodeDrag in progress — inverse-transform cursor through active
    #    pan/zoom to get the new world position; drag_offset is in
    #    screen space (same units as the cursor).
    if state.dragging_node != RET_ID_NONE and state.resizing_node == RET_ID_NONE:
        var idx = graph.find_node(state.dragging_node)
        if (
            idx >= 0
            and not drag_started_this_frame
            and not ctx.control.mouse_pressed_this_frame
            and ctx.input.mouse_held(_BTN_LEFT)
        ):
            if state.zoom != Float32(0.0):
                var new_world_x = (
                    ctx.control.mouse_pos.x
                    - state.drag_offset.x
                    - state.pan.x
                ) / state.zoom
                var new_world_y = (
                    ctx.control.mouse_pos.y
                    - state.drag_offset.y
                    - state.pan.y
                ) / state.zoom
                var new_world = Vec2(new_world_x, new_world_y)
                if state.snap_to_grid or ctx.control.shift_held:
                    new_world = canvas_snap_world(new_world.copy(), state.snap_grid)
                var old_world = graph.nodes[idx].position.copy()
                var delta = Vec2(new_world.x - old_world.x, new_world.y - old_world.y)
                if delta.x != Float32(0.0) or delta.y != Float32(0.0):
                    _ensure_primary_in_selection(state)
                    for ni in range(graph.node_count()):
                        if canvas_is_node_selected(state, graph.nodes[ni].id) and not graph.nodes[ni].pinned:
                            graph.nodes[ni].position = Vec2(
                                graph.nodes[ni].position.x + delta.x,
                                graph.nodes[ni].position.y + delta.y,
                            )
                    state.drag_last_world = new_world.copy()
                    changed = True
        # Drag ends on LEFT-button release. We check `mouse_released`
        # (rising-edge to up) rather than `not mouse_held` because the
        # press frame itself has pressed=True/held=True but the test
        # fixture (`begin_frame_no_input`) does not auto-sync `held`
        # off `pressed` — checking the release edge keeps both the
        # production path (poll() syncs held) and the test path
        # consistent.
        if ctx.input.mouse_released(_BTN_LEFT) or ctx.control.mouse_released_this_frame:
            state.dragging_node = RET_ID_NONE

    if ctx.input.mouse_released(_BTN_LEFT) or ctx.control.mouse_released_this_frame:
        state.dragging_group = Int64(-1)

    if _wire_drag_active(state):
        if ctx.control.mouse_released_this_frame:
            _clear_wire_drag(state)
            changed = True

    # 7. Wire hover hit-test (before drawing so the hovered/selected wire
    #    can be stroked thicker this same frame). Nearest edge within
    #    `_WIRE_HIT_DIST` px of the cursor, or -1.
    if state.show_links:
        state.hovered_edge = hovered_edge(
            state, graph, ctx.control.mouse_pos.copy(), _WIRE_HIT_DIST
        )
    else:
        state.hovered_edge = Int32(-1)

    # 8. Wires — drawn AFTER nodes so they paint on top of node bodies.
    if state.show_links:
        var ne = graph.edge_count()
        for ei in range(ne):
            var edge = graph.edges[ei].copy()
            var from_idx = graph.find_node(edge.from_node)
            var to_idx = graph.find_node(edge.to_node)
            if from_idx < 0 or to_idx < 0:
                continue
            var from_node = graph.nodes[from_idx].copy()
            var to_node = graph.nodes[to_idx].copy()

            # Resolve port indices by NAME (EriGui invariant).
            var from_port_idx: Int = -1
            var nfo = len(from_node.outputs)
            for pi in range(nfo):
                if from_node.outputs[pi].name == edge.from_port:
                    from_port_idx = pi
                    break
            var to_port_idx: Int = -1
            var nti = len(to_node.inputs)
            for pi in range(nti):
                if to_node.inputs[pi].name == edge.to_port:
                    to_port_idx = pi
                    break
            if from_port_idx < 0 or to_port_idx < 0:
                continue

            var from_pos = port_screen_pos(
                state, from_node, from_port_idx, False
            )
            var to_pos = port_screen_pos(state, to_node, to_port_idx, True)
            var wcolor = wire_color_for_type(
                from_node.outputs[from_port_idx].value_type
            )
            # Selected wire = thickest + theme-primary so it reads as armed
            # for delete; hovered = medium; idle = default thickness.
            if Int32(ei) == state.selected_edge:
                draw_wire_thick(
                    ctx,
                    from_pos.copy(),
                    to_pos.copy(),
                    ctx.theme.primary.copy(),
                    _WIRE_SELECT_THICKNESS,
                )
            elif Int32(ei) == state.hovered_edge:
                draw_wire_thick(
                    ctx,
                    from_pos.copy(),
                    to_pos.copy(),
                    wcolor^,
                    _WIRE_HOVER_THICKNESS,
                )
            else:
                draw_wire(ctx, from_pos.copy(), to_pos.copy(), wcolor^)

        _draw_wire_drag_preview(ctx, state, graph)

    # 9. Wire select + delete.
    #    - Left-press on a hovered wire (and NOT on a node) selects it and
    #      clears any node selection.
    #    - Left-press on empty space (no node, no wire) clears wire-select.
    #    - Delete key removes the selected wire.
    if ctx.control.mouse_pressed_this_frame and not node_left_pressed:
        if state.hovered_edge >= Int32(0):
            state.selected_edge = state.hovered_edge
            state.selected_node = RET_ID_NONE
            state.selected_nodes = List[RetainedId]()
            changed = True
        else:
            state.marquee_active = True
            state.marquee_start = ctx.control.mouse_pos.copy()
            state.marquee_end = ctx.control.mouse_pos.copy()
            canvas_clear_selection(state)
            changed = True

    if state.marquee_active:
        state.marquee_end = ctx.control.mouse_pos.copy()
        if ctx.control.mouse_released_this_frame:
            _apply_marquee_selection(state, graph)
            state.marquee_active = False
            changed = True

    if (
        ctx.input.key_pressed(MOJOUI_KEY_DELETE)
        and not state.locked
        and state.bbox_edit_node == RET_ID_NONE
    ):
        if _delete_selected_bbox(state, graph):
            changed = True
        elif canvas_delete_selection(state, graph) > 0:
            changed = True

    _draw_marquee(ctx, state)
    _draw_minimap(ctx, rect.copy(), state, graph)
    if _draw_canvas_action_bar(ctx, state, rect.copy()):
        changed = True

    return changed


def end_node_canvas(mut ctx: Context):
    """End the matching `begin_node_canvas`: pop the id_stack scope pushed
    by `begin_node_canvas` and restore the clip rect to the full window.
    M2.5 does NOT push an inner layout frame so no `layout.pop()` is needed.
    """
    # Pop the id_stack scope pushed by begin_node_canvas (M2.5 skeptic
    # FRAGILE #1 — matches scroll_area / window_panel convention).
    ctx.pop_id()
    ctx.draw_clip(ctx.window_rect.copy())
