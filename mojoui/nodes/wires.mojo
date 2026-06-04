"""Cubic-bezier wire rendering for the M2.5 node graph (chunk 38).

The NodeCanvas widget (c39) calls `draw_wire(ctx, from_pos, to_pos, color)`
for each visible edge. Wire shape mirrors EriGui's `draw_bezier`
(`erigui-widgets/src/node_graph/mod.rs:980-1022`): cubic bezier with
horizontal tangents at the endpoints, control points offset by
`dx * 0.35`, 24 segments. The same conventions appear in
`egui_node_graph` and ComfyUI, so a saved workflow's wires render
identically wherever they are opened.

M2.5 simplification (deliberate, documented for M3):

- Each segment is drawn as one axis-aligned bounding rect rather than a
  proper stroked line. Thin near-horizontal segments look like horizontal
  strips; thin near-vertical segments look like vertical strips; diagonal
  segments get a small box. The 24-segment tessellation visually masks
  the stub for the smooth EriGui-style S-curves. M3's tessellator swaps
  in real rotated-quad strokes with mitred joins and round caps.
- No arrowhead at the `to` end (M3 adds; EriGui's arrowhead is a small
  triangle that the M3 tessellator's line-cap pipeline will subsume).
- No alpha animation, no per-port glow, no port-type label/tooltip — all
  M3 / theme work.

Coupling: this module knows NOTHING about `Edge`, `Graph`, or `Port`.
It takes TWO `Vec2` endpoints + a `Color`. The canvas widget composes
the endpoints by looking up port positions on the rendered nodes.

Per-type colors live in `wire_color_for_type`. M3 sources these from
the theme system; for M2.5 the palette is hardcoded matching ComfyUI's
common conventions (latent=magenta, image=green, conditioning=yellow,
model=blue, vae=red, ...).
"""

from std.math import sqrt
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context


# 24 segments per EriGui `draw_bezier` (mod.rs:980-1022); enough to mask
# the bounding-rect stub for typical wire lengths.
comptime WIRE_SEGMENTS: Int = 24

# Default stroke thickness in pixels. M3 reads from theme.
comptime WIRE_THICKNESS: Float32 = 2.0

# Control-point offset fraction along dx (EriGui's hardcoded 0.35).
# 0.0 = straight line; 1.0 = control points reach the opposite endpoint.
# 0.35 gives the gentle S-curve characteristic of node-editor wires.
comptime WIRE_TANGENT_FRAC: Float32 = 0.35


# ---------------------------------------------------------------------------
# Bezier math
# ---------------------------------------------------------------------------


def cubic_bezier_point(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, t: Float32) -> Vec2:
    """Evaluate a cubic bezier curve at parameter `t` in [0, 1].

    Standard cubic bezier formula:
        B(t) = (1-t)^3 * P0
             + 3 * (1-t)^2 * t * P1
             + 3 * (1-t)   * t^2 * P2
             + t^3          * P3

    Endpoints: B(0) == P0, B(1) == P3 (verified by smoke tests).
    """
    var u = Float32(1.0) - t
    var uu = u * u
    var uuu = uu * u
    var tt = t * t
    var ttt = tt * t
    var x = (
        uuu * p0.x
        + Float32(3.0) * uu * t * p1.x
        + Float32(3.0) * u * tt * p2.x
        + ttt * p3.x
    )
    var y = (
        uuu * p0.y
        + Float32(3.0) * uu * t * p1.y
        + Float32(3.0) * u * tt * p2.y
        + ttt * p3.y
    )
    return Vec2(x, y)


# ---------------------------------------------------------------------------
# Wire drawing
# ---------------------------------------------------------------------------


def draw_wire(
    mut ctx: Context, from_pos: Vec2, to_pos: Vec2, color: Color
):
    """Draw a cubic-bezier wire from `from_pos` (output port) to
    `to_pos` (input port) using `WIRE_THICKNESS` and the EriGui-style
    horizontal-tangent control-point layout.

    Emits exactly `WIRE_SEGMENTS` (24) `CMD_RECT` commands — one per
    segment of the polyline tessellation. The canvas widget calls
    `draw_wire` once per edge; the renderer adapter walks the resulting
    `CMD_RECT` records as normal axis-aligned rects.
    """
    var dx = to_pos.x - from_pos.x
    # Horizontal-tangent control points: P1 sits dx*frac right of P0,
    # P2 sits dx*frac left of P3. When dx < 0 (wire flows right-to-left,
    # e.g. a node placed to the left of its consumer) the offset flips
    # sign too, which keeps the curve smooth — EriGui's behaviour.
    var ctrl_dx = dx * WIRE_TANGENT_FRAC
    var p0 = from_pos.copy()
    var p1 = Vec2(from_pos.x + ctrl_dx, from_pos.y)
    var p2 = Vec2(to_pos.x - ctrl_dx, to_pos.y)
    var p3 = to_pos.copy()

    var prev = p0.copy()
    for i in range(1, WIRE_SEGMENTS + 1):
        var t = Float32(i) / Float32(WIRE_SEGMENTS)
        var cur = cubic_bezier_point(
            p0.copy(), p1.copy(), p2.copy(), p3.copy(), t
        )
        _draw_thick_line_segment(
            ctx, prev.copy(), cur.copy(), color.copy(), WIRE_THICKNESS
        )
        prev = cur.copy()


def draw_wire_thick(
    mut ctx: Context,
    from_pos: Vec2,
    to_pos: Vec2,
    color: Color,
    thickness: Float32,
):
    """Same as `draw_wire` but with caller-specified `thickness`. Used by
    the canvas hover/selection states (slightly thicker stroke on
    pointer-over). M3 will route through the theme rather than expose
    thickness as a parameter.
    """
    var dx = to_pos.x - from_pos.x
    var ctrl_dx = dx * WIRE_TANGENT_FRAC
    var p0 = from_pos.copy()
    var p1 = Vec2(from_pos.x + ctrl_dx, from_pos.y)
    var p2 = Vec2(to_pos.x - ctrl_dx, to_pos.y)
    var p3 = to_pos.copy()

    var prev = p0.copy()
    for i in range(1, WIRE_SEGMENTS + 1):
        var t = Float32(i) / Float32(WIRE_SEGMENTS)
        var cur = cubic_bezier_point(
            p0.copy(), p1.copy(), p2.copy(), p3.copy(), t
        )
        _draw_thick_line_segment(
            ctx, prev.copy(), cur.copy(), color.copy(), thickness
        )
        prev = cur.copy()


def _draw_thick_line_segment(
    mut ctx: Context, a: Vec2, b: Vec2, color: Color, thickness: Float32
):
    """Draw one polyline segment as an axis-aligned bounding rect with
    `thickness`-pixel padding along the smaller axis.

    M2.5 stub: cheap, visually adequate at 24 segments for the smooth
    EriGui-style S-curves the bezier produces. Diagonal segments paint
    a small box (looks like a fat dot in isolation but the segment chain
    masks it). M3's tessellator replaces with proper rotated-quad
    strokes + mitred joins + round caps.
    """
    # Bounding rect of (a, b) — sorted x and y.
    var x0 = a.x
    var x1 = b.x
    if x0 > x1:
        var tmp = x0
        x0 = x1
        x1 = tmp
    var y0 = a.y
    var y1 = b.y
    if y0 > y1:
        var tmp = y0
        y0 = y1
        y1 = tmp

    # Inflate by thickness/2 on the smaller axis so the rect always has
    # visible width AND height. A purely horizontal segment (dy == 0)
    # would otherwise be 0-height; the pad gives it `thickness` height.
    var dx_seg = x1 - x0
    var dy_seg = y1 - y0
    if dx_seg < thickness:
        var pad = (thickness - dx_seg) * Float32(0.5)
        x0 = x0 - pad
        x1 = x1 + pad
    if dy_seg < thickness:
        var pad = (thickness - dy_seg) * Float32(0.5)
        y0 = y0 - pad
        y1 = y1 + pad

    var rect = Rect(x0, y0, x1 - x0, y1 - y0)
    ctx.draw_rect(rect^, color.copy())


# ---------------------------------------------------------------------------
# Wire hit-testing (for hover highlight + click-to-select-then-delete)
# ---------------------------------------------------------------------------


def _point_segment_distance(p: Vec2, a: Vec2, b: Vec2) -> Float32:
    """Shortest distance from point `p` to the line segment `a`-`b`.

    Projects `p` onto the segment, clamping the projection parameter to
    [0, 1] so the result is the distance to the nearest point ON the
    segment (not the infinite line). Degenerate `a == b` returns the
    point-to-point distance.
    """
    var abx = b.x - a.x
    var aby = b.y - a.y
    var len_sq = abx * abx + aby * aby
    if len_sq <= Float32(1.0e-12):
        var dx0 = p.x - a.x
        var dy0 = p.y - a.y
        return sqrt(dx0 * dx0 + dy0 * dy0)
    var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len_sq
    if t < Float32(0.0):
        t = Float32(0.0)
    elif t > Float32(1.0):
        t = Float32(1.0)
    var projx = a.x + t * abx
    var projy = a.y + t * aby
    var dx = p.x - projx
    var dy = p.y - projy
    return sqrt(dx * dx + dy * dy)


def wire_distance_to_point(from_pos: Vec2, to_pos: Vec2, p: Vec2) -> Float32:
    """Minimum distance from point `p` to the wire that `draw_wire` would
    render between `from_pos` and `to_pos`.

    Tessellates the SAME cubic bezier (identical control-point layout:
    horizontal tangents at `dx * WIRE_TANGENT_FRAC`, `WIRE_SEGMENTS`
    segments) and returns the smallest point-to-segment distance across
    the polyline. The canvas uses this for hover/click hit-testing so the
    clickable region matches the drawn curve exactly.
    """
    var dx = to_pos.x - from_pos.x
    var ctrl_dx = dx * WIRE_TANGENT_FRAC
    var p0 = from_pos.copy()
    var p1 = Vec2(from_pos.x + ctrl_dx, from_pos.y)
    var p2 = Vec2(to_pos.x - ctrl_dx, to_pos.y)
    var p3 = to_pos.copy()

    var best = Float32(1.0e30)
    var prev = p0.copy()
    for i in range(1, WIRE_SEGMENTS + 1):
        var t = Float32(i) / Float32(WIRE_SEGMENTS)
        var cur = cubic_bezier_point(
            p0.copy(), p1.copy(), p2.copy(), p3.copy(), t
        )
        var d = _point_segment_distance(p.copy(), prev.copy(), cur.copy())
        if d < best:
            best = d
        prev = cur.copy()
    return best


# ---------------------------------------------------------------------------
# Per-type wire colors (stub palette; M3 routes through theme)
# ---------------------------------------------------------------------------


def wire_color_for_type(value_type_tag: Int32) -> Color:
    """Return a per-`NodeValueType` wire color matching the common
    ComfyUI palette. Tags align with `mojoui/nodes/port.mojo`'s
    `NVT_*` constants (0..10). Unknown tags fall back to the EriGui
    default amber `#F59E0B`.

    M3 sources these from a theme dict so palette tweaks land in one
    place; we hardcode here for M2.5 so the canvas widget can ship
    without a theme-system dependency.
    """
    if value_type_tag == Int32(0):       # NVT_LATENT
        return Color(UInt8(200), UInt8(100), UInt8(200), UInt8(255))
    elif value_type_tag == Int32(1):     # NVT_IMAGE
        return Color(UInt8(100), UInt8(200), UInt8(100), UInt8(255))
    elif value_type_tag == Int32(2):     # NVT_CONDITIONING
        return Color(UInt8(200), UInt8(200), UInt8(100), UInt8(255))
    elif value_type_tag == Int32(3):     # NVT_MODEL
        return Color(UInt8(100), UInt8(100), UInt8(200), UInt8(255))
    elif value_type_tag == Int32(4):     # NVT_VAE
        return Color(UInt8(200), UInt8(100), UInt8(100), UInt8(255))
    elif value_type_tag == Int32(5):     # NVT_CLIP
        return Color(UInt8(100), UInt8(200), UInt8(200), UInt8(255))
    elif value_type_tag == Int32(6):     # NVT_LORA
        return Color(UInt8(200), UInt8(150), UInt8(100), UInt8(255))
    elif value_type_tag == Int32(7):     # NVT_NUMBER
        return Color(UInt8(180), UInt8(180), UInt8(180), UInt8(255))
    elif value_type_tag == Int32(8):     # NVT_TEXT
        return Color(UInt8(220), UInt8(220), UInt8(180), UInt8(255))
    elif value_type_tag == Int32(9):     # NVT_SEED
        return Color(UInt8(150), UInt8(150), UInt8(100), UInt8(255))
    elif value_type_tag == Int32(10):    # NVT_BOOL
        return Color(UInt8(150), UInt8(100), UInt8(150), UInt8(255))
    # Default: EriGui's hardcoded amber #F59E0B.
    return Color(UInt8(245), UInt8(158), UInt8(11), UInt8(255))
