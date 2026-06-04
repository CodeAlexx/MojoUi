"""Smoke tests for `mojoui/widgets/combobox.mojo` — M2 chunk 25.

Run: `pixi run test-combobox`

Exercises the combobox dropdown state machine: closed header toggle on click,
open-then-click-an-option flips `selected_index` + closes, re-click of the
already-selected option closes without change, out-of-bounds index renders
gracefully. The caller owns BOTH `selected_index` and `is_open` (Mojo has no
module-level mutable state); each test threads both through 2-frame
press→release sequences (so CTRL_RELEASED actually fires).

JIT note: like all widget tests, uses `Context.begin_frame_no_input` to
bypass the FFI poll path.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, hash_str
from mojoui.core.context import Context
from mojoui.widgets.combobox import combobox


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Helpers — single 1-column row of width 200, height 24 (matches test_radio).
# The closed header lands at (0, 0, 200, 24); open dropdown rows land STRICTLY
# BELOW the header at (0, 24, 200, 24), (0, 48, 200, 24), (0, 72, 200, 24), ...
# (per M2 bugfix 2026-05-28: option rects no longer overlap the header — see
# SKEPTIC_FINDINGS_M2_2026-05-28.md FRAGILE #2).
# ----------------------------------------------------------------------------


def _begin_1_row(
    mut ctx: Context,
    mouse_pos: Vec2,
    pressed: Bool,
    released: Bool,
) raises:
    """Begin a frame with a single 1-column row of width 200, height 24."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def _make_options() -> List[String]:
    """Standard 3-option list used by most tests."""
    var opts = List[String]()
    opts.append(String("Red"))
    opts.append(String("Green"))
    opts.append(String("Blue"))
    return opts^


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_compile_and_basic_call() raises:
    """Test 1: combobox() compiles and is callable with the documented
    signature. Closed, no click → no change, returns False, is_open stays
    False, selected_index untouched."""
    var ctx = Context()
    _begin_1_row(ctx, Vec2(500.0, 500.0), False, False)
    var opts = _make_options()
    var sel: Int32 = 1
    var is_open: Bool = False
    var changed = combobox(ctx, String("color"), opts, sel, is_open)
    if changed:
        _fail("no-click frame should return False")
    if Int(sel) != 1:
        _fail("no-click frame should leave selected_index unchanged at 1")
    if is_open:
        _fail("no-click frame should leave is_open False")
    ctx.end_frame()


def test_combobox_emits_draw_commands() raises:
    """Test 2: closed combobox emits header bg + selected text + glyph
    draw commands. We don't check pixels; we verify command buffer grew."""
    var ctx = Context()
    _begin_1_row(ctx, Vec2(500.0, 500.0), False, False)
    var opts = _make_options()
    var sel: Int32 = 0
    var is_open: Bool = False
    var before_bytes = ctx.commands.byte_count()
    var _ = combobox(ctx, String("color"), opts, sel, is_open)
    var after_bytes = ctx.commands.byte_count()
    if after_bytes <= before_bytes:
        _fail("closed combobox should emit at least bg + text + glyph commands")
    ctx.end_frame()


def test_header_click_toggles_open() raises:
    """Test 3: clicking the closed header opens the dropdown.

    Frame 1 — press inside header (claims active).
    Frame 2 — release inside header: CTRL_RELEASED fires → is_open = True.
    selected_index does NOT change (header click is not an option click).
    """
    var ctx = Context()
    var opts = _make_options()
    var sel: Int32 = 0
    var is_open: Bool = False

    # Frame 1: press inside header (mouse at y=10, header rect 0..24).
    _begin_1_row(ctx, Vec2(10.0, 10.0), True, False)
    var c1 = combobox(ctx, String("color"), opts, sel, is_open)
    if c1:
        _fail("press-only frame should return False (not a selection change)")
    if is_open:
        _fail("press-only frame should not yet toggle is_open")
    ctx.end_frame()

    # Frame 2: release inside header.
    _begin_1_row(ctx, Vec2(10.0, 10.0), False, True)
    var c2 = combobox(ctx, String("color"), opts, sel, is_open)
    if c2:
        _fail("header release should return False (header click is not a selection)")
    if not is_open:
        _fail("release inside header should toggle is_open to True")
    if Int(sel) != 0:
        _fail("header click should not change selected_index")
    ctx.end_frame()


def test_option_click_selects_and_closes() raises:
    """Test 4: when open, clicking an option writes its index into
    selected_index, closes the dropdown, returns True.

    Setup: combobox starts open with selected_index = 0. Click the second
    option (index 1) at y=60 (inside the second dropdown row 48..72). Per
    M2 bugfix 2026-05-28 (FRAGILE #2): option rects are strictly below the
    header, so option 0 = 24..48, option 1 = 48..72, option 2 = 72..96.
    """
    var ctx = Context()
    var opts = _make_options()
    var sel: Int32 = 0
    var is_open: Bool = True

    # Frame 1: press inside option-1 row (y=60 is in rect 48..72).
    _begin_1_row(ctx, Vec2(10.0, 60.0), True, False)
    var _ = combobox(ctx, String("color"), opts, sel, is_open)
    if not is_open:
        _fail("press-only frame should not close dropdown yet")
    ctx.end_frame()

    # Frame 2: release inside option-1 row.
    _begin_1_row(ctx, Vec2(10.0, 60.0), False, True)
    var c2 = combobox(ctx, String("color"), opts, sel, is_open)
    if not c2:
        _fail("release on option 1 should return True (selection changed)")
    if Int(sel) != 1:
        _fail("release on option 1 should set selected_index = 1")
    if is_open:
        _fail("release on option should close dropdown (is_open = False)")
    ctx.end_frame()


def test_reclick_same_option_no_change() raises:
    """Test 5: clicking the ALREADY-selected option closes dropdown but
    returns False (no change), selected_index unchanged.

    Setup: selected_index = 2, is_open = True. Click option 2 at y=84 (in
    its dropdown rect 72..96). Per M2 bugfix 2026-05-28 (FRAGILE #2):
    header 0..24, option 0 = 24..48, option 1 = 48..72, option 2 = 72..96.
    """
    var ctx = Context()
    var opts = _make_options()
    var sel: Int32 = 2
    var is_open: Bool = True

    # Frame 1: press on option-2 row (y=84 in rect 72..96).
    _begin_1_row(ctx, Vec2(10.0, 84.0), True, False)
    var _ = combobox(ctx, String("color"), opts, sel, is_open)
    ctx.end_frame()

    # Frame 2: release on option-2 row — same as currently selected.
    _begin_1_row(ctx, Vec2(10.0, 84.0), False, True)
    var c2 = combobox(ctx, String("color"), opts, sel, is_open)
    if c2:
        _fail("re-clicking already-selected option should return False")
    if Int(sel) != 2:
        _fail("re-click should not change selected_index")
    if is_open:
        _fail("re-click should still close dropdown")
    ctx.end_frame()


def test_out_of_bounds_selected_index_graceful() raises:
    """Test 6: selected_index out of bounds (-1, or >= len) does NOT crash;
    the header just renders without a selection string. Dropdown still
    works normally — clicking an option heals the bad index.
    """
    var ctx = Context()
    var opts = _make_options()
    var is_open: Bool = False

    # -1 selected_index → header renders empty, no crash.
    var sel_neg: Int32 = -1
    _begin_1_row(ctx, Vec2(500.0, 500.0), False, False)
    var _ = combobox(ctx, String("color"), opts, sel_neg, is_open)
    if Int(sel_neg) != -1:
        _fail("negative selected_index should be left as-is by a no-click frame")
    ctx.end_frame()

    # selected_index >= len(options) → same, header renders empty.
    var sel_big: Int32 = 99
    _begin_1_row(ctx, Vec2(500.0, 500.0), False, False)
    var _ = combobox(ctx, String("color"), opts, sel_big, is_open)
    if Int(sel_big) != 99:
        _fail("oversized selected_index should be left as-is by a no-click frame")
    ctx.end_frame()


def main() raises:
    test_compile_and_basic_call()
    test_combobox_emits_draw_commands()
    test_header_click_toggles_open()
    test_option_click_selects_and_closes()
    test_reclick_same_option_no_change()
    test_out_of_bounds_selected_index_graceful()
    print("PASS: combobox widget smoke tests (6 tests)")
