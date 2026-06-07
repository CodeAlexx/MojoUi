"""Cubic-bezier wire rendering for the M2.5 node graph (chunk 38).

The NodeCanvas widget (c39) calls `draw_wire(ctx, from_pos, to_pos, color)`
for each visible edge. Wire shape mirrors EriGui's `draw_bezier`
(`erigui-widgets/src/node_graph/mod.rs:980-1022`): cubic bezier with
horizontal tangents at the endpoints, control points offset by
  `dx * 0.35`, 36 segments. The same conventions appear in
`egui_node_graph` and ComfyUI, so a saved workflow's wires render
identically wherever they are opened.

Current stroke path:

- Each segment is drawn as a rotated quad batched into one CMD_TRIANGLES
  command, with slight overlap at joins and round end caps.
- A low-alpha glow layer is drawn under the core stroke so selected and
  typed wires read clearly on the dark canvas without square stair-steps.
- No arrowhead at the `to` end (M3 adds; EriGui's arrowhead is a small
  triangle that the M3 tessellator's line-cap pipeline will subsume).
- No alpha animation, no per-port tooltip — all
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
from mojoui.render.backend import _pack_color_aabbggrr, _u32_to_f32_bits
from mojoui.render.tessellator import tess_circle


# More samples than the original EriGui smoke path because MojoUI now uses
# proper stroked geometry and large high-DPI canvases make jagged curves obvious.
comptime WIRE_SEGMENTS: Int = 36

# Default stroke thickness in pixels. M3 reads from theme.
comptime WIRE_THICKNESS: Float32 = 3.0

comptime WIRE_GLOW_EXTRA: Float32 = 7.0
"""Extra width for the translucent underlay."""

comptime WIRE_JOIN_OVERLAP: Float32 = 1.25
"""Pixels to extend each segment along its tangent so adjacent quads overlap."""

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

    Emits stroked triangle geometry rather than axis-aligned segment
    boxes. The canvas widget calls `draw_wire` once per edge; the renderer
    adapter walks the resulting `CMD_TRIANGLES` records like the rest of
    the tessellated UI primitives.
    """
    _draw_wire_stroked(
        ctx,
        from_pos.copy(),
        to_pos.copy(),
        color.copy(),
        WIRE_THICKNESS,
        True,
    )


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
    _draw_wire_stroked(
        ctx,
        from_pos.copy(),
        to_pos.copy(),
        color.copy(),
        thickness,
        True,
    )


def _push_wire_vert(
    mut verts: List[Float32], x: Float32, y: Float32, color_bits: Float32
):
    verts.append(x)
    verts.append(y)
    verts.append(Float32(0.0))
    verts.append(Float32(0.0))
    verts.append(color_bits)


def _push_wire_quad_indices(mut indices: List[UInt16], base: UInt16):
    indices.append(base)
    indices.append(base + UInt16(1))
    indices.append(base + UInt16(2))
    indices.append(base)
    indices.append(base + UInt16(2))
    indices.append(base + UInt16(3))


def _emit_stroked_segment_batch(
    mut ctx: Context,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    color: Color,
    thickness: Float32,
):
    """Batch the bezier polyline into rotated segment quads.

    The slight tangent overlap hides cracks between adjacent quads without
    needing a full miter-join pipeline.
    """
    if thickness <= Float32(0.0):
        return
    var packed = _pack_color_aabbggrr(color)
    var color_bits = _u32_to_f32_bits(packed)
    var verts = List[Float32]()
    var indices = List[UInt16]()
    var half = thickness * Float32(0.5)
    var prev = p0.copy()
    var emitted = 0
    for i in range(1, WIRE_SEGMENTS + 1):
        var t = Float32(i) / Float32(WIRE_SEGMENTS)
        var cur = cubic_bezier_point(
            p0.copy(), p1.copy(), p2.copy(), p3.copy(), t
        )
        var dx = cur.x - prev.x
        var dy = cur.y - prev.y
        var len_seg = sqrt(dx * dx + dy * dy)
        if len_seg > Float32(1.0e-4):
            var ux = dx / len_seg
            var uy = dy / len_seg
            var nx = -uy * half
            var ny = ux * half
            var ox = ux * WIRE_JOIN_OVERLAP
            var oy = uy * WIRE_JOIN_OVERLAP
            var ax = prev.x - ox
            var ay = prev.y - oy
            var bx = cur.x + ox
            var by = cur.y + oy
            _push_wire_vert(verts, ax + nx, ay + ny, color_bits)
            _push_wire_vert(verts, bx + nx, by + ny, color_bits)
            _push_wire_vert(verts, bx - nx, by - ny, color_bits)
            _push_wire_vert(verts, ax - nx, ay - ny, color_bits)
            _push_wire_quad_indices(indices, UInt16(emitted * 4))
            emitted = emitted + 1
        prev = cur.copy()
    if emitted > 0:
        _ = ctx.commands.emit_triangles(verts^, indices^, UInt32(0))


def _draw_wire_stroked(
    mut ctx: Context,
    from_pos: Vec2,
    to_pos: Vec2,
    color: Color,
    thickness: Float32,
    glow: Bool,
):
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

    if glow:
        var glow_color = color.with_alpha(UInt8(44))
        _emit_stroked_segment_batch(
            ctx,
            p0.copy(),
            p1.copy(),
            p2.copy(),
            p3.copy(),
            glow_color^,
            thickness + WIRE_GLOW_EXTRA,
        )
    _emit_stroked_segment_batch(
        ctx,
        p0.copy(),
        p1.copy(),
        p2.copy(),
        p3.copy(),
        color.copy(),
        thickness,
    )
    var cap_r = thickness * Float32(0.5)
    tess_circle(ctx, from_pos.copy(), cap_r, color.copy(), 12)
    tess_circle(ctx, to_pos.copy(), cap_r, color.copy(), 12)


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
    `NVT_*` constants (0..12). Unknown tags fall back to the EriGui
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
    elif value_type_tag == Int32(11):    # NVT_VIDEO
        return Color(UInt8(90), UInt8(170), UInt8(240), UInt8(255))
    elif value_type_tag == Int32(12):    # NVT_BBOX
        return Color(UInt8(255), UInt8(120), UInt8(210), UInt8(255))
    # Default: EriGui's hardcoded amber #F59E0B.
    return Color(UInt8(245), UInt8(158), UInt8(11), UInt8(255))
