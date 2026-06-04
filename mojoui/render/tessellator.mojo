"""Anti-aliased primitive tessellation — rounded rects, drop shadows, circles.

M3 chunk 46 introduced these primitives; **M3 c46-fix Bug 2 (2026-05-28)**
re-routes the emit-side API through `ctx.commands.emit_triangles` so widget
geometry flows through the command buffer + walker like every other draw
primitive (RECT/TEXT/CLIP/JUMP). This fixes a regression where tessellated
geometry was cleared before the demo walker could draw it.

Extends the existing `mojoui/render/backend.mojo` flat-rect tessellator
(`_tessellate_rect`) with three new primitives that emit variable-vertex-
count geometry too large to fit in the `CMD_RECT` command buffer: rounded
rectangles, concentric-rect drop shadows, and filled circles.

These functions now emit `CMD_TRIANGLES` records via `ctx.commands.emit_
triangles(verts, indices, texture_id)` (M3 c46-fix). The walker in the demo
(see `examples/m3_interactive_demo.mojo::_render_command_buffer`) reads
back `CmdTriangles` and dispatches to `Backend.draw_batch_lists`. The pre-
fix design called Backend directly from the tessellator, bypassing the
walker entirely and so getting the geometry cleared by `Backend.frame_begin`
between widget evaluation and the walker's draw calls.

Design notes for the M3 tessellator:

  - Rounded rect = 4 corner fans (N triangles each) + 1 center rect (2 tris)
    + 4 edge rects (2 tris each) = 4N + 10 triangles total.
  - Concentric-rect drop shadow approximation: N stacked offset rounded rects
    with decreasing alpha. Cheap, looks OK at small blur radii. Real Gaussian
    blur deferred to M3.5+ (needs an offscreen pass + a separable kernel).
  - Filled circle = triangle fan from the centre to N perimeter samples.

Internal builder helpers (`_build_rounded_rect_verts` / `_build_circle_verts`)
are split out so smoke tests can verify vertex/index correctness directly.
After the M3 c46-fix re-routing, the emit-side `tess_*` functions are pure
Mojo (no FFI in their bodies) — the JIT guard pattern is no longer needed
in tests that call them. The demo's walker is the FFI surface; gating it
remains the c53 pattern.

What this chunk deliberately does NOT do (deferred to later M3 / M3.5):

  - Fringe-based AA. Current beta lacks subpixel coverage math; the smooth
    corner fan already looks acceptable on integer-pixel rasters.
  - Proper Gaussian-blur shadows. Concentric-rect approximation is the M3
    stub; M3.5+ adds a real two-pass separable Gaussian + offscreen RT.
  - Polyline / stroked-rect / mitred-join APIs. Sticks to filled-area
    primitives for c46; stroked variants land alongside the renderer
    adapter once cap/join math is in place.
  - Multi-batch dispatch. Each `tess_*` call emits exactly ONE
    `CMD_TRIANGLES` record (no cross-primitive batching).
"""

from std.math import sin, cos

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.render.backend import (
    _pack_color_aabbggrr,
    _u32_to_f32_bits,
)


# ---------------------------------------------------------------------------
# Compile-time defaults
# ---------------------------------------------------------------------------

# Default corner-fan resolution. 4 segments per 90 degrees gives 16 perimeter
# samples per rounded rect — visually smooth for typical UI radii (4-12 px)
# without blowing up the vertex count.
comptime DEFAULT_CORNER_SEGS: Int = 4

# Default filled-circle perimeter resolution. 24 segments matches the wires
# chunk (c38 WIRE_SEGMENTS) — smooth at typical port-dot radii (~5 px).
comptime DEFAULT_CIRCLE_SEGS: Int = 24

# Float32 PI literal — std.math.pi may or may not be in current beta's
# importable surface; using a local literal avoids the probe.
comptime _PI_F32: Float32 = 3.14159265358979323846

# Drop-shadow layer cap — keeps a runaway blur from spamming the GPU.
comptime _SHADOW_MAX_LAYERS: Int = 16


# ---------------------------------------------------------------------------
# Vertex / index builders (pure, JIT-test friendly)
# ---------------------------------------------------------------------------


def _push_vert(
    mut verts: List[Float32], x: Float32, y: Float32, color_bits: Float32
):
    """Append one (x, y, u=0, v=0, color_bits) vertex to the flat List."""
    verts.append(x)
    verts.append(y)
    verts.append(Float32(0.0))
    verts.append(Float32(0.0))
    verts.append(color_bits)


def _push_tri(
    mut indices: List[UInt16], a: UInt16, b: UInt16, c: UInt16
):
    """Append one triangle as three indices to the flat List."""
    indices.append(a)
    indices.append(b)
    indices.append(c)


def _build_rounded_rect_verts(
    rect: Rect,
    radius: Float32,
    color: Color,
    segments_per_corner: Int,
) -> Tuple[List[Float32], List[UInt16]]:
    """Build the vertex + index Lists for a rounded rectangle.

    Layout (corner indices in source order — TL, TR, BR, BL):

        ┌─────────────────────────┐
        │ TL  (top edge)       TR │
        │   ╲                 ╱   │
        │    ┌───────────────┐    │
        │    │               │    │
        │ (L)│   centre      │(R) │
        │    │               │    │
        │    └───────────────┘    │
        │   ╱                 ╲   │
        │ BL  (bot edge)       BR │
        └─────────────────────────┘

    The inner rect (centre) is bounded by `(x+r, y+r) .. (x+w-r, y+h-r)`.
    Each corner is a triangle fan from the inner-corner point through
    `n_segs + 1` perimeter samples. Edges are 2-triangle strips between
    adjacent corner endpoints.

    Total triangles: 4 corners * n_segs + 1 centre (2 tris) + 4 edges
    (2 tris each) = 4 * n_segs + 10. Total vertices: 4 corner centres
    + 4 * (n_segs + 1) corner perimeter points = 8 + 4 * n_segs.

    Pure: no FFI, no Backend call — safe to call under JIT. The smoke
    tests exercise this helper directly.
    """
    # Degenerate-dimension guard: zero or negative width/height has no
    # visible output. Return empty lists rather than producing inverted
    # geometry. Without this guard a negative w/h would drive the
    # `half_min` clamp below into producing a negative radius, which the
    # downstream cos/sin math would place outside the rect bounds.
    if rect.w <= Float32(0.0) or rect.h <= Float32(0.0):
        var empty_v = List[Float32]()
        var empty_i = List[UInt16]()
        return (empty_v^, empty_i^)
    var r = radius
    if r < Float32(0.0):
        r = Float32(0.0)
    # Clamp radius to half the smaller dimension so corners don't overlap.
    var half_min = rect.w
    if rect.h < half_min:
        half_min = rect.h
    half_min = half_min * Float32(0.5)
    if r > half_min:
        r = half_min

    var n_segs = segments_per_corner
    if n_segs < 1:
        n_segs = 1

    var packed = _pack_color_aabbggrr(color)
    var color_bits = _u32_to_f32_bits(packed)

    var verts = List[Float32]()
    var indices = List[UInt16]()

    # Inner-rect corner positions (after radius inset).
    var inner_x0 = rect.x + r
    var inner_y0 = rect.y + r
    var inner_x1 = rect.x + rect.w - r
    var inner_y1 = rect.y + rect.h - r

    # ----- Vertex emission -------------------------------------------------
    # Per-corner block layout in `verts`:
    #     vertex offset = corner_idx * (n_segs + 2)
    #     slot 0           = corner inner-centre
    #     slots 1..n_segs+1 = perimeter samples (start_angle .. end_angle)
    # Corner order: TL (0), TR (1), BR (2), BL (3).

    # Helper closure-ish: angle sweeps per corner.
    # TL: starts pointing UP (-y), sweeps clockwise to LEFT (-x).
    # TR: starts pointing RIGHT (+x), sweeps clockwise to UP (-y).
    # BR: starts pointing DOWN (+y), sweeps clockwise to RIGHT (+x).
    # BL: starts pointing LEFT (-x), sweeps clockwise to DOWN (+y).
    # In screen space Y grows DOWN, so the corner direction signs match
    # the standard quadrant conventions for a centre-up coordinate system
    # if we flip the sin sign; using sin(-theta) below handles this.

    # Generate corners.
    var corners_cx = InlineArray[Float32, 4](fill=Float32(0.0))
    var corners_cy = InlineArray[Float32, 4](fill=Float32(0.0))
    corners_cx[0] = inner_x0  # TL
    corners_cy[0] = inner_y0
    corners_cx[1] = inner_x1  # TR
    corners_cy[1] = inner_y0
    corners_cx[2] = inner_x1  # BR
    corners_cy[2] = inner_y1
    corners_cx[3] = inner_x0  # BL
    corners_cy[3] = inner_y1

    # Starting angle for each corner's perimeter sweep (radians).
    # Angle measured from +x axis, with Y growing DOWN. The corner
    # perimeter starts at the outer-edge tangent and sweeps 90 degrees
    # clockwise (when viewed with +y down).
    # TL: starts at angle pi (left tangent), sweeps to 1.5*pi (top tangent).
    # TR: starts at 1.5*pi (top tangent), sweeps to 2*pi (right tangent).
    # BR: starts at 0 (right tangent), sweeps to 0.5*pi (bottom tangent).
    # BL: starts at 0.5*pi (bottom tangent), sweeps to pi (left tangent).
    var start_angles = InlineArray[Float32, 4](fill=Float32(0.0))
    start_angles[0] = _PI_F32                # TL
    start_angles[1] = Float32(1.5) * _PI_F32  # TR
    start_angles[2] = Float32(0.0)           # BR
    start_angles[3] = Float32(0.5) * _PI_F32  # BL

    var sweep = Float32(0.5) * _PI_F32

    # Push corner vertices (centre + n_segs+1 perimeter samples).
    for c_idx in range(4):
        var cx = corners_cx[c_idx]
        var cy = corners_cy[c_idx]
        # Centre vertex first.
        _push_vert(verts, cx, cy, color_bits)
        # Perimeter samples.
        var ang0 = start_angles[c_idx]
        for s in range(n_segs + 1):
            var t = Float32(s) / Float32(n_segs)
            var theta = ang0 + sweep * t
            var px = cx + r * cos(theta)
            var py = cy + r * sin(theta)
            _push_vert(verts, px, py, color_bits)

    # ----- Index emission --------------------------------------------------
    # Per corner: n_segs triangles, each (centre, p_i, p_{i+1}).
    var per_corner = UInt16(n_segs + 2)
    for c_idx in range(4):
        var base = UInt16(c_idx) * per_corner
        var centre = base
        for s in range(n_segs):
            var pi = base + UInt16(1 + s)
            var pj = base + UInt16(2 + s)
            _push_tri(indices, centre, pi, pj)

    # ----- Inner rect (centre) — 2 triangles -------------------------------
    # Push 4 vertices for the inner rect (CCW in screen space, Y down).
    var inner_base = UInt16(len(verts) // 5)
    _push_vert(verts, inner_x0, inner_y0, color_bits)  # TL
    _push_vert(verts, inner_x1, inner_y0, color_bits)  # TR
    _push_vert(verts, inner_x1, inner_y1, color_bits)  # BR
    _push_vert(verts, inner_x0, inner_y1, color_bits)  # BL
    _push_tri(indices, inner_base + UInt16(0), inner_base + UInt16(1), inner_base + UInt16(2))
    _push_tri(indices, inner_base + UInt16(0), inner_base + UInt16(2), inner_base + UInt16(3))

    # ----- Edge strips — 4 rects, 2 tris each ------------------------------
    # Each edge is the rectangle between two adjacent corners' outer tangents.
    # We pick existing perimeter endpoints as the seam so the strip joins
    # the corner fan cleanly without an extra vertex.
    #
    # Top edge: between TL last perimeter point and TR first perimeter point.
    #   TL last  = idx 0*per_corner + (n_segs+1)
    #   TR first = idx 1*per_corner + 1
    #   inner TL = inner_base + 0
    #   inner TR = inner_base + 1
    # Right edge: between TR last and BR first.
    # Bottom edge: between BR last and BL first.
    # Left edge: between BL last and TL first.
    # (Indices computed below; geometry is the natural axis-aligned strip.)

    # We'll add fresh edge-strip vertices to make the math simple and
    # avoid coupling to corner-fan endpoint coordinates (which depend on
    # cos/sin precision). The cost is 4 * 4 = 16 extra vertices total
    # — a fixed overhead independent of n_segs.

    # Top edge strip: (inner_x0, rect.y) .. (inner_x1, inner_y0).
    var top_base = UInt16(len(verts) // 5)
    _push_vert(verts, inner_x0, rect.y, color_bits)       # TL
    _push_vert(verts, inner_x1, rect.y, color_bits)       # TR
    _push_vert(verts, inner_x1, inner_y0, color_bits)     # BR
    _push_vert(verts, inner_x0, inner_y0, color_bits)     # BL
    _push_tri(indices, top_base + UInt16(0), top_base + UInt16(1), top_base + UInt16(2))
    _push_tri(indices, top_base + UInt16(0), top_base + UInt16(2), top_base + UInt16(3))

    # Right edge strip: (inner_x1, inner_y0) .. (rect.x + rect.w, inner_y1).
    var right_base = UInt16(len(verts) // 5)
    var x_right = rect.x + rect.w
    _push_vert(verts, inner_x1, inner_y0, color_bits)     # TL
    _push_vert(verts, x_right, inner_y0, color_bits)      # TR
    _push_vert(verts, x_right, inner_y1, color_bits)      # BR
    _push_vert(verts, inner_x1, inner_y1, color_bits)     # BL
    _push_tri(indices, right_base + UInt16(0), right_base + UInt16(1), right_base + UInt16(2))
    _push_tri(indices, right_base + UInt16(0), right_base + UInt16(2), right_base + UInt16(3))

    # Bottom edge strip: (inner_x0, inner_y1) .. (inner_x1, rect.y + rect.h).
    var bot_base = UInt16(len(verts) // 5)
    var y_bot = rect.y + rect.h
    _push_vert(verts, inner_x0, inner_y1, color_bits)     # TL
    _push_vert(verts, inner_x1, inner_y1, color_bits)     # TR
    _push_vert(verts, inner_x1, y_bot, color_bits)        # BR
    _push_vert(verts, inner_x0, y_bot, color_bits)        # BL
    _push_tri(indices, bot_base + UInt16(0), bot_base + UInt16(1), bot_base + UInt16(2))
    _push_tri(indices, bot_base + UInt16(0), bot_base + UInt16(2), bot_base + UInt16(3))

    # Left edge strip: (rect.x, inner_y0) .. (inner_x0, inner_y1).
    var left_base = UInt16(len(verts) // 5)
    _push_vert(verts, rect.x, inner_y0, color_bits)       # TL
    _push_vert(verts, inner_x0, inner_y0, color_bits)     # TR
    _push_vert(verts, inner_x0, inner_y1, color_bits)     # BR
    _push_vert(verts, rect.x, inner_y1, color_bits)       # BL
    _push_tri(indices, left_base + UInt16(0), left_base + UInt16(1), left_base + UInt16(2))
    _push_tri(indices, left_base + UInt16(0), left_base + UInt16(2), left_base + UInt16(3))

    return (verts^, indices^)


def _build_circle_verts(
    center: Vec2, radius: Float32, color: Color, segments: Int
) -> Tuple[List[Float32], List[UInt16]]:
    """Build the vertex + index Lists for a filled circle.

    Layout: centre vertex at index 0, then `segments` perimeter samples
    at indices 1..segments. Triangles form a fan: (0, i, i+1) for each
    perimeter pair with wrap-around (last triangle is (0, segments, 1)).

    Total vertices: 1 + segments. Total triangles: segments.
    Total indices: 3 * segments.

    Pure: no FFI, JIT-safe.
    """
    var n = segments
    if n < 3:
        n = 3

    var packed = _pack_color_aabbggrr(color)
    var color_bits = _u32_to_f32_bits(packed)

    var verts = List[Float32]()
    var indices = List[UInt16]()

    # Centre vertex (idx 0).
    _push_vert(verts, center.x, center.y, color_bits)

    # Perimeter samples (idx 1..n).
    for i in range(n):
        var theta = Float32(2.0) * _PI_F32 * Float32(i) / Float32(n)
        var x = center.x + radius * cos(theta)
        var y = center.y + radius * sin(theta)
        _push_vert(verts, x, y, color_bits)

    # Triangles: (0, i, i+1) for i in 1..n, with the last triangle wrapping
    # back to vertex 1.
    for i in range(n):
        var idx_a = UInt16(1 + i)
        var idx_b = UInt16(1 + i + 1)
        if i == n - 1:
            idx_b = UInt16(1)
        _push_tri(indices, UInt16(0), idx_a, idx_b)

    return (verts^, indices^)


# ---------------------------------------------------------------------------
# Public emit-side API (calls Backend.draw_batch_lists; FFI-touching)
# ---------------------------------------------------------------------------


def tess_rounded_rect(
    mut ctx: Context,
    rect: Rect,
    radius: Float32,
    color: Color,
    segments_per_corner: Int = DEFAULT_CORNER_SEGS,
):
    """Tessellate an anti-aliased rounded rectangle into a `CMD_TRIANGLES`
    record on `ctx.commands`. The demo walker dispatches CMD_TRIANGLES to
    `Backend.draw_batch_lists` at frame end (M3 c46-fix Bug 2).

    Pre-fix design (c46): called `Backend.draw_batch_lists` directly,
    bypassing the command buffer and getting cleared by `Backend.frame_
    begin` between widget evaluation and the demo walker.

    Emits ONE CMD_TRIANGLES record per call (the tessellation produces
    4*N + 10 triangles — too large to encode in a CMD_RECT, which can
    only carry one axis-aligned (Rect, Color) pair). Texture id 0 binds
    the built-in 1x1 white texture for solid color geometry.

    `segments_per_corner` defaults to `DEFAULT_CORNER_SEGS` (4). A radius
    of 0 collapses to a flat rectangle (corner fans degenerate to a
    single point each); for that case prefer `ctx.draw_rect` which uses
    a 4-vert / 6-idx CMD_RECT.
    """
    var built = _build_rounded_rect_verts(rect, radius, color, segments_per_corner)
    var verts = built[0].copy()
    var indices = built[1].copy()
    _ = ctx.commands.emit_triangles(verts^, indices^, UInt32(0))


def tess_circle(
    mut ctx: Context,
    center: Vec2,
    radius: Float32,
    color: Color,
    segments: Int = DEFAULT_CIRCLE_SEGS,
):
    """Tessellate a filled circle as a triangle fan into a `CMD_TRIANGLES`
    record on `ctx.commands`. The demo walker dispatches the record to
    `Backend.draw_batch_lists` at frame end (M3 c46-fix Bug 2).

    `segments` defaults to `DEFAULT_CIRCLE_SEGS` (24). At typical
    port-dot radii (~5 px) this is visually smooth. Below 3 segments
    the helper clamps up to 3 (a triangle).
    """
    var built = _build_circle_verts(center, radius, color, segments)
    var verts = built[0].copy()
    var indices = built[1].copy()
    _ = ctx.commands.emit_triangles(verts^, indices^, UInt32(0))


def tess_drop_shadow(
    mut ctx: Context,
    rect: Rect,
    radius: Float32,
    blur: Float32,
    offset_x: Float32,
    offset_y: Float32,
    color: Color,
):
    """Approximate a drop shadow as N concentric rounded rects offset by
    `(offset_x, offset_y)` with decreasing alpha. Emits N CMD_TRIANGLES
    records on `ctx.commands` (M3 c46-fix Bug 2).

    Cheap and visually adequate at small blur radii (1..8 px). Real
    Gaussian-blur shadows are deferred to M3.5+ — they require an
    offscreen render target plus a separable two-pass filter, neither
    of which the M3 tessellator targets.

    `blur` controls the number of layers (capped at `_SHADOW_MAX_LAYERS`
    so a runaway value cannot spam the GPU). Each layer is offset
    outward by `i` pixels from the shifted (offset_x, offset_y) anchor
    and tinted with alpha `color.a * (1 - i/N)`. With offset (0, 0)
    this degenerates to a symmetric outward glow; typical CSS-style
    drop shadows use (0, 2) for a subtle below-element shadow.

    Each layer emits ONE CMD_TRIANGLES record (so a 4-layer shadow
    contributes 4 records). M3.5+ optimisation: merge layers into a
    single index/vertex stream.
    """
    var n_layers: Int = Int(blur)
    if n_layers < 1:
        n_layers = 1
    if n_layers > _SHADOW_MAX_LAYERS:
        n_layers = _SHADOW_MAX_LAYERS

    for i in range(n_layers):
        var t = Float32(i + 1) / Float32(n_layers + 1)
        var inset_neg: Float32 = Float32(i) * Float32(1.0)
        var alpha_frac = Float32(1.0) - t
        var a_scaled = Float32(Int(color.a)) * alpha_frac
        var shadow_a: UInt8 = UInt8(Int(a_scaled))
        var shadow_color = Color(color.r, color.g, color.b, shadow_a)
        var shadow_rect = Rect(
            rect.x + offset_x - inset_neg,
            rect.y + offset_y - inset_neg,
            rect.w + Float32(2.0) * inset_neg,
            rect.h + Float32(2.0) * inset_neg,
        )
        tess_rounded_rect(
            ctx, shadow_rect, radius + inset_neg, shadow_color, DEFAULT_CORNER_SEGS
        )


def tess_outer_glow(
    mut ctx: Context,
    rect: Rect,
    radius: Float32,
    blur: Float32,
    color: Color,
):
    """Symmetric outward glow — `tess_drop_shadow` with zero offset.

    Backward-compat wrapper for callers / tests that pre-dated the
    `offset_x`/`offset_y` parameters being added to `tess_drop_shadow`.
    """
    tess_drop_shadow(ctx, rect, radius, blur, Float32(0.0), Float32(0.0), color)
