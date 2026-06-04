"""Popup widget — generic anchored item-list overlay. M5 menu system.

A popup is a transient overlay anchored at a window-space position, listing a
vertical run of clickable items. Building block for `menubar`, `context_menu`,
and any other "click here, get a list, pick one" UI. Uses the M5 popup-layer
primitive on `Context` (`ctx.begin_popup` / `ctx.end_popup`) so the popup's
draws are appended AFTER every base-layer widget at `end_frame` — guaranteed
to render on top regardless of where this widget call sits in the frame.

API shape mirrors `widgets/combobox.mojo` — caller owns the open flag and the
list of items; the widget returns the clicked-item index this frame (and
closes itself), or -1 if nothing was clicked.

State ownership (per Mojo implementation notes "Module-level `var` is REJECTED"):
  `is_open` is a caller-managed `Bool`. Same convention as combobox. The
  caller stores it alongside whatever triggered the popup (a menubar's
  selected-menu index, a right-click anchor Vec2, etc.) and threads both
  in each frame. Closing semantics:
    1. Clicking an item → `is_open = False`, returns the item index.
    2. Clicking OUTSIDE the popup rect (anywhere in the window that isn't
       the popup itself) → `is_open = False`, returns -1.
  The caller should NOT toggle `is_open` to True inside the popup call
  (that would re-open it during the same frame it just closed) — set it
  True from whatever button/right-click handler triggered the popup, and
  let the popup handle close.

Geometry contract:
  `anchor` is the popup's TOP-LEFT corner in window-space. The popup grows
  DOWN from there, `item_width` wide, `len(items) * row_h` tall, where
  `row_h = ctx.theme.row_height`. Caller is responsible for clamping the
  anchor so the popup doesn't fall off-window — there is no auto-flip-up
  logic yet (M6 polish). For a typical menubar item, anchor = button's
  bottom-left; for a context menu, anchor = right-click position.

ID strategy:
  Caller-supplied `id_str` is pushed for the popup as a whole; per-item ids
  are derived by hashing the item index ("0", "1", ...). Matches the
  combobox pattern so re-orderings of the item list don't cross-collide
  with sibling popups.

`.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
  `Vec2` / `Rect` / `Color` are `Copyable, Movable` but NOT
  `ImplicitlyCopyable`. Every field read passed to another call needs
  `.copy()`. `anchor` and the constructed popup `rect` are read multiple
  times; the per-row sub-rects are read twice each.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_ACTIVE,
    CTRL_RELEASED,
    OPT_NONE,
)


def popup(
    mut ctx: Context,
    id_str: String,
    anchor: Vec2,
    items: List[String],
    item_width: Float32,
    mut is_open: Bool,
) -> Int32:
    """Render a popup of clickable item rows. Returns the clicked-item
    index this frame (and sets `is_open = False`), or -1 if no item was
    clicked. Clicking anywhere OUTSIDE the popup also closes it.

    Args:
        ctx:        Per-frame Context. Uses `ctx.theme.row_height` /
                    `font_size_pt` / `padding` for row geometry and text
                    layout. Uses `theme.bg` / `hover_bg` / `active_bg` /
                    `text` / `border` for the palette.
        id_str:     Caller-supplied id seed. Two popups with the same
                    `id_str` under the same id_stack parent will collide.
                    Pass a logical name (`"file_menu"`, `"node_ctx"`, etc).
        anchor:     Window-space top-left corner of the popup. Caller is
                    responsible for keeping anchor on-screen (no
                    auto-flip-up yet).
        items:      Item labels. Empty list short-circuits — the popup
                    closes itself (no rows to click, dropdown is
                    pointless).
        item_width: Width in px of each item row. Caller picks; no
                    automatic text measurement in M5 (would require
                    Backend.text_width which is FFI and unreachable from
                    the JIT used by tests). 200 is a sensible default for
                    a top-bar menu.
        is_open:    Caller-managed open flag. Set True from whatever
                    triggered the popup; the widget sets it False on
                    item click or click-outside.

    Returns: clicked item index, or -1 if no click occurred this frame.
    """
    # Short-circuit: not open or empty items.
    if not is_open:
        return -1

    var n = Int32(len(items))
    if n == 0:
        # Caller passed an empty list — close (nothing to show).
        is_open = False
        return -1

    var row_h = Float32(ctx.theme.row_height)
    var popup_h = row_h * Float32(n)
    # Window-space rect of the entire popup. Used for begin_popup (input
    # suppression of base-layer widgets underneath) and for click-outside
    # detection below.
    var popup_rect = Rect(anchor.x, anchor.y, item_width, popup_h)

    # Click-outside detection: if a press happened this frame AND the
    # cursor was NOT inside the popup, close. We check this BEFORE
    # begin_popup so the press still falls through to whatever widget
    # the user intended to click (the popup doesn't swallow it). The
    # press inside popup is fine — update_control on a row will claim it.
    if ctx.control.mouse_pressed_this_frame:
        if not popup_rect.contains(ctx.control.mouse_pos.copy()):
            is_open = False
            return -1

    # Enter the popup draw layer: subsequent draw_* calls land in the
    # popup buffer (appended onto main buffer at end_frame → on top).
    ctx.begin_popup(popup_rect.copy())

    # Push the popup's id so per-row ids derive off it. Mirrors combobox.
    ctx.push_id_str(id_str)

    # Background fill + 1px border. We approximate the border as four thin
    # rects since there's no draw_line primitive at M5.
    ctx.draw_rect(popup_rect.copy(), ctx.theme.bg.copy())
    var border_t: Float32 = 1.0
    var bc = ctx.theme.border.copy()
    ctx.draw_rect(Rect(popup_rect.x, popup_rect.y, popup_rect.w, border_t), bc.copy())
    ctx.draw_rect(
        Rect(popup_rect.x, popup_rect.y + popup_rect.h - border_t, popup_rect.w, border_t),
        bc.copy(),
    )
    ctx.draw_rect(Rect(popup_rect.x, popup_rect.y, border_t, popup_rect.h), bc.copy())
    ctx.draw_rect(
        Rect(popup_rect.x + popup_rect.w - border_t, popup_rect.y, border_t, popup_rect.h),
        bc.copy(),
    )

    var clicked: Int32 = -1
    var i: Int32 = 0
    while i < n:
        var row_rect = Rect(
            anchor.x, anchor.y + Float32(i) * row_h, item_width, row_h,
        )
        var row_id = ctx.get_id(String(i))
        var flags = ctx.update_control(row_id, row_rect.copy(), OPT_NONE)

        # Per-row background: hover/active highlight, else transparent
        # (bg fill is already painted underneath by the popup background).
        if (flags & CTRL_ACTIVE) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.active_bg.copy())
        elif (flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.hover_bg.copy())

        # Item text — caller must have set theme.font_id (else skip, same
        # font_id==0 guard as combobox per regression notes FRAGILE #5).
        if ctx.theme.font_id != 0:
            var text_pos = Vec2(
                row_rect.x + Float32(ctx.theme.padding),
                row_rect.y + (row_rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                text_pos^,
                ctx.theme.text.copy(),
                items[Int(i)],
            )

        # CTRL_RELEASED on a row = click. Capture the index, close popup.
        # First-released wins (subsequent rows can't also be active, since
        # only one widget can be `active` at a time per microui invariant).
        if (flags & CTRL_RELEASED) != 0:
            clicked = i
            is_open = False

        i = i + 1

    ctx.pop_id()
    ctx.end_popup()

    return clicked
