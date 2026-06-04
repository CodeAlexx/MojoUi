"""Display-only progress bar — horizontal track with a colored fill.

M2 chunk 23. The progress bar is the simplest "stateful display" widget:
no interaction (no `get_id`, no `update_control`), no return value — just
a layout slot and a few draw commands sized by a fraction in [0, 1].

API:
    progress_bar(ctx, 0.5)   # half-full
    progress_bar(ctx, 0.0)   # empty (border + bg, no fill)
    progress_bar(ctx, 1.0)   # full-width fill
    progress_bar(ctx, -1.0)  # indeterminate (M2: just an empty track;
                             # M3: animated diagonal stripes)
    progress_bar(ctx, 1.5)   # clamped to 1.0 — no overflow past rect.w

Following the microui pattern (`AUDIT_microui.md` "Widget Pattern") this
is the display-only variant of the 6-step recipe (steps 1 and 3 are
omitted — no id, no `update_control` — because labels / separators /
progress bars never interact). Same shape as `widgets/basic.mojo::label`
and `widgets/basic.mojo::separator`.

`.copy()` discipline (per MOJO_NOTES.md "Copyable ≠ ImplicitlyCopyable"):
every read of a `Rect` / `Color` / `DefaultTheme` field to pass into
another call has an explicit `.copy()`. The `rect` returned by
`layout_next` is read up to three times (border, background, fill); the
theme colour fields are `.copy()`'d at every read.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context


# ============================================================================
# progress_bar — display-only fraction indicator
# ============================================================================


def progress_bar(mut ctx: Context, fraction: Float32):
    """Draw a horizontal progress bar for `fraction` in [0.0, 1.0].

    Negative `fraction` (e.g. -1.0) signals indeterminate: draws the empty
    track only (M3 will overlay animated diagonal stripes). Values >1.0 are
    clamped to 1.0 so the fill never overflows the track rect.

    Visual: background track (theme.bg) under a 1-px border (theme.border)
    with a colored fill (theme.primary) from x to x + rect.w * fraction.

    Draw order matters — the fill is painted ON TOP of the background so
    the determinate fraction is visible; the border is painted last so the
    edge sits over both the bg and the fill. This is the same paint order
    as `widgets/basic.mojo::button` (bg → border → text).

    No interaction — pure display. Skips `get_id` / `update_control`
    entirely, so a progress_bar NEVER claims hover/focus/active even when
    the cursor is directly over it. Same property as `label` / `separator`.
    """
    # 1. layout — reserve a slot from the current row/column flow.
    var rect = ctx.layout_next()

    # 2. background track — full rect, theme.bg. Painted FIRST so the fill
    #    and the border can layer on top.
    ctx.draw_rect(rect.copy(), ctx.theme.bg.copy())

    # 3. fill — only for determinate fractions (>= 0.0). The width is
    #    clamped to [0, rect.w] so values >1.0 don't overflow. Negative
    #    fractions (indeterminate) skip the fill entirely — M2 stub.
    if fraction >= 0.0:
        var clamped = fraction
        if clamped > 1.0:
            clamped = 1.0
        # `clamped` is Float32 / `ImplicitlyCopyable` — no .copy() needed.
        var fill_w = rect.w * clamped
        if fill_w > 0.0:
            var fill = Rect(rect.x, rect.y, fill_w, rect.h)
            ctx.draw_rect(fill^, ctx.theme.primary.copy())

    # 4. border — 4 thin rects (top/bottom/left/right) painted LAST so the
    #    edge sits over the bg and the fill. Same shape as `basic.mojo`'s
    #    private `_draw_border` helper; replicated here so this module
    #    stays self-contained (no cross-file private import).
    _draw_border_outline(ctx, rect.copy(), ctx.theme.border.copy(), 1.0)


# ============================================================================
# Internal helpers
# ============================================================================


def _draw_border_outline(
    mut ctx: Context, rect: Rect, color: Color, thickness: Float32
):
    """Draw a rectangular outline as 4 thin filled rects (top, bottom, left,
    right with corner-avoidance on the side edges so corners aren't painted
    twice). Stub — proper AA outline drawing with miter joins comes with
    the M3 tessellator; the 4-rects-per-border cost is acceptable for M2.

    Mirror of `widgets/basic.mojo::_draw_border` (kept private there). The
    duplication is intentional: progress_bar is self-contained, so it does
    NOT import a private helper from a sibling widget module. When M3
    refactors to a shared AA outline path, both call sites collapse to one
    public helper in `widgets/draw.mojo` (or similar).

    `color` is read 4× via `.copy()` (Color is Copyable-not-
    ImplicitlyCopyable per MOJO_NOTES.md).
    """
    # Top edge: full width, `thickness` tall.
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    # Bottom edge.
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    # Left edge — inset by `thickness` top/bottom to avoid double-painting
    # the corners (they're already covered by top/bottom).
    ctx.draw_rect(
        Rect(rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness),
        color.copy(),
    )
    # Right edge.
    ctx.draw_rect(
        Rect(
            rect.x + rect.w - thickness,
            rect.y + thickness,
            thickness,
            rect.h - 2.0 * thickness,
        ),
        color.copy(),
    )
