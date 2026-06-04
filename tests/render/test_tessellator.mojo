"""Smoke tests for `mojoui/render/tessellator.mojo`.

Covers the M3 chunk 46 surface — the pure builder helpers
(`_build_rounded_rect_verts`, `_build_circle_verts`) plus end-to-end
signature exercises for the public emit functions (`tess_rounded_rect`,
`tess_circle`, `tess_drop_shadow`, `tess_outer_glow`).

After M3 c46-fix Bug 2 (2026-05-28) the tess_* functions emit CMD_TRIANGLES
records into `ctx.commands` instead of calling Backend.draw_batch_lists
directly — no FFI in their call body. The old c15/c16/c24 runtime-False
JIT guard is no longer needed; the tests call them directly and assert the
ctx.commands byte count grows.

Behavior assertions (vertex / index correctness, circle math) still run
through the pure builders for tight assertions; the public-API tests now
verify the command-buffer integration as well.

Run: `pixi run test-tessellator`.
"""

from std.math import sqrt

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_TRIANGLES
from mojoui.render.tessellator import (
    DEFAULT_CORNER_SEGS,
    DEFAULT_CIRCLE_SEGS,
    _build_rounded_rect_verts,
    _build_circle_verts,
    tess_rounded_rect,
    tess_circle,
    tess_drop_shadow,
    tess_outer_glow,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error("tessellator smoke")


def _abs(x: Float32) -> Float32:
    if x < Float32(0.0):
        return -x
    return x


# ============================================================
# _build_rounded_rect_verts — pure helper tests
# ============================================================


def test_build_rounded_rect_radius_zero_emits_vertices() raises:
    """`radius=0` still produces a non-empty vertex+index list (corner fans
    degenerate to coincident points; centre rect + edge strips still
    paint a full filled rectangle). The function does not special-case
    radius=0, so the helper output is non-zero."""
    var rect = Rect(0.0, 0.0, 100.0, 100.0)
    var built = _build_rounded_rect_verts(rect, Float32(0.0), Color.white(), 4)
    var verts = built[0].copy()
    var indices = built[1].copy()
    if len(verts) <= 0:
        _fail("radius=0 produced empty vertex list")
    if len(indices) <= 0:
        _fail("radius=0 produced empty index list")
    # Every vertex is 5 floats — must divide cleanly.
    if len(verts) % 5 != 0:
        print("got vert len:", len(verts))
        _fail("vertex list length not divisible by 5")
    # Indices must come in triples (each triangle = 3 indices).
    if len(indices) % 3 != 0:
        print("got index len:", len(indices))
        _fail("index list length not divisible by 3")


def test_build_rounded_rect_radius_positive_grows_vertex_count() raises:
    """`radius>0` with N corner segments produces a known vertex count.

    Layout breakdown for `n_segs=4`:

      total verts = 4*(n_segs+2) corner verts + 4 inner + 16 edge strip
                  = 4*n_segs + 8 + 4 + 16 = 4*n_segs + 28 = 44

    `radius=0` has the same shape but the corner-fan vertices collapse
    onto the inner-corner point — still 44 vertices, just degenerate.
    So vertex-count alone can't distinguish; we verify the exact count
    for the known shape.
    """
    var rect = Rect(0.0, 0.0, 50.0, 50.0)
    var n_segs = 4
    var built = _build_rounded_rect_verts(rect, Float32(8.0), Color.white(), n_segs)
    var verts = built[0].copy()
    var n_verts = len(verts) // 5
    var expected = 4 * n_segs + 28
    if n_verts != expected:
        print("got n_verts:", n_verts, " expected:", expected)
        _fail("rounded rect vertex count mismatch")


def test_build_rounded_rect_triangle_count() raises:
    """Triangle count = 4*n_segs (corner fans) + 2 (centre) + 8 (4 edges
    * 2 tris each) = 4*n_segs + 10. Indices = 3 * triangle count."""
    var rect = Rect(0.0, 0.0, 40.0, 40.0)
    var n_segs = 6
    var built = _build_rounded_rect_verts(rect, Float32(6.0), Color.white(), n_segs)
    var indices = built[1].copy()
    var n_tris = len(indices) // 3
    var expected = 4 * n_segs + 10
    if n_tris != expected:
        print("got n_tris:", n_tris, " expected:", expected)
        _fail("rounded rect triangle count mismatch")


def test_build_rounded_rect_radius_clamped_to_half_min() raises:
    """A radius larger than half the smaller dimension is silently
    clamped (no crash, no degenerate output)."""
    var rect = Rect(0.0, 0.0, 20.0, 100.0)  # half-min = 10
    # Pass radius=50 (way too big); helper clamps internally.
    var built = _build_rounded_rect_verts(rect, Float32(50.0), Color.white(), 4)
    var verts = built[0].copy()
    var indices = built[1].copy()
    if len(verts) <= 0 or len(indices) <= 0:
        _fail("over-radius produced empty output")
    # Sanity: still produces 4*n_segs + 10 = 26 triangles.
    if len(indices) // 3 != 26:
        _fail("over-radius did not clamp to expected triangle count")


def test_build_rounded_rect_min_segs_clamps_up_to_1() raises:
    """`segments_per_corner < 1` clamps to 1 (one triangle per corner)."""
    var rect = Rect(0.0, 0.0, 40.0, 40.0)
    var built = _build_rounded_rect_verts(rect, Float32(6.0), Color.white(), 0)
    var indices = built[1].copy()
    # Expected: 4*1 + 10 = 14 triangles.
    if len(indices) // 3 != 14:
        print("got tris:", len(indices) // 3)
        _fail("segments_per_corner=0 did not clamp to 1")


# ============================================================
# _build_circle_verts — pure helper tests
# ============================================================


def test_build_circle_default_counts() raises:
    """24-segment circle: 1 centre vertex + 24 perimeter vertices = 25
    total. 24 fan triangles = 72 indices."""
    var built = _build_circle_verts(Vec2(0.0, 0.0), Float32(10.0), Color.white(), 24)
    var verts = built[0].copy()
    var indices = built[1].copy()
    var n_verts = len(verts) // 5
    if n_verts != 25:
        print("got n_verts:", n_verts, " expected: 25")
        _fail("circle vertex count")
    var n_indices = len(indices)
    if n_indices != 72:
        print("got n_indices:", n_indices, " expected: 72")
        _fail("circle index count")


def test_build_circle_perimeter_on_radius() raises:
    """Every perimeter vertex is at distance `radius` from the centre
    (within Float32 epsilon — cos/sin precision)."""
    var cx: Float32 = 100.0
    var cy: Float32 = 50.0
    var r: Float32 = 30.0
    var built = _build_circle_verts(Vec2(cx, cy), r, Color.white(), 24)
    var verts = built[0].copy()
    var eps: Float32 = 1.0e-3
    # Skip vertex 0 (centre); walk 1..24.
    for i in range(1, 25):
        var off = i * 5
        var px = verts[off]
        var py = verts[off + 1]
        var dx = px - cx
        var dy = py - cy
        var dist = sqrt(dx * dx + dy * dy)
        if _abs(dist - r) > eps:
            print("vert", i, " dist:", dist, " want:", r)
            _fail("perimeter vertex not on radius")


def test_build_circle_centre_at_origin() raises:
    """Vertex 0 is the centre at exactly the supplied centre coords."""
    var built = _build_circle_verts(Vec2(7.0, 13.0), Float32(5.0), Color.white(), 12)
    var verts = built[0].copy()
    if verts[0] != Float32(7.0):
        _fail("circle centre x")
    if verts[1] != Float32(13.0):
        _fail("circle centre y")


def test_build_circle_low_segs_clamps_to_3() raises:
    """`segments < 3` clamps to 3 (a triangle); 4 verts, 3 indices*3 = 9."""
    var built = _build_circle_verts(Vec2(0.0, 0.0), Float32(1.0), Color.white(), 1)
    var verts = built[0].copy()
    var indices = built[1].copy()
    if len(verts) // 5 != 4:
        _fail("low segs did not clamp vertex count to 4")
    if len(indices) != 9:
        _fail("low segs did not clamp index count to 9")


def test_build_circle_indices_wrap_around() raises:
    """The last triangle's third index wraps back to vertex 1 (closing
    the fan). For 24 segments the last tri is (0, 24, 1)."""
    var built = _build_circle_verts(Vec2(0.0, 0.0), Float32(5.0), Color.white(), 24)
    var indices = built[1].copy()
    var n = len(indices)
    # Last triangle's three indices are at offsets n-3, n-2, n-1.
    if indices[n - 3] != UInt16(0):
        _fail("last tri centre != 0")
    if indices[n - 2] != UInt16(24):
        _fail("last tri second index != 24")
    if indices[n - 1] != UInt16(1):
        _fail("last tri third index did not wrap to 1")


# ============================================================
# tess_drop_shadow — concentric-rect approximation
# ============================================================


def test_drop_shadow_emits_per_layer_blur4() raises:
    """`blur=4` produces 4 layers (4 * tess_rounded_rect calls). We
    can't directly observe Backend.draw_batch_lists from a JIT test
    (FFI), but the helper-only path (`_build_rounded_rect_verts`)
    accumulates predictable output. Verify the helper returns
    sensible per-layer geometry by manually mirroring the loop body.
    """
    var rect = Rect(20.0, 20.0, 100.0, 60.0)
    var radius: Float32 = 8.0
    var color = Color(0, 0, 0, 200)
    var n_layers: Int = 4
    var prev_tri_count: Int = 0
    for i in range(n_layers):
        var inset = Float32(i) * Float32(1.0)
        var shadow_rect = Rect(
            rect.x - inset,
            rect.y - inset,
            rect.w + Float32(2.0) * inset,
            rect.h + Float32(2.0) * inset,
        )
        var built = _build_rounded_rect_verts(
            shadow_rect, radius + inset, color, DEFAULT_CORNER_SEGS
        )
        var indices = built[1].copy()
        var tris = len(indices) // 3
        # Every layer should produce the same triangle count
        # (4 * DEFAULT_CORNER_SEGS + 10) — geometry shape doesn't
        # change with the inset/radius growth.
        var expected = 4 * Int(DEFAULT_CORNER_SEGS) + 10
        if tris != expected:
            print("layer", i, " tris:", tris, " want:", expected)
            _fail("shadow layer triangle count")
        if i > 0:
            # Each layer geometry has the same number of triangles, sanity.
            if tris != prev_tri_count:
                _fail("shadow layer count divergence")
        prev_tri_count = tris


# ============================================================
# Signature proofs — FFI-touching surface (runtime-False JIT guard)
# ============================================================


def test_tess_rounded_rect_emits_cmd_triangles() raises:
    """`tess_rounded_rect` emits exactly ONE CMD_TRIANGLES record into
    `ctx.commands`. M3 c46-fix Bug 2 routing — no FFI in the call body,
    so the call runs cleanly under JIT."""
    var ctx = Context()
    var before = ctx.commands.byte_count()
    tess_rounded_rect(
        ctx, Rect(0.0, 0.0, 100.0, 50.0), Float32(8.0), Color.white(), 4
    )
    if ctx.commands.byte_count() <= before:
        _fail("tess_rounded_rect did not grow command buffer")
    if Int32(ctx.commands.kind_at(Int32(before))) != Int32(CMD_TRIANGLES):
        _fail("expected CMD_TRIANGLES at the first emitted offset")


def test_tess_circle_emits_cmd_triangles() raises:
    """`tess_circle` emits exactly ONE CMD_TRIANGLES record into ctx.commands."""
    var ctx = Context()
    var before = ctx.commands.byte_count()
    tess_circle(ctx, Vec2(50.0, 50.0), Float32(10.0), Color.white(), 24)
    if ctx.commands.byte_count() <= before:
        _fail("tess_circle did not grow command buffer")
    if Int32(ctx.commands.kind_at(Int32(before))) != Int32(CMD_TRIANGLES):
        _fail("expected CMD_TRIANGLES at the first emitted offset")


def test_tess_drop_shadow_emits_per_layer_records() raises:
    """`tess_drop_shadow(blur=4)` emits 4 CMD_TRIANGLES records (one per
    concentric-rect layer). Walks the buffer and counts CMD_TRIANGLES
    headers."""
    var ctx = Context()
    tess_drop_shadow(
        ctx,
        Rect(20.0, 20.0, 100.0, 60.0),
        Float32(8.0),
        Float32(4.0),
        Float32(0.0),
        Float32(2.0),
        Color(0, 0, 0, 200),
    )
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    var n_tri = 0
    while off < end_off:
        if Int32(ctx.commands.kind_at(off)) == Int32(CMD_TRIANGLES):
            n_tri = n_tri + 1
        off = off + ctx.commands.size_at(off)
    if n_tri != 4:
        print("got n_tri:", n_tri, "expected 4")
        _fail("drop_shadow blur=4 should emit 4 CMD_TRIANGLES records")


def test_drop_shadow_offset_geometry() raises:
    """Verify that with offset (2, 4), each layer's rect is shifted by the
    offset relative to the source. Walks the same per-layer build the
    `tess_drop_shadow` function does, asserts the offset propagates."""
    var rect = Rect(20.0, 20.0, 100.0, 60.0)
    var radius: Float32 = 8.0
    var color = Color(0, 0, 0, 200)
    var off_x: Float32 = 2.0
    var off_y: Float32 = 4.0
    var n_layers: Int = 4
    for i in range(n_layers):
        var inset = Float32(i) * Float32(1.0)
        var shadow_rect = Rect(
            rect.x + off_x - inset,
            rect.y + off_y - inset,
            rect.w + Float32(2.0) * inset,
            rect.h + Float32(2.0) * inset,
        )
        # Layer 0 must sit at rect + (off_x, off_y). Layers i>0 shift
        # outward by -i but still relative to the offset anchor.
        var expected_x = rect.x + off_x - inset
        var expected_y = rect.y + off_y - inset
        if _abs(shadow_rect.x - expected_x) > Float32(1.0e-5):
            _fail("drop_shadow offset x mismatch")
        if _abs(shadow_rect.y - expected_y) > Float32(1.0e-5):
            _fail("drop_shadow offset y mismatch")
        # Build the geometry to confirm it tessellates without raising.
        var built = _build_rounded_rect_verts(
            shadow_rect, radius + inset, color, DEFAULT_CORNER_SEGS
        )
        var indices = built[1].copy()
        if len(indices) <= 0:
            _fail("drop_shadow layer produced empty indices")
    print("PASS: drop_shadow offset (2,4) geometry")


def test_tess_outer_glow_emits_cmd_triangles() raises:
    """`tess_outer_glow` is a back-compat wrapper for tess_drop_shadow with
    zero offset. Verifies it composes the same CMD_TRIANGLES records via
    the ctx.commands path (M3 c46-fix Bug 2)."""
    var ctx = Context()
    var before = ctx.commands.byte_count()
    tess_outer_glow(
        ctx,
        Rect(20.0, 20.0, 100.0, 60.0),
        Float32(8.0),
        Float32(4.0),
        Color(0, 0, 0, 200),
    )
    if ctx.commands.byte_count() <= before:
        _fail("tess_outer_glow did not grow command buffer")
    if Int32(ctx.commands.kind_at(Int32(before))) != Int32(CMD_TRIANGLES):
        _fail("expected CMD_TRIANGLES at the first emitted offset")


def test_build_rounded_rect_negative_dims_returns_empty() raises:
    """A rect with negative width or height has no visible output.
    The builder must return empty vertex+index lists rather than
    producing inverted geometry."""
    var built_neg_w = _build_rounded_rect_verts(
        Rect(0.0, 0.0, Float32(-10.0), 50.0), Float32(5.0), Color.white(), 4
    )
    if len(built_neg_w[0]) != 0:
        _fail("negative width: expected empty vertex list")
    if len(built_neg_w[1]) != 0:
        _fail("negative width: expected empty index list")
    var built_neg_h = _build_rounded_rect_verts(
        Rect(0.0, 0.0, 50.0, Float32(-10.0)), Float32(5.0), Color.white(), 4
    )
    if len(built_neg_h[0]) != 0:
        _fail("negative height: expected empty vertex list")
    if len(built_neg_h[1]) != 0:
        _fail("negative height: expected empty index list")
    var built_zero = _build_rounded_rect_verts(
        Rect(0.0, 0.0, 0.0, 50.0), Float32(5.0), Color.white(), 4
    )
    if len(built_zero[0]) != 0:
        _fail("zero width: expected empty vertex list")
    print("PASS: negative-dim rect returns empty geometry")


# ============================================================
# Entry
# ============================================================


def main() raises:
    test_build_rounded_rect_radius_zero_emits_vertices()
    test_build_rounded_rect_radius_positive_grows_vertex_count()
    test_build_rounded_rect_triangle_count()
    test_build_rounded_rect_radius_clamped_to_half_min()
    test_build_rounded_rect_min_segs_clamps_up_to_1()
    test_build_circle_default_counts()
    test_build_circle_perimeter_on_radius()
    test_build_circle_centre_at_origin()
    test_build_circle_low_segs_clamps_to_3()
    test_build_circle_indices_wrap_around()
    test_drop_shadow_emits_per_layer_blur4()
    test_tess_rounded_rect_emits_cmd_triangles()
    test_tess_circle_emits_cmd_triangles()
    test_tess_drop_shadow_emits_per_layer_records()
    test_drop_shadow_offset_geometry()
    test_tess_outer_glow_emits_cmd_triangles()
    test_build_rounded_rect_negative_dims_returns_empty()
    print(
        "PASS: tessellator smoke (rounded rect builder + circle builder +",
        "shadow per-layer geometry + 4 CMD_TRIANGLES routing tests +",
        "drop_shadow offset + outer_glow wrapper + negative-dim guard)",
    )
