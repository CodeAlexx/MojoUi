"""Image widget — display-only textured rect. M2 chunk 27.

The image widget is the simplest of the display-only widgets: it consumes a
layout slot (so subsequent widgets flow past it) and emits a single
`CMD_IMAGE` command that the renderer adapter (M3) will dispatch to
`Backend.draw_image` (textured-quad path through sokol_gfx with the
texture id from `Backend.make_texture` / the C-floor `mojoui_make_texture`).

Three entry points (sized to match the three call-site shapes M2/M2.5 needs):

  * `image(ctx, texture_id)`           — fills the next layout slot with the
                                          texture, white tint (no modulation).
  * `image_tinted(ctx, texture_id, tint)` — same as above with an explicit
                                          per-texel colour modulation (texel
                                          * tint, premultiplied alpha on the
                                          renderer side in M3).
  * `image_rect(ctx, rect, texture_id, tint)` — paints at an EXPLICIT rect
                                          that does NOT consume a layout slot.
                                          Used by the M2.5 node-graph canvas
                                          to draw socket icons at arbitrary
                                          positions inside a single canvas
                                          layout slot.

For M2 simplicity the image always stretches to fill the slot — no
preserve-aspect, no inset, no nine-slice. Aspect-preserving paint lands in
M3 alongside the proper sampler/scissor wiring (the texture's natural size
isn't known at the widget level yet — `Backend.texture_size(id)` is an M3
extension on the FFI surface).

There is NO `update_control` call on this widget — like `label`/`separator`
in `basic.mojo`, it never claims hover/focus/active even when the mouse is
over it. If an app needs a clickable image, the convention is to wrap
`image_rect` inside a manual `update_control` block (or to use a real
`image_button` widget, which is deferred).

The `.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Rect` and `Color` are `Copyable, Movable` but NOT `ImplicitlyCopyable`.
Every read of a function parameter into another call needs explicit
`.copy()` — the body below threads `.copy()` wherever required.
"""

from mojoui.core.types import Rect, Color
from mojoui.core.context import Context


# ============================================================================
# image — white-tint convenience (no colour modulation by default)
# ============================================================================


def image(mut ctx: Context, texture_id: UInt32):
    """Display-only textured rect. `texture_id` comes from
    `Backend.make_texture` / the C-floor `mojoui_make_texture` entry point.

    Allocates the next layout slot and emits a `CMD_IMAGE` painting that slot
    with the texture and a fully-opaque white tint (texel * white == texel,
    so the texture's own colours pass through unchanged).

    The image fills the slot by stretching — no preserve-aspect mode in M2.
    """
    # 1. layout_next — reserve the next slot from the current row/column flow.
    var rect = ctx.layout_next()

    # 2. (no id — display-only, no update_control invocation)

    # 3. draw — emit a CMD_IMAGE with white tint (no per-pixel modulation).
    #    Local `tint` then `.copy()` into emit_image is the canonical pattern
    #    for Color values per Mojo implementation notes (Color is Copyable-not-
    #    ImplicitlyCopyable, so the read of `tint` for the call needs .copy()).
    var tint = Color(255, 255, 255, 255)
    _ = ctx.commands.emit_image(rect.copy(), texture_id, tint.copy())


# ============================================================================
# image_tinted — explicit per-pixel colour modulation
# ============================================================================


def image_tinted(mut ctx: Context, texture_id: UInt32, tint: Color):
    """Tinted image — paints the next layout slot with `texture_id` and
    multiplies each texel by `tint` (so tint=(255,0,0,255) produces a red-
    only channel pass-through, tint=(255,255,255,128) is a 50%-alpha overlay,
    etc.).

    Identical to `image()` but exposes the tint colour. The two are kept
    separate because the white-tint case is so common at call sites that
    forcing every caller to construct an explicit `Color(255,255,255,255)`
    is noise.
    """
    var rect = ctx.layout_next()
    _ = ctx.commands.emit_image(rect.copy(), texture_id, tint.copy())


# ============================================================================
# image_rect — explicit rect, does NOT consume a layout slot
# ============================================================================


def image_rect(mut ctx: Context, rect: Rect, texture_id: UInt32, tint: Color):
    """Image at an EXPLICIT screen-space rect. Does NOT call `layout_next` —
    the caller has already computed the rect themselves (typically by adding
    an offset to the parent's already-claimed canvas rect).

    Used by the M2.5 node-graph canvas to draw socket icons and node-header
    glyphs at arbitrary positions inside ONE container layout slot. Also
    useful for sprite-style overlays on top of other widgets (the renderer
    walks commands in emit order, so a later `image_rect` paints on top).
    """
    _ = ctx.commands.emit_image(rect.copy(), texture_id, tint.copy())
