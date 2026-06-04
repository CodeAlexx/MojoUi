"""Collapsing header widget — M2 chunk 26.

A section header with an expand/collapse toggle. Clicking the header flips
the `open` Bool; the function returns the current `open` state so the caller
can conditionally emit child widgets:

    var section_a_open: Bool = True
    if collapsing_header(ctx, "Section A", section_a_open):
        _ = button(ctx, "Inside A")
        _ = checkbox(ctx, "X", x_value)
    if collapsing_header(ctx, "Section B", section_b_open):
        _ = label(ctx, "Inside B")

Microui 6-step recipe (same shape as `widgets/checkbox.mojo::checkbox`):
    1. id     = ctx.get_id(label)
    2. rect   = ctx.layout_next()
    3. flags  = ctx.update_control(id, rect, OPT_NONE)
    4. behavior — on CTRL_RELEASED toggle `open`
    5. draw   — bg fill (hover_bg when hovered, theme.bg otherwise) +
                 triangle indicator on the LEFT (right-pointing ▶ when closed,
                 down-pointing ▼ when open) + label text to the right
    6. return — current value of `open` (caller's `if collapsing_header(...):`
                 controls child emission this frame).

Triangle is approximated for M2 by stacked thin rects (3 thin vertical-stacked
rows for ▶, single thin horizontal row for ▼) — proper tessellated triangles
arrive with M3's AA vector primitive. The public API is unchanged by that swap.

`.copy()` discipline (per MOJO_NOTES.md "Copyable ≠ ImplicitlyCopyable"):
`Color`/`Rect`/`Vec2`/`DefaultTheme` field reads need explicit `.copy()`. The
implementation threads `.copy()` everywhere required.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_RELEASED,
    OPT_NONE,
)


# Visual constants. `comptime` per current beta. Module-private.
comptime _TRI_SIZE: Float32 = 10.0
"""Bounding-box edge length of the triangle indicator (px)."""

comptime _TRI_BAR_THICKNESS: Float32 = 2.0
"""Thickness of each stacked rect used to approximate the triangle (px)."""


def collapsing_header(mut ctx: Context, label: String, mut open: Bool) -> Bool:
    """Section header with expand/collapse toggle. Clicking the header
    toggles `open`. Returns the CURRENT value of `open` so the caller can
    conditionally emit child widgets inside `if collapsing_header(...):`.

    `open` is read AND written. Caller stores the boolean state externally
    (microui-style, no widget retained state). `Bool` is `ImplicitlyCopyable`
    so no `.copy()` is needed on the parameter itself.

    Visual: bg fill (hover_bg when hovered, theme.bg otherwise — no special
    "open" highlight) + triangle indicator on the LEFT (▶ closed / ▼ open)
    + label text to the right.
    """
    # 1. id — derive from the label string under the current id_stack top.
    var id = ctx.get_id(label)

    # 2. layout slot — the whole rect is the click target.
    var rect = ctx.layout_next()

    # 3. update_control — .copy() rect because we need it again for drawing.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4. behavior — CTRL_RELEASED is the click; flip `open`.
    if (flags & CTRL_RELEASED) != 0:
        open = not open

    # 5. draw — background first (hover-aware), then triangle, then label.
    var bg: Color
    if (flags & CTRL_HOVERED) != 0:
        bg = ctx.theme.hover_bg.copy()
    else:
        bg = ctx.theme.bg.copy()
    ctx.draw_rect(rect.copy(), bg^)

    # Triangle geometry: top-left at (rect.x + padding, vcenter - size/2).
    var pad: Float32 = Float32(ctx.theme.padding)
    var tri_x: Float32 = rect.x + pad
    var tri_y: Float32 = rect.y + (rect.h - _TRI_SIZE) * 0.5

    # Triangle stub: stacked thin rects in the theme.text colour. The M3
    # tessellator will replace this with proper filled triangle geometry.
    if open:
        # ▼ down-pointing — single thin horizontal bar across the middle
        # of the bounding box. (M3: filled equilateral triangle apex-down.)
        ctx.draw_rect(
            Rect(
                tri_x,
                tri_y + (_TRI_SIZE - _TRI_BAR_THICKNESS) * 0.5,
                _TRI_SIZE,
                _TRI_BAR_THICKNESS,
            ),
            ctx.theme.text.copy(),
        )
    else:
        # ▶ right-pointing — 3 stacked thin vertical-segments of decreasing
        # width to suggest a right-pointing arrow. Top and bottom segments
        # are short, middle segment is wider. (M3: filled equilateral
        # triangle apex-right.)
        var seg_h: Float32 = _TRI_SIZE / 3.0
        # Top segment — short (1/3 of width), top of bbox.
        ctx.draw_rect(
            Rect(tri_x, tri_y, _TRI_SIZE / 3.0, seg_h),
            ctx.theme.text.copy(),
        )
        # Middle segment — wider (2/3 of width), middle of bbox.
        ctx.draw_rect(
            Rect(tri_x, tri_y + seg_h, _TRI_SIZE * 2.0 / 3.0, seg_h),
            ctx.theme.text.copy(),
        )
        # Bottom segment — short (1/3 of width), bottom of bbox.
        ctx.draw_rect(
            Rect(tri_x, tri_y + 2.0 * seg_h, _TRI_SIZE / 3.0, seg_h),
            ctx.theme.text.copy(),
        )

    # Label text — right of the triangle with one padding gap. Baseline-y
    # mirrors button/checkbox vertical-center calc.
    # Caller contract: call `ctx.set_default_font(<id>)` before the frame if
    # the label should render. When `ctx.theme.font_id == 0` the text draw is
    # SKIPPED — see SKEPTIC_FINDINGS_M1_2026-05-28.md FRAGILE #5.
    if ctx.theme.font_id != 0:
        var label_x: Float32 = tri_x + _TRI_SIZE + pad
        var label_y: Float32 = rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5
        var label_pos = Vec2(label_x, label_y)
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            label_pos^,
            ctx.theme.text.copy(),
            label,
        )

    # 6. return — CURRENT `open` (post-toggle from step 4). Caller's
    # `if collapsing_header(...):` controls child emission this frame.
    return open


def collapsing_header_accordion(
    mut ctx: Context, label: String, index: Int32, mut open_index: Int32
) -> Bool:
    """Accordion variant of `collapsing_header` — "only one open at a time".

    The caller owns a single `Int32 open_index` shared across a group of
    accordion headers. Each header is given its own `index`. A header is OPEN
    iff `open_index == index`. Clicking an open header closes it
    (`open_index = -1`); clicking a closed header opens it and implicitly
    closes whichever sibling was open (`open_index = index`).

    Returns True iff this header is currently open (so the caller can gate
    child emission inside `if collapsing_header_accordion(...):`). The bool
    `collapsing_header` API is unchanged and remains available — this is an
    opt-in helper that delegates the actual draw/hit-test to the bool variant
    via a synthesized local bool, then folds the result back into
    `open_index`.
    """
    var was_open = open_index == index
    var local_open = was_open
    var now_open = collapsing_header(ctx, label, local_open)
    if now_open != was_open:
        # The header was toggled this frame.
        if now_open:
            open_index = index   # open this one (closes the previous sibling)
        else:
            open_index = -1      # closed this one; nothing open
    return open_index == index
