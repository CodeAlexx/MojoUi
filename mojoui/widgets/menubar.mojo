"""Top-bar menubar — horizontal row of menu buttons, each opens a popup of
items below. M5 menu system, built on `widgets/popup.mojo` and the M5
popup-layer primitive on `Context`.

Visual model: a row of buttons (`File | Edit | View | Help`) at fixed
`menu_button_width` apiece, height `ctx.theme.row_height`. Clicking a
button toggles its menu open/closed; opening a button auto-closes any
previously-open menu (mutual exclusion). When a menu is open, the popup
list is drawn beneath the button using `popup(...)`; clicking an item
returns `(menu_idx, item_idx)` to the caller and closes the menu.

State ownership (per Mojo implementation notes "Module-level `var` is REJECTED"):
  `open_menu` is a caller-managed `Int32`. -1 means no menu is open; a
  non-negative value is the index of the currently-open menu in `menus`.
  The widget toggles this directly. Same pattern as combobox's `is_open`.

Click semantics:
  - Click a CLOSED button → its menu opens (`open_menu = i`).
  - Click the SAME OPEN button → its menu closes (`open_menu = -1`).
  - Click a DIFFERENT button while a menu is open → the popup detects
    "press outside popup" on press-frame and closes itself; the other
    button's CTRL_RELEASED fires on release-frame and opens the new
    menu. (Two-frame transition — matches the press-then-release nature
    of a click; visually instantaneous to the user since both events
    happen within ~16ms.)
  - Click an ITEM in the open popup → caller gets `(menu_idx, item_idx)`,
    popup closes (`open_menu = -1`).
  - Click ANYWHERE ELSE → popup closes via its built-in
    click-outside-to-close logic.

Out params (`mut clicked_menu`, `mut clicked_item`):
  Caller initialises both to -1 before the call. After the call, if an
  item was clicked, both are >= 0; otherwise both stay -1. Mojo current-
  beta function syntax makes returning a tuple awkward; out-params keep
  the call site readable and match the convention used by combobox's
  `mut selected_index` and `mut is_open`.

ID strategy:
  Caller-supplied `id_str` scopes the menubar as a whole. Each menu
  button's id is derived by hashing the menu's `label`; the popup's id
  is derived by appending "_popup" to the open menu's label. As long as
  the caller doesn't have two menus with the same label, ids are
  collision-free.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_FOCUSED,
    CTRL_ACTIVE,
    CTRL_RELEASED,
    OPT_NONE,
)
from mojoui.widgets.popup import popup


@fieldwise_init
struct MenuSpec(Copyable, Movable):
    """One menu in the menubar: a button label + the items shown in its
    dropdown popup.

    `Copyable, Movable` but NOT `ImplicitlyCopyable` (matches `String` /
    `List[String]`). Every read needs `.copy()` — see Mojo implementation notes
    "Copyable ≠ ImplicitlyCopyable".
    """

    var label: String
    var items: List[String]


def menubar(
    mut ctx: Context,
    id_str: String,
    menus: List[MenuSpec],
    menu_button_width: Float32,
    popup_item_width: Float32,
    mut open_menu: Int32,
    mut clicked_menu: Int32,
    mut clicked_item: Int32,
):
    """Draw a horizontal row of menu buttons; render the currently-open
    menu's dropdown popup beneath its button.

    Args:
        ctx:                Per-frame Context. Uses `theme.row_height`,
                            `font_size_pt`, `padding`; palette pulls
                            `theme.primary` / `hover_bg` / `active_bg`
                            for the buttons and the popup widget's
                            theme keys for the dropdown.
        id_str:             Caller-supplied scope id (e.g. `"main_menubar"`).
                            Push more parent ids before calling if you
                            need multiple menubars in the same window.
        menus:              List of MenuSpec. May be empty (no-op).
        menu_button_width:  Pixel width of each top-row button.
        popup_item_width:   Pixel width of the dropdown popup. Typically
                            wider than `menu_button_width` (so long item
                            labels fit) but caller's choice.
        open_menu:          Caller-managed open-menu index. -1 = closed;
                            0..len(menus)-1 = the menu whose popup is
                            currently shown. Widget toggles this on
                            button click and clears it on item click /
                            click-outside.
        clicked_menu:       Out — set to the menu index whose item was
                            clicked this frame, or -1 if no item click.
                            Initialise to -1 before calling.
        clicked_item:       Out — set to the item index inside the
                            clicked menu, or -1 if no item click.
                            Initialise to -1 before calling.
    """
    var n_menus = Int32(len(menus))
    if n_menus == 0:
        return

    ctx.push_id_str(id_str)

    # Lay out one horizontal row of n_menus equal-width slots. We DON'T
    # use ctx.layout_row here because the caller may already have a row
    # active (in a window layout). Instead we compute button rects from
    # the current layout position. To keep this simple and predictable,
    # we anchor at (0, 0) — the menubar is intended as a top-of-window
    # element. Caller wanting a different anchor can ctx.push a sub-
    # layout frame OR (TODO M6) we accept an anchor argument.
    var row_h = Float32(ctx.theme.row_height)

    # Track each button's rect so we can anchor the popup later.
    var button_xs = List[Float32]()
    var button_y: Float32 = 0.0

    # ---- Per-button pass: update_control + draw, capture click toggles ----
    var i: Int32 = 0
    while i < n_menus:
        var bx = Float32(i) * menu_button_width
        button_xs.append(bx)
        var brect = Rect(bx, button_y, menu_button_width, row_h)
        var bid = ctx.get_id(menus[Int(i)].label)
        var flags = ctx.update_control(bid, brect.copy(), OPT_NONE)

        # Click toggles open/close on THIS menu. Mutual-exclusion (closing
        # any other open menu) is handled by the popup's click-outside
        # detection on the PRESS frame; the button's CTRL_RELEASED on the
        # RELEASE frame then opens this one.
        if (flags & CTRL_RELEASED) != 0:
            if open_menu == i:
                open_menu = -1
            else:
                open_menu = i

        # Button background. "This menu is open" looks like ACTIVE so
        # the user can see which menu is currently dropped down even
        # after they moved the mouse away.
        var bg: Color
        if open_menu == i:
            bg = ctx.theme.active_bg.copy()
        elif (flags & CTRL_ACTIVE) != 0:
            bg = ctx.theme.active_bg.copy()
        elif (flags & CTRL_HOVERED) != 0:
            bg = ctx.theme.hover_bg.copy()
        else:
            bg = ctx.theme.primary.copy()
        ctx.draw_rect(brect.copy(), bg^)

        # Label text — centered-ish in the button. Same font_id==0 guard
        # as combobox per regression notes FRAGILE #5.
        if ctx.theme.font_id != 0:
            var text_pos = Vec2(
                brect.x + Float32(ctx.theme.padding),
                brect.y + (brect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                text_pos^,
                ctx.theme.text.copy(),
                menus[Int(i)].label,
            )

        i = i + 1

    # ---- Open-menu popup ----
    # Run AFTER all menu buttons so their update_control already claimed
    # any hover before the popup_rect lands in popup_rects.
    if open_menu >= 0 and open_menu < n_menus:
        var idx = Int(open_menu)
        var anchor = Vec2(button_xs[idx], button_y + row_h)
        var popup_open: Bool = True
        var pid = String("popup_") + menus[idx].label
        # popup() may set popup_open=False via click-outside or item click.
        var item = popup(
            ctx, pid^, anchor^,
            menus[idx].items, popup_item_width, popup_open,
        )
        if item >= 0:
            clicked_menu = open_menu
            clicked_item = item
            open_menu = -1
        elif not popup_open:
            # popup closed itself (click-outside) without an item click.
            open_menu = -1

    ctx.pop_id()
