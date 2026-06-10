"""Load an SVG icon into a MojoUI texture (svg_icon_demo, compile-verified).

Proves the cross-repo path: MOJO-libs `svg` parses + rasterizes an icon to an
RGBA Canvas, then MojoUI uploads it as a GPU texture via make_texture_rgba —
ready to draw in the immediate-mode UI.

Build (links the C floor + needs MOJO-libs on the include path):
  pixi run mojo build -I . -I /home/alex/MOJO-libs \
    -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
    examples/svg_icon_demo.mojo -o /tmp/svg_icon
  LD_LIBRARY_PATH=. /tmp/svg_icon          # GUI needs a display
"""

from graphics.color import rgb
from svg.loader import load_svg_text, to_rgba_list
from mojoui.render.backend import Backend


def main() raises:
    # An icon (24x24 viewBox) — here a check mark; in practice load_svg_file(path).
    var icon = String(
        "<svg viewBox='0 0 24 24'>"
        "<path d='M4 12 L10 18 L20 6' fill='none' stroke='currentColor' stroke-width='2'/>"
        "</svg>"
    )

    # Rasterize to a 64x64 RGBA canvas, tinted with the theme's icon color.
    var tint = rgb(230, 230, 235)
    var canvas = load_svg_text(icon, 64, 64, tint)
    var pixels = to_rgba_list(canvas)
    print("rasterized icon:", canvas.w, "x", canvas.h, "->", len(pixels), "bytes")

    # Upload to a GPU texture (valid once a GL context exists — i.e. in-frame).
    # Shown here as the integration call; in a real app do this lazily on the
    # first frame, like font loading:
    #   var tex = Backend.make_texture_rgba(Int32(canvas.w), Int32(canvas.h), pixels)
    # then draw it via the image widget / textured rect with `tex`.
    _ = Backend.init(320, 240, String("SVG icon demo"))
    var tex = Backend.make_texture_rgba(Int32(canvas.w), Int32(canvas.h), pixels)
    print("texture id:", tex)
