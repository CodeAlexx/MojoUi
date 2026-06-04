"""Tab bar widget — a horizontal row of selectable tabs.

A classic tabbed-interface selector: a row of clickable tab headers where
exactly one is active. The caller owns the `active` index (microui-style,
no widget retained state — same convention as combobox/slider) and renders
the matching panel itself based on the returned index:

    var active: Int32 = 0
    var tabs = [String("Files"), String("Edit"), String("View")]
    active = tab_bar(ctx, String("main_tabs"), tabs, 100.0, active)
    if active == 0:
        ... render Files panel ...
    elif active == 1:
        ... render Edit panel ...

Consumes ONE layout slot (`layout_next`) as the bar's bounding rect and
lays the tabs out left-to-right at `tab_width` each within it. The active
tab gets the `active_bg` fill plus a `primary` underline; hovered tabs get
`hover_bg`; the rest use `theme.bg`. A `border`-colored baseline runs under
the whole bar.

`.copy()` discipline per Mojo implementation notes: Vec2/Rect/Color reads passed onward
need `.copy()`.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_RELEASED, OPT_NONE


comptime _UNDERLINE_H: Float32 = 2.0
"""Thickness of the active-tab underline + the bar baseline (px)."""


def tab_bar(
    mut ctx: Context,
    id_str: String,
    labels: List[String],
    tab_width: Float32,
    active: Int32,
) -> Int32:
    """Render a row of tab headers and return the active index.

    Args:
        ctx:       Per-frame Context.
        id_str:    Id seed; per-tab ids derive under it (so two tab bars
                   don't collide).
        labels:    Tab header labels. Empty → no-op, returns `active`.
        tab_width: Width in px of each tab header.
        active:    Currently-active index (caller-owned). Clamped into
                   range; clicking a tab returns that tab's index.

    Returns: the active index after this frame (== a clicked tab's index,
    else the clamped input `active`).
    """
    var n = Int32(len(labels))
    if n == 0:
        return active

    # Clamp incoming active into [0, n-1].
    var result = active
    if result < Int32(0):
        result = Int32(0)
    elif result >= n:
        result = n - Int32(1)

    ctx.push_id_str(id_str)
    var bar = ctx.layout_next()
    var row_h = bar.h

    # Baseline under the whole bar (border color).
    ctx.draw_rect(
        Rect(bar.x, bar.y + row_h - _UNDERLINE_H, Float32(n) * tab_width, _UNDERLINE_H),
        ctx.theme.border.copy(),
    )

    var i: Int32 = 0
    while i < n:
        var tab_rect = Rect(
            bar.x + Float32(i) * tab_width, bar.y, tab_width, row_h
        )
        var tid = ctx.get_id(String(i))
        var flags = ctx.update_control(tid, tab_rect.copy(), OPT_NONE)
        if (flags & CTRL_RELEASED) != 0:
            result = i

        var is_active = i == result
        var bg: Color
        if is_active:
            bg = ctx.theme.active_bg.copy()
        elif (flags & CTRL_HOVERED) != 0:
            bg = ctx.theme.hover_bg.copy()
        else:
            bg = ctx.theme.bg.copy()
        ctx.draw_rect(tab_rect.copy(), bg^)

        # Active-tab underline in the accent/primary color, over the baseline.
        if is_active:
            ctx.draw_rect(
                Rect(
                    tab_rect.x,
                    tab_rect.y + row_h - _UNDERLINE_H,
                    tab_width,
                    _UNDERLINE_H,
                ),
                ctx.theme.primary.copy(),
            )

        # Label text (FRAGILE #5 — only when a font is loaded).
        if ctx.theme.font_id != 0:
            var pad = Float32(ctx.theme.padding)
            var text_pos = Vec2(
                tab_rect.x + pad,
                tab_rect.y + (row_h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                text_pos^,
                ctx.theme.text.copy(),
                labels[Int(i)],
            )

        i = i + 1

    ctx.pop_id()
    return result
