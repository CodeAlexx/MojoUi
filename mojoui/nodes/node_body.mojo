"""Default per-node body renderer — the `draw_body` hook seam.

EriGui's `NodeType` trait exposes a `draw_body` method so each node type
renders its own parameter widgets inside the node rect
(`erigui-widgets/src/node_graph/mod.rs`). MojoUI keeps `NodeTypeDef` as
pure data (`architecture plan` Decision 1), so there is no per-type vtable
to dispatch on. Instead the canvas calls this ONE default body renderer
for every node: it lists the node's `fields` as `name: value` text rows
below the title bar.

This function IS the hook seam. A future app-supplied custom body (a
callback registered per `type_id`) slots in by replacing the
`draw_node_body(...)` call in `canvas.begin_node_canvas` with a dispatch
that falls back to this default when no custom renderer is registered.
Keeping the default here means every node already shows its parameters
(the actual Klein-demo need — seeing a sampler's steps/cfg/seed at a
glance) without any per-type code.

Determinism: field keys render in SORTED order, matching the sorted-key
serde convention (`serde/workflow.mojo`) so the body looks identical
frame-to-frame regardless of `Dict` iteration order.

`raises`: reads `node.fields[key]` (Dict `__getitem__` raises in current
beta — see `serde/workflow.mojo:142`). Callers (`begin_node_canvas`) are
already raising. The font_id == 0 guard short-circuits all `draw_text`
under headless tests (FRAGILE #5).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.nodes.node import (
    Node,
    FieldValue,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
)


comptime _BODY_LINE_H: Float32 = 16.0
"""Vertical pitch between field rows (screen px at zoom == 1)."""

comptime _BODY_PAD_X: Float32 = 6.0
"""Left inset of field text from the node's left edge."""

comptime _BODY_PAD_Y: Float32 = 4.0
"""Padding below the title bar before the first field row, and above the
node's bottom edge where rows stop."""


def _sorted_field_keys(node: Node) -> List[String]:
    """Field keys in ascending byte order. Insertion sort — key counts
    are tiny (<50 per node) so O(n^2) is irrelevant. Materializes keys
    into a List first (the c37 Dict-aliasing wall: can't index a Dict by
    a key still borrowing from `.keys()`)."""
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


def _field_value_str(fv: FieldValue) -> String:
    """Render a FieldValue as a bare display string (no JSON quoting —
    this is a UI label, not serialization)."""
    if fv.kind == FK_NUMBER:
        return String(fv.num_val)
    elif fv.kind == FK_STRING:
        return fv.str_val.copy()
    elif fv.kind == FK_BOOL:
        if fv.bool_val:
            return String("true")
        return String("false")
    elif fv.kind == FK_INT:
        return String(fv.int_val)
    return String("null")


def draw_node_body(
    mut ctx: Context,
    node: Node,
    node_rect: Rect,
    title_h_screen: Float32,
) raises:
    """Render every field of `node` as a `name: value` text row inside the
    node body, below the title bar.

    Args:
        ctx:            Per-frame Context (reads `theme.font_id` /
                        `font_size_pt` / `text`).
        node:           The node whose fields to render.
        node_rect:      The node's SCREEN-space rect (already pan/zoom
                        transformed by the canvas).
        title_h_screen: Screen-space title-bar height (so rows start just
                        below it).

    Rows past the node's bottom edge are not drawn (cheap overflow guard;
    the canvas's viewport CMD_CLIP also clips anything that escapes). No-op
    when `font_id == 0` (headless tests / font not yet loaded).
    """
    if ctx.theme.font_id == 0:
        return
    var keys = _sorted_field_keys(node)
    var n = len(keys)
    var x = node_rect.x + _BODY_PAD_X
    var y0 = node_rect.y + title_h_screen + _BODY_PAD_Y + _BODY_LINE_H
    var max_y = node_rect.y + node_rect.h - _BODY_PAD_Y
    for i in range(n):
        var ly = y0 + Float32(i) * _BODY_LINE_H
        if ly > max_y:
            break
        var key = keys[i].copy()
        var fv = node.fields[key].copy()
        var line = key + String(": ") + _field_value_str(fv)
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            Vec2(x, ly),
            ctx.theme.text.copy(),
            line,
        )
