"""MojoUI m8 — Z-Image backend adapter seam (STUB default).

This is the ONE file where MojoUI would call serenitymojo's GPU inference. It
is deliberately thin and FFI-free in its default form so the whole m8 app keeps
building in MojoUI's own pixi env WITHOUT the serenitymojo (MAX + multi-GB
weights) env merged in.

## The env split (why this file exists)

- MojoUI lives in `the MojoUI repo` (package `mojoui`, modular + C floor).
- serenitymojo lives in `<path-to-mojodiffusion>` (package `serenitymojo`,
  MAX + weights), a SEPARATE pixi project.

A single binary importing both is an env-merge problem we do NOT solve today.
So the real `from serenitymojo... import zimage_generate` import is GATED behind
the comptime flag `ZIMAGE_REAL_BACKEND` (default False). With the flag False the
adapter returns a deterministic synthetic RGBA buffer so the mock UI path keeps
working and `pixi run inference` / `pixi run test` stay green in MojoUI's env.

## Cross-env build (GPU time only)

When the GPU is free and the two envs are merged, flip `ZIMAGE_REAL_BACKEND` to
True and build with serenitymojo on the import path:

    mojo build -I . -I <path-to-mojodiffusion> \\
      -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \\
      examples/m8_inference_ui.mojo -o /tmp/mojoui_m8_real

Then the `_real_zimage_generate` branch below calls serenitymojo's
`zimage_generate(prompt, negative, steps, cfg, seed, width, height, events,
ctx)` (which preserves the GPU-verified denoise numerics; the only behavioral
change vs the verified comptime-exact run is the fixed-padded caption — flag
that for parity re-verification, see Z-Image wiring notes).

This file has NO `from serenitymojo` import while the flag is False so MojoUI's
env never needs MAX or the weights to compile.
"""


# ---------------------------------------------------------------------------
# Seam flag. False = stub (default, MojoUI-only build). True = real
# serenitymojo backend (requires the merged env + GPU; do NOT flip in CI).
# ---------------------------------------------------------------------------

comptime ZIMAGE_REAL_BACKEND: Bool = False


# ---------------------------------------------------------------------------
# Decoded-image carrier. RGBA8 row-major [h][w][4]; the m8 preview converts
# this into a Backend texture (Backend.make_texture) when a real result lands.
# In stub mode `pixels` is a deterministic gradient keyed on the param snapshot
# so the existing synthetic-preview behavior is preserved without any GPU.
# ---------------------------------------------------------------------------


struct ZImageResult(Movable):
    var width: Int
    var height: Int
    var pixels: List[UInt8]   # len == width*height*4, RGBA8
    var ok: Bool
    var error: String

    def __init__(out self, width: Int, height: Int, var pixels: List[UInt8]):
        self.width = width
        self.height = height
        self.pixels = pixels^
        self.ok = True
        self.error = String("")

    @staticmethod
    def failure(msg: String) -> ZImageResult:
        var empty = List[UInt8]()
        var r = ZImageResult(0, 0, empty^)
        r.ok = False
        r.error = msg
        return r^


# ---------------------------------------------------------------------------
# Stub generator. Produces a deterministic RGBA gradient from the param
# snapshot — the SAME role the m8 synthetic preview plays — so the adapter has
# a real, testable return value without touching the GPU or serenitymojo.
# ---------------------------------------------------------------------------


def _stub_zimage_generate(
    prompt: String, negative: String,
    steps: Int, cfg: Float32, seed: Int64,
    width: Int, height: Int, color_seed: UInt32,
) -> ZImageResult:
    if width <= 0 or height <= 0:
        return ZImageResult.failure(String("stub: non-positive size"))
    var n = width * height * 4
    var px = List[UInt8](capacity=n)
    var s = color_seed
    for y in range(height):
        # Per-row band color folded from the seed (mirrors _draw_synthetic).
        s = (s ^ UInt32(y)) * UInt32(2654435761)
        var r = UInt8((s >> 16) & UInt32(0xFF))
        var g = UInt8((s >> 8) & UInt32(0xFF))
        var b = UInt8(s & UInt32(0xFF))
        for _x in range(width):
            px.append(r)
            px.append(g)
            px.append(b)
            px.append(UInt8(255))
    return ZImageResult(width, height, px^)


# ---------------------------------------------------------------------------
# Real generator (GATED). When ZIMAGE_REAL_BACKEND is False this is a hard
# error so a mis-build can never silently run the stub as if it were real.
#
# Under the merged env, replace the body with:
#
#   from std.gpu.host import DeviceContext
#   from serenitymojo.pipeline.zimage_generate import (
#       zimage_generate, ZImageEvent,
#   )
#   var ctx = DeviceContext()
#   var events = List[ZImageEvent]()
#   var rgb = zimage_generate(prompt, negative, steps, cfg,
#                             UInt64(seed if seed >= 0 else 42),
#                             width, height, events, ctx)
#   # rgb is [1,3,H,W] SIGNED [-1,1]; convert CHW→RGBA8 here (see
#   # decoded_to_color_image in worker/zimage.rs for the (v+1)*127.5 mapping).
#   return ZImageResult(width, height, <rgba>^)
#
# Kept out of the default build so MojoUI's env needs neither MAX nor weights.
# ---------------------------------------------------------------------------


def _real_zimage_generate(
    prompt: String, negative: String,
    steps: Int, cfg: Float32, seed: Int64,
    width: Int, height: Int, color_seed: UInt32,
) -> ZImageResult:
    return ZImageResult.failure(
        String(
            "ZIMAGE_REAL_BACKEND is enabled but _real_zimage_generate is not"
            " wired in this build — merge the serenitymojo env (-I"
            " <path-to-mojodiffusion>) and replace this body. See"
            " Z-Image wiring notes."
        )
    )


# ---------------------------------------------------------------------------
# Public adapter entry. The worker calls THIS; it dispatches stub vs real at
# comptime so the rest of m8 never sees the serenitymojo import.
# ---------------------------------------------------------------------------


def adapter_zimage_generate(
    prompt: String, negative: String,
    steps: Int, cfg: Float32, seed: Int64,
    width: Int, height: Int, color_seed: UInt32,
) -> ZImageResult:
    comptime if ZIMAGE_REAL_BACKEND:
        return _real_zimage_generate(
            prompt, negative, steps, cfg, seed, width, height, color_seed
        )
    else:
        return _stub_zimage_generate(
            prompt, negative, steps, cfg, seed, width, height, color_seed
        )


def backend_is_real() -> Bool:
    """True when the real serenitymojo backend is compiled in (GPU env)."""
    return ZIMAGE_REAL_BACKEND
