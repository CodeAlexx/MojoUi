"""Smoke tests for `mojoui/widgets/radio.mojo` — M2 chunk 20.

Run: `pixi run test-radio`

Exercises the radio button's group semantics: N radios sharing a `mut
selected: Int32` form a mutually-exclusive group, clicking one writes its
`value` into `selected`, only the matching one paints with the inner dot
(we can't observe pixels — we verify the post-call state of `selected`).

JIT note: like all widget tests, uses `Context.begin_frame_no_input` to
bypass the FFI poll path (the JIT does not auto-dlopen libmojoui_floor.so
when no runtime path materialises `mojoui_get_mouse_*`).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, hash_str
from mojoui.core.context import Context
from mojoui.widgets.radio import radio


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — 3-row column-stacked layout of width 200 each, so radios drop into
# rects (0,0,200,24), (0,24,200,24), (0,48,200,24).
# ----------------------------------------------------------------------------


def _begin_3_row(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Begin a frame with a single 1-column row of width 200, height 24.
    The row will auto-wrap to a fresh row after each `layout_next()`, so
    three sequential `radio()` calls land in stacked rects at y = 0/24/48.
    """
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_basic_call() raises:
    """Test 1: radio() compiles and is callable with the documented signature.

    Three radios with values 1/2/3, shared `selected = 2` initially, mouse
    far away (no interaction). Returns False for all three; `selected`
    stays 2 (no click happened, no write occurred).
    """
    var ctx = Context()
    _begin_3_row(ctx, Vec2(500.0, 500.0), False, False)
    var selected: Int32 = 2
    var c1 = radio(ctx, String("Apple"), 1, selected)
    var c2 = radio(ctx, String("Banana"), 2, selected)
    var c3 = radio(ctx, String("Cherry"), 3, selected)
    if c1 or c2 or c3:
        _fail("no-click frame should return False from all three radios")
    if Int(selected) != 2:
        _fail("no-click frame should leave selected unchanged at 2")
    ctx.end_frame()


def test_radio_emits_draw_commands() raises:
    """Test 2: radio() emits draw commands — outer rect + inner dot (when
    selected) + label text. We don't check pixels; we verify the command
    buffer GREW (so something was painted)."""
    var ctx = Context()
    _begin_3_row(ctx, Vec2(500.0, 500.0), False, False)
    var selected: Int32 = 1
    var before_bytes = ctx.commands.byte_count()
    var _ = radio(ctx, String("Pick me"), 1, selected)
    var after_bytes = ctx.commands.byte_count()
    if after_bytes <= before_bytes:
        _fail("radio should emit at least one draw command (outer + dot + text)")
    ctx.end_frame()


def test_radio_no_change_when_pressed_but_not_released() raises:
    """Test 3: mouse INSIDE the first radio's rect, pressed=True released=False
    — no selection change yet (CTRL_RELEASED hasn't fired).
    """
    var ctx = Context()
    # Mouse at (10, 10) — inside the FIRST radio's rect at (0,0,200,24).
    _begin_3_row(ctx, Vec2(10.0, 10.0), True, False)
    var selected: Int32 = 2
    var c1 = radio(ctx, String("One"), 1, selected)
    if c1:
        _fail("press-only (no release) should not flip selection")
    if Int(selected) != 2:
        _fail("press-only frame should leave selected unchanged at 2")
    ctx.end_frame()


def test_radio_click_changes_selection() raises:
    """Test 4: click sequence on the value-3 radio across two frames.

    Frame 1 — press inside the third radio (active gets claimed).
    Frame 2 — release inside the third radio: selected flips 2 → 3,
              radio returns True.
    """
    var ctx = Context()
    var selected: Int32 = 2

    # Frame 1: press inside the third radio (y rect: 48..72; mouse at y=60).
    _begin_3_row(ctx, Vec2(10.0, 60.0), True, False)
    var _ = radio(ctx, String("A"), 1, selected)
    var _ = radio(ctx, String("B"), 2, selected)
    var f1_c = radio(ctx, String("C"), 3, selected)
    if f1_c:
        _fail("frame 1 (press) on radio C should not flip selection yet")
    if Int(selected) != 2:
        _fail("press frame should leave selected unchanged")
    ctx.end_frame()

    # Frame 2: release inside the third radio.
    _begin_3_row(ctx, Vec2(10.0, 60.0), False, True)
    var _ = radio(ctx, String("A"), 1, selected)
    var _ = radio(ctx, String("B"), 2, selected)
    var f2_c = radio(ctx, String("C"), 3, selected)
    if not f2_c:
        _fail("frame 2 (release-inside-active) on radio C should return True")
    if Int(selected) != 3:
        _fail("release on radio C should set selected = 3")
    ctx.end_frame()


def test_radio_no_change_when_clicking_already_selected() raises:
    """Test 5: clicking the ALREADY-selected radio is a no-op (no change
    flag). Selected stays the same value; radio returns False.
    """
    var ctx = Context()
    var selected: Int32 = 1

    # Frame 1: press inside the first radio (which IS the selected one).
    _begin_3_row(ctx, Vec2(10.0, 10.0), True, False)
    var _ = radio(ctx, String("A"), 1, selected)
    var _ = radio(ctx, String("B"), 2, selected)
    var _ = radio(ctx, String("C"), 3, selected)
    ctx.end_frame()

    # Frame 2: release inside the first radio.
    _begin_3_row(ctx, Vec2(10.0, 10.0), False, True)
    var f2_a = radio(ctx, String("A"), 1, selected)
    var _ = radio(ctx, String("B"), 2, selected)
    var _ = radio(ctx, String("C"), 3, selected)
    if f2_a:
        _fail("re-clicking already-selected radio should return False (no change)")
    if Int(selected) != 1:
        _fail("re-click on already-selected radio should not change selected")
    ctx.end_frame()


def test_three_radios_get_different_ids() raises:
    """Test 6: three different-label radios get different ImmediateIds.

    The radio derives its id from the label string (not from `value` and not
    from rect position) — same label-based contextual-hash discipline as
    button. This test confirms three distinct labels under the same id_stack
    scope produce three distinct ids, so they hover/focus/active independently.
    """
    var id_a = hash_str(String("Apple"))
    var id_b = hash_str(String("Banana"))
    var id_c = hash_str(String("Cherry"))
    if UInt32(id_a) == UInt32(id_b):
        _fail("hash_str sanity: 'Apple' and 'Banana' should hash differently")
    if UInt32(id_b) == UInt32(id_c):
        _fail("hash_str sanity: 'Banana' and 'Cherry' should hash differently")
    if UInt32(id_a) == UInt32(id_c):
        _fail("hash_str sanity: 'Apple' and 'Cherry' should hash differently")

    # Now verify via a real frame that the FIRST radio claims hover (mouse
    # at y=10 is in rect 0..24) and the others do not.
    var ctx = Context()
    _begin_3_row(ctx, Vec2(10.0, 10.0), False, False)
    var selected: Int32 = 1
    var _ = radio(ctx, String("Apple"), 1, selected)
    var _ = radio(ctx, String("Banana"), 2, selected)
    var _ = radio(ctx, String("Cherry"), 3, selected)
    if UInt32(ctx.control.hover) != UInt32(id_a):
        _fail("mouse over first radio should grant hover to 'Apple'")
    if UInt32(ctx.control.hover) == UInt32(id_b):
        _fail("hover should NOT be 'Banana' when mouse is over 'Apple'")
    if UInt32(ctx.control.hover) == UInt32(id_c):
        _fail("hover should NOT be 'Cherry' when mouse is over 'Apple'")
    ctx.end_frame()


def main() raises:
    test_compile_and_basic_call()
    test_radio_emits_draw_commands()
    test_radio_no_change_when_pressed_but_not_released()
    test_radio_click_changes_selection()
    test_radio_no_change_when_clicking_already_selected()
    test_three_radios_get_different_ids()
    print("PASS: radio widget smoke tests (6 tests)")
