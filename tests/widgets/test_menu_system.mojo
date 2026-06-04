"""Smoke tests for the M5 menu system: popup layer (Context), popup widget,
menubar, context_menu.

Run: `pixi run test-menu-system`

Coverage:
  1. Context popup layer — begin/end_popup routes draws to popup_commands;
     end_frame appends popup bytes after base bytes; active_layer resets.
  2. update_control suppression — base-layer widget under an open popup
     rect returns 0 flags; popup-layer widgets are unaffected.
  3. popup widget — closed returns -1 (no draw), open + item click returns
     idx and clears is_open, click-outside closes without dispatch.
  4. menubar widget — closed menubar (open_menu=-1) only draws buttons;
     opening + clicking an item dispatches via (clicked_menu, clicked_item)
     out params.
  5. context_menu / right_click_at — right-click inside a rect captures
     anchor + returns True.

JIT note: every test uses Context.begin_frame_no_input so we don't depend
on the FFI input poll. right_click_at reads `ctx.input.mouse_pressed`
which checks `ctx.input.mouse[].pressed` — that field IS written directly
when we synthesize input via _set_mouse_button below, bypassing the FFI
sample.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context, LAYER_BASE, LAYER_POPUP
from mojoui.core.control import OPT_NONE, CTRL_HOVERED, CTRL_RELEASED
from mojoui.render.ffi import MOJOUI_BTN_LEFT, MOJOUI_BTN_RIGHT
from mojoui.widgets.popup import popup
from mojoui.widgets.menubar import menubar, MenuSpec
from mojoui.widgets.context_menu import context_menu, right_click_at


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _begin(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
):
    """begin_frame_no_input with a 1-column row of (200, 24). Mirrors the
    helper in test_combobox so tests read familiarly."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def _set_right_button(mut ctx: Context, pressed: Bool, released: Bool):
    """Directly tickle the right-mouse-button edges in InputState so
    right_click_at can be tested without the FFI poll path. The `mouse[]`
    array is indexed by MOJOUI_BTN_* (0=L, 1=R, 2=M); we set RIGHT's
    pressed/released this-frame booleans. ctx.input.poll() is NOT
    called between this and the right_click_at check, so these values
    persist."""
    ctx.input.mouse[Int(MOJOUI_BTN_RIGHT)].pressed = pressed
    ctx.input.mouse[Int(MOJOUI_BTN_RIGHT)].released = released


def _items() -> List[String]:
    var xs = List[String]()
    xs.append(String("Open"))
    xs.append(String("Save"))
    xs.append(String("Quit"))
    return xs^


# ============================================================================
# 1. Context popup layer mechanics
# ============================================================================


def test_begin_popup_routes_draws_to_popup_buffer() raises:
    """A draw_rect call between begin_popup/end_popup lands in
    popup_commands, not the main commands buffer."""
    var ctx = Context()
    _begin(ctx, Vec2(500.0, 500.0), False, False)

    var base_before = ctx.commands.byte_count()
    var pop_before = ctx.popup_commands.byte_count()

    ctx.begin_popup(Rect(10.0, 10.0, 100.0, 100.0))
    if ctx.active_layer != LAYER_POPUP:
        _fail("active_layer should be LAYER_POPUP after begin_popup")
    ctx.draw_rect(Rect(20.0, 20.0, 50.0, 50.0), Color(255, 0, 0, 255))
    ctx.end_popup()
    if ctx.active_layer != LAYER_BASE:
        _fail("active_layer should reset to LAYER_BASE after end_popup")

    if ctx.commands.byte_count() != base_before:
        _fail("draw_rect inside popup must not grow the main commands buffer")
    if ctx.popup_commands.byte_count() <= pop_before:
        _fail("draw_rect inside popup must grow popup_commands buffer")

    ctx.end_frame()


def test_end_frame_appends_popup_bytes_after_base() raises:
    """After end_frame, popup bytes are concatenated onto commands.bytes;
    base draws emitted BEFORE the popup remain first, popup draws last."""
    var ctx = Context()
    _begin(ctx, Vec2(500.0, 500.0), False, False)

    # Base-layer draw
    ctx.draw_rect(Rect(0.0, 0.0, 10.0, 10.0), Color(1, 1, 1, 255))
    var base_only = ctx.commands.byte_count()

    # Popup-layer draw
    ctx.begin_popup(Rect(0.0, 0.0, 100.0, 100.0))
    ctx.draw_rect(Rect(50.0, 50.0, 10.0, 10.0), Color(2, 2, 2, 255))
    var popup_added = ctx.popup_commands.byte_count()
    ctx.end_popup()

    if ctx.commands.byte_count() != base_only:
        _fail("popup-layer draw must NOT touch commands until end_frame")

    ctx.end_frame()

    if ctx.commands.byte_count() != base_only + popup_added:
        _fail(
            String("after end_frame, commands.byte_count should equal base+popup; got ")
            + String(ctx.commands.byte_count())
            + String(" expected ")
            + String(base_only + popup_added)
        )


def test_update_control_suppressed_under_open_popup() raises:
    """A base-layer widget whose update_control runs AFTER begin_popup,
    with the mouse cursor inside the popup rect, must return 0 flags
    (suppressed). Same widget OUTSIDE the popup rect returns CTRL_HOVERED
    normally."""
    var ctx = Context()
    _begin(ctx, Vec2(50.0, 50.0), False, False)

    # Open a popup covering (0,0)-(100,100). The cursor at (50, 50) is
    # inside; a base-layer widget with rect (40,40)-(60,60) is also inside.
    ctx.begin_popup(Rect(0.0, 0.0, 100.0, 100.0))
    ctx.end_popup()  # only the popup_rects registration matters

    var id_under = ctx.get_id(String("under_popup"))
    var flags_under = ctx.update_control(id_under, Rect(40.0, 40.0, 20.0, 20.0), OPT_NONE)
    if flags_under != 0:
        _fail(String("widget under popup should return 0 flags; got ") + String(Int(flags_under)))

    # And a widget far from the popup whose rect contains the mouse — but
    # wait, the mouse is at (50,50) which IS inside the popup region we
    # registered. So any widget claim with mouse_over=True is suppressed
    # regardless of widget rect position. To test the non-suppressed path
    # we move the mouse out of the popup rect.
    ctx.end_frame()

    _begin(ctx, Vec2(200.0, 200.0), False, False)
    ctx.begin_popup(Rect(0.0, 0.0, 100.0, 100.0))
    ctx.end_popup()
    var id_far = ctx.get_id(String("far_from_popup"))
    var flags_far = ctx.update_control(id_far, Rect(190.0, 190.0, 20.0, 20.0), OPT_NONE)
    if (flags_far & CTRL_HOVERED) == 0:
        _fail("widget far from popup with mouse over it should claim hover")
    ctx.end_frame()


# ============================================================================
# 2. popup widget
# ============================================================================


def test_popup_closed_returns_minus_one_no_draw() raises:
    """A closed popup (is_open=False) returns -1 and emits NO popup-layer
    bytes."""
    var ctx = Context()
    _begin(ctx, Vec2(0.0, 0.0), False, False)
    var is_open: Bool = False
    var pop_before = ctx.popup_commands.byte_count()
    var idx = popup(
        ctx, String("p"), Vec2(0.0, 0.0), _items(), 150.0, is_open,
    )
    if Int(idx) != -1:
        _fail("closed popup should return -1")
    if ctx.popup_commands.byte_count() != pop_before:
        _fail("closed popup should not emit any popup-layer draws")
    ctx.end_frame()


def test_popup_item_click_returns_idx_and_closes() raises:
    """Open popup, press inside the second item, then release inside it.
    The release frame returns idx=1 and sets is_open=False."""
    var ctx = Context()
    var is_open: Bool = True
    # Popup at (0, 24); row_height defaults to 24. So row 0 = 24..48,
    # row 1 = 48..72, row 2 = 72..96. y=60 lands in row 1.

    # Frame 1: press inside row 1.
    _begin(ctx, Vec2(50.0, 60.0), True, False)
    var idx1 = popup(
        ctx, String("p"), Vec2(0.0, 24.0), _items(), 150.0, is_open,
    )
    if Int(idx1) != -1:
        _fail("press-only frame should return -1 (not the click event)")
    if not is_open:
        _fail("press inside popup must NOT close it (only click-outside or item-release)")
    ctx.end_frame()

    # Frame 2: release inside row 1 → click event.
    _begin(ctx, Vec2(50.0, 60.0), False, True)
    var idx2 = popup(
        ctx, String("p"), Vec2(0.0, 24.0), _items(), 150.0, is_open,
    )
    if Int(idx2) != 1:
        _fail(String("release on row 1 should return idx=1; got ") + String(Int(idx2)))
    if is_open:
        _fail("item click should close popup (is_open=False)")
    ctx.end_frame()


def test_popup_click_outside_closes_without_dispatch() raises:
    """Open popup, press OUTSIDE its rect. Popup closes (is_open=False),
    returns -1 (no item dispatched)."""
    var ctx = Context()
    var is_open: Bool = True
    # Popup at (0, 24)-(150, 96). Click at (500, 500) is far outside.
    _begin(ctx, Vec2(500.0, 500.0), True, False)
    var idx = popup(
        ctx, String("p"), Vec2(0.0, 24.0), _items(), 150.0, is_open,
    )
    if Int(idx) != -1:
        _fail("click-outside should return -1")
    if is_open:
        _fail("press outside popup should set is_open=False")
    ctx.end_frame()


def test_popup_empty_items_self_closes() raises:
    """Open popup with zero items closes itself and returns -1."""
    var ctx = Context()
    var is_open: Bool = True
    var empty = List[String]()
    _begin(ctx, Vec2(0.0, 0.0), False, False)
    var idx = popup(ctx, String("p"), Vec2(0.0, 0.0), empty, 150.0, is_open)
    if Int(idx) != -1:
        _fail("empty popup should return -1")
    if is_open:
        _fail("empty popup should close itself")
    ctx.end_frame()


# ============================================================================
# 3. menubar widget
# ============================================================================


def _make_menus() -> List[MenuSpec]:
    var file_items = List[String]()
    file_items.append(String("New"))
    file_items.append(String("Open"))
    file_items.append(String("Save"))
    var edit_items = List[String]()
    edit_items.append(String("Cut"))
    edit_items.append(String("Copy"))
    edit_items.append(String("Paste"))
    var menus = List[MenuSpec]()
    menus.append(MenuSpec(String("File"), file_items^))
    menus.append(MenuSpec(String("Edit"), edit_items^))
    return menus^


def test_menubar_closed_no_click() raises:
    """No interaction: closed menubar, no clicks → open_menu stays -1,
    clicked_menu/item stay -1."""
    var ctx = Context()
    _begin(ctx, Vec2(500.0, 500.0), False, False)
    var menus = _make_menus()
    var open_menu: Int32 = -1
    var cm: Int32 = -1
    var ci: Int32 = -1
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    if Int(open_menu) != -1: _fail("no-click frame: open_menu should stay -1")
    if Int(cm) != -1: _fail("no-click frame: clicked_menu should stay -1")
    if Int(ci) != -1: _fail("no-click frame: clicked_item should stay -1")
    ctx.end_frame()


def test_menubar_button_click_opens_menu() raises:
    """Press+release on the File button (rect x=0..80, y=0..24) opens
    its menu (open_menu becomes 0)."""
    var ctx = Context()
    var menus = _make_menus()
    var open_menu: Int32 = -1
    var cm: Int32 = -1
    var ci: Int32 = -1

    # Frame 1: press inside File button.
    _begin(ctx, Vec2(40.0, 12.0), True, False)
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    ctx.end_frame()

    # Frame 2: release inside File button → CTRL_RELEASED → toggle open.
    _begin(ctx, Vec2(40.0, 12.0), False, True)
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    if Int(open_menu) != 0:
        _fail(String("release on File should set open_menu=0; got ") + String(Int(open_menu)))
    ctx.end_frame()


def test_menubar_item_click_dispatches() raises:
    """With File menu open, press+release on its second item should set
    clicked_menu=0, clicked_item=1, and close open_menu."""
    var ctx = Context()
    var menus = _make_menus()
    var open_menu: Int32 = 0   # start with File open
    var cm: Int32 = -1
    var ci: Int32 = -1

    # File button rect: x=0..80, y=0..24. Popup anchored at (0, 24),
    # row_height=24, so item 0 = y 24..48, item 1 = y 48..72.
    # Frame 1: press inside item 1 (y=60).
    _begin(ctx, Vec2(40.0, 60.0), True, False)
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    ctx.end_frame()

    # Frame 2: release inside item 1.
    _begin(ctx, Vec2(40.0, 60.0), False, True)
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    if Int(cm) != 0:
        _fail(String("expected clicked_menu=0; got ") + String(Int(cm)))
    if Int(ci) != 1:
        _fail(String("expected clicked_item=1; got ") + String(Int(ci)))
    if Int(open_menu) != -1:
        _fail("item click should close open_menu (-1)")
    ctx.end_frame()


def test_menubar_click_outside_closes() raises:
    """With File menu open, pressing far away from both buttons and the
    popup closes the menu without dispatching."""
    var ctx = Context()
    var menus = _make_menus()
    var open_menu: Int32 = 0
    var cm: Int32 = -1
    var ci: Int32 = -1

    # Click at (500, 500) — outside the menubar and outside the popup.
    _begin(ctx, Vec2(500.0, 500.0), True, False)
    menubar(ctx, String("mb"), menus, 80.0, 160.0, open_menu, cm, ci)
    if Int(open_menu) != -1:
        _fail("click outside should close open_menu")
    if Int(cm) != -1 or Int(ci) != -1:
        _fail("click outside should NOT set clicked_menu/clicked_item")
    ctx.end_frame()


# ============================================================================
# 4. context_menu / right_click_at
# ============================================================================


def test_right_click_at_captures_anchor() raises:
    """RMB press inside a rect populates `anchor` with the mouse pos and
    returns True. Outside the rect or without the press flag → False."""
    var ctx = Context()
    _begin(ctx, Vec2(42.0, 99.0), False, False)
    _set_right_button(ctx, True, False)
    var anchor = Vec2(0.0, 0.0)
    var hit = right_click_at(ctx, Rect(0.0, 0.0, 200.0, 200.0), anchor)
    if not hit:
        _fail("RMB press inside rect should return True")
    if anchor.x != 42.0 or anchor.y != 99.0:
        _fail(
            String("expected anchor=(42,99); got (")
            + String(anchor.x) + String(",") + String(anchor.y) + String(")")
        )
    ctx.end_frame()

    # Outside the rect — no capture even on press.
    _begin(ctx, Vec2(500.0, 500.0), False, False)
    _set_right_button(ctx, True, False)
    var anchor2 = Vec2(0.0, 0.0)
    var hit2 = right_click_at(ctx, Rect(0.0, 0.0, 200.0, 200.0), anchor2)
    if hit2:
        _fail("RMB press outside rect should return False")
    ctx.end_frame()


def test_context_menu_item_click_dispatches() raises:
    """context_menu is a thin wrapper around popup; verify the end-to-end
    flow: anchored popup, click second item, returns 1 + closes."""
    var ctx = Context()
    var is_open: Bool = True

    # Anchor at (100, 100); item rows: row 0 = 100..124, row 1 = 124..148.
    # Click row 1 at (150, 130).
    _begin(ctx, Vec2(150.0, 130.0), True, False)
    var _ = context_menu(
        ctx, String("ctx"), Vec2(100.0, 100.0), _items(), 160.0, is_open,
    )
    ctx.end_frame()

    _begin(ctx, Vec2(150.0, 130.0), False, True)
    var idx = context_menu(
        ctx, String("ctx"), Vec2(100.0, 100.0), _items(), 160.0, is_open,
    )
    if Int(idx) != 1:
        _fail(String("expected idx=1 from row 1; got ") + String(Int(idx)))
    if is_open:
        _fail("context_menu item click should close it")
    ctx.end_frame()


# ============================================================================
# Main
# ============================================================================


def main() raises:
    test_begin_popup_routes_draws_to_popup_buffer()
    test_end_frame_appends_popup_bytes_after_base()
    test_update_control_suppressed_under_open_popup()

    test_popup_closed_returns_minus_one_no_draw()
    test_popup_item_click_returns_idx_and_closes()
    test_popup_click_outside_closes_without_dispatch()
    test_popup_empty_items_self_closes()

    test_menubar_closed_no_click()
    test_menubar_button_click_opens_menu()
    test_menubar_item_click_dispatches()
    test_menubar_click_outside_closes()

    test_right_click_at_captures_anchor()
    test_context_menu_item_click_dispatches()

    print("PASS: menu system smoke tests (13 tests)")
