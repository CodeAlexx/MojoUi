"""Smoke tests for `mojoui/widgets/tab_bar.mojo`.

Run: `pixi run test-tab-bar`

Pure `mojo run` (no FFI). Two-frame press→release click pattern from
test_checkbox. The bar takes ONE layout slot; tabs are laid out at
`tab_width` each inside it starting at the slot's x.

Covers:
  1. Empty labels → no-op, returns input active, no draws.
  2. Renders: N tabs emit draw commands (>= N CMD_RECT bg fills + baseline).
  3. Out-of-range active clamps into [0, n-1].
  4. Click tab 2 → active becomes 2.
  5. No interaction → active unchanged.
"""

from mojoui.core.types import Vec2, Rect
from mojoui.core.context import Context
from mojoui.core.commands import CMD_RECT
from mojoui.widgets.tab_bar import tab_bar


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _count_kind(ctx: Context, target_kind: Int32) -> Int32:
    var n: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == target_kind:
            n = n + 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off = off + step
    return n


def _begin(mut ctx: Context, mouse: Vec2, pressed: Bool, released: Bool) raises:
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(Int32(600))
    ctx.layout_row(widths^, Int32(30))


def _tabs() -> List[String]:
    var t = List[String]()
    t.append(String("Files"))
    t.append(String("Edit"))
    t.append(String("View"))
    return t^


def test_empty_labels_noop() raises:
    var ctx = Context()
    _begin(ctx, Vec2(0.0, 0.0), False, False)
    var empty = List[String]()
    var before = ctx.commands.byte_count()
    var active = tab_bar(ctx, String("t"), empty, 100.0, Int32(0))
    if active != Int32(0):
        _fail("empty tab_bar should return input active")
    if ctx.commands.byte_count() != before:
        _fail("empty tab_bar should emit no draw commands")
    ctx.end_frame()
    print("PASS: test_empty_labels_noop")


def test_renders_tabs() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)  # mouse off the bar
    var active = tab_bar(ctx, String("t"), _tabs(), 100.0, Int32(0))
    if active != Int32(0):
        _fail("no click should keep active 0")
    var rects = _count_kind(ctx, Int32(CMD_RECT))
    # 1 baseline + 3 tab bgs + 1 active underline = 5 minimum.
    if Int(rects) < 4:
        _fail("3 tabs should emit >= 4 CMD_RECT, got " + String(Int(rects)))
    ctx.end_frame()
    print("PASS: test_renders_tabs")


def test_out_of_range_active_clamps() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var active = tab_bar(ctx, String("t"), _tabs(), 100.0, Int32(99))
    if active != Int32(2):
        _fail("active=99 with 3 tabs should clamp to 2, got " + String(active))
    ctx.end_frame()

    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var active2 = tab_bar(ctx, String("t"), _tabs(), 100.0, Int32(-5))
    if active2 != Int32(0):
        _fail("active=-5 should clamp to 0, got " + String(active2))
    ctx.end_frame()
    print("PASS: test_out_of_range_active_clamps")


def test_click_selects_tab() raises:
    """Click tab index 2 (third tab). Tabs are 100px wide starting at x=0,
    so tab 2 spans x 200..300; click at x=250."""
    var ctx = Context()
    var active: Int32 = 0
    # Frame 1: press inside tab 2.
    _begin(ctx, Vec2(250.0, 15.0), True, False)
    active = tab_bar(ctx, String("t"), _tabs(), 100.0, active)
    ctx.end_frame()
    # Frame 2: release inside tab 2 → select.
    _begin(ctx, Vec2(250.0, 15.0), False, True)
    active = tab_bar(ctx, String("t"), _tabs(), 100.0, active)
    ctx.end_frame()
    if active != Int32(2):
        _fail("clicking tab 2 should set active=2, got " + String(active))
    print("PASS: test_click_selects_tab")


def test_no_interaction_keeps_active() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var active = tab_bar(ctx, String("t"), _tabs(), 100.0, Int32(1))
    if active != Int32(1):
        _fail("no click should keep active=1, got " + String(active))
    ctx.end_frame()
    print("PASS: test_no_interaction_keeps_active")


def main() raises:
    test_empty_labels_noop()
    test_renders_tabs()
    test_out_of_range_active_clamps()
    test_click_selects_tab()
    test_no_interaction_keeps_active()
    print("PASS: all 5 tab-bar tests")
