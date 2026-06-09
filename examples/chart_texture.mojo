"""MojoUI + MOJO-libs `graphics`: render a chart on the CPU, show it as a texture.

MojoUI draws shapes via GPU tessellation, so the `graphics` CPU rasterizer is not
a replacement renderer — it's the way to put *offscreen 2D content* (charts,
custom visualizations, sparklines) into a MojoUI frame: draw into a `graphics`
`Canvas`, hand the RGBA bytes to `Backend.make_texture_rgba`, and draw the
returned texture with `Backend.draw_image_rect`.

The CPU chart rasterization below REALLY runs (no GL needed). The Backend
texture/draw calls are compile-proved against the real signatures but gated behind
a runtime-False guard — same pattern as `m1_button` (no live GL context in this
environment). Build (links the C floor so the FFI symbols resolve):

  pixi run mojo build -I . -I /home/alex/MOJO-libs \\
      -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \\
      examples/chart_texture.mojo -o /tmp/mojoui_chart \\
  && LD_LIBRARY_PATH=. /tmp/mojoui_chart
"""

from mojoui.core.types import Rect, Color
from mojoui.render.backend import Backend
from mojoui.render.ffi import MOJOUI_KEY_COUNT

from graphics.canvas import Canvas
from graphics.color import rgb as grgb
from graphics.chart import bar_chart, line_chart
from graphics.text import draw_text
from graphics.texture import to_rgba_list


def main() raises:
    # runtime-False, opaque to the optimizer (same trick as m1_button): the
    # Backend GPU calls below type-check + link but never execute here.
    var never: Bool = (Int(MOJOUI_KEY_COUNT) - 96) != 0

    # 1) render a chart into a CPU canvas with graphics primitives — REALLY RUNS
    var W = 300
    var H = 170
    var cv = Canvas(W, H)
    cv.clear(grgb(24, 26, 34))
    draw_text(cv, 8, 6, String("REVENUE"), grgb(240, 200, 40), 2)
    var vals = List[Float64]()
    for v in [42.0, 58.0, 35.0, 73.0, 61.0, 88.0]:
        vals.append(v)
    bar_chart(cv, 20, 26, 260, 120, vals, grgb(38, 139, 210), grgb(190, 190, 200))

    # 2) convert to the exact RGBA8 list MojoUI's texture upload consumes — RUNS
    var pixels = to_rgba_list(cv)
    print("chart canvas:", W, "x", H, "-> rgba bytes:", len(pixels),
          "(expected", W * H * 4, ")")

    # 3) upload + draw inside a MojoUI frame — compile-proved, gated off here
    if never:
        _ = Backend.init(Int32(640), Int32(400), String("chart-texture"))
        Backend.frame_begin(Color(UInt8(18), UInt8(20), UInt8(28)))
        var tex = Backend.make_texture_rgba(Int32(W), Int32(H), pixels)
        Backend.draw_image_rect(
            Rect(Float32(40), Float32(40), Float32(W), Float32(H)),
            tex,
            Color(UInt8(255), UInt8(255), UInt8(255)),
        )
        Backend.frame_end()
        Backend.shutdown()

    print("PASS: graphics chart -> RGBA texture data; MojoUI upload+draw compile-proved")
