"""Smoke tests for `mojoui/core/layout.mojo`.

Run: `pixi run test-layout`
"""

from mojoui.core.layout import (
    LayoutFrame,
    LayoutStack,
    ROW_DEFAULT_H,
    DEFAULT_ROW_PX,
    DEFAULT_COL_PX,
    SPACING_DEFAULT,
)
from mojoui.core.types import Rect, Vec2


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


@always_inline
def _abs_f32(x: Float32) -> Float32:
    if x < 0.0:
        return -x
    return x


def _expect_close(name: String, got: Float32, want: Float32) raises:
    if _abs_f32(got - want) > 0.001:
        _fail(
            String("expected ")
            + name
            + String(" == ")
            + String(want)
            + String(", got ")
            + String(got)
        )


def _expect_eq_i32(name: String, got: Int32, want: Int32) raises:
    if Int32(got) != Int32(want):
        _fail(
            String("expected ")
            + name
            + String(" == ")
            + String(Int(want))
            + String(", got ")
            + String(Int(got))
        )


# ----------------------------------------------------------------------------
# 1) Empty stack depth
# ----------------------------------------------------------------------------

def test_empty_stack_depth() raises:
    var s = LayoutStack()
    _expect_eq_i32("depth() after construction", s.depth(), 0)


# ----------------------------------------------------------------------------
# 2) push grows the stack and stores the body rect
# ----------------------------------------------------------------------------

def test_push_grows_depth_and_stores_body() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 200.0, 100.0))
    _expect_eq_i32("depth() after one push", s.depth(), 1)
    var body = s.frames[0].body.copy()
    _expect_close("body.x", body.x, 0.0)
    _expect_close("body.y", body.y, 0.0)
    _expect_close("body.w", body.w, 200.0)
    _expect_close("body.h", body.h, 100.0)
    # Cursor starts at top-left of body.
    var cur = s.frames[0].cursor.copy()
    _expect_close("cursor.x", cur.x, 0.0)
    _expect_close("cursor.y", cur.y, 0.0)


# ----------------------------------------------------------------------------
# 3) push/pop is balanced
# ----------------------------------------------------------------------------

def test_push_pop_balanced() raises:
    var s = LayoutStack()
    s.push(Rect(10.0, 20.0, 100.0, 50.0))
    _expect_eq_i32("depth() after push", s.depth(), 1)
    s.pop()
    _expect_eq_i32("depth() after pop", s.depth(), 0)


# ----------------------------------------------------------------------------
# 4) row + next: three columns then wrap-to-next-row
# ----------------------------------------------------------------------------

def test_row_three_cols_then_wrap() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 400.0, 200.0))
    var widths = List[Int32]()
    widths.append(100)
    widths.append(50)
    widths.append(50)
    s.row(widths^, 24)
    # First slot: (0, 0, 100, 24).
    var r0 = s.next()
    _expect_close("r0.x", r0.x, 0.0)
    _expect_close("r0.y", r0.y, 0.0)
    _expect_close("r0.w", r0.w, 100.0)
    _expect_close("r0.h", r0.h, 24.0)
    # Second slot: (100 + spacing.x, 0, 50, 24).
    var r1 = s.next()
    _expect_close("r1.x", r1.x, 100.0 + SPACING_DEFAULT)
    _expect_close("r1.y", r1.y, 0.0)
    _expect_close("r1.w", r1.w, 50.0)
    _expect_close("r1.h", r1.h, 24.0)
    # Third slot: (100 + 50 + 2*spacing.x, 0, 50, 24).
    var r2 = s.next()
    _expect_close("r2.x", r2.x, 100.0 + 50.0 + 2.0 * SPACING_DEFAULT)
    _expect_close("r2.y", r2.y, 0.0)
    _expect_close("r2.w", r2.w, 50.0)
    _expect_close("r2.h", r2.h, 24.0)
    # Fourth slot: wraps to next row at (0, 24 + spacing.y, 100, 24)
    # (same widths template re-used per microui auto-wrap behaviour).
    var r3 = s.next()
    _expect_close("r3.x (wrap)", r3.x, 0.0)
    _expect_close("r3.y (wrap)", r3.y, 24.0 + SPACING_DEFAULT)
    _expect_close("r3.w (wrap)", r3.w, 100.0)
    _expect_close("r3.h (wrap)", r3.h, 24.0)


# ----------------------------------------------------------------------------
# 5) begin_column / end_column nest cleanly
# ----------------------------------------------------------------------------

def test_begin_column_end_column_nests() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 300.0, 200.0))
    _expect_eq_i32("outer depth", s.depth(), 1)
    var widths = List[Int32]()
    widths.append(120)
    widths.append(120)
    s.row(widths^, 60)
    # Open a column inside the first slot.
    s.begin_column()
    _expect_eq_i32("depth after begin_column", s.depth(), 2)
    # Inside the column, the inner body is the slot the parent vended.
    var inner_body = s.frames[1].body.copy()
    _expect_close("inner_body.x", inner_body.x, 0.0)
    _expect_close("inner_body.y", inner_body.y, 0.0)
    _expect_close("inner_body.w", inner_body.w, 120.0)
    _expect_close("inner_body.h", inner_body.h, 60.0)
    # Emit a slot inside the column (no widths template → default).
    var inner = s.next()
    _expect_close("inner.x", inner.x, 0.0)
    _expect_close("inner.y", inner.y, 0.0)
    _expect_close("inner.w", inner.w, Float32(DEFAULT_COL_PX))
    _expect_close("inner.h", inner.h, Float32(DEFAULT_ROW_PX))
    # Close the column; depth returns to 1.
    s.end_column()
    _expect_eq_i32("depth after end_column", s.depth(), 1)


# ----------------------------------------------------------------------------
# 6) _compute_col_width resolves positive / zero / negative correctly
# ----------------------------------------------------------------------------

def test_compute_col_width_rules() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 200.0, 100.0))
    # widths = [0, 100, -1] — col 0 default, col 1 fixed, col 2 default (M1).
    var widths = List[Int32]()
    widths.append(0)
    widths.append(100)
    widths.append(-1)
    s.row(widths^, 0)
    # col_index = 0 → width 0 → DEFAULT_COL_PX.
    var r0 = s.next()
    _expect_close("col 0 width (0→default)", r0.w, Float32(DEFAULT_COL_PX))
    # col_index = 1 → width 100 → 100.
    var r1 = s.next()
    _expect_close("col 1 width (100→fixed)", r1.w, 100.0)
    # col_index = 2 → width -1 → DEFAULT_COL_PX (M1 simplification).
    var r2 = s.next()
    _expect_close("col 2 width (-1→default in M1)", r2.w, Float32(DEFAULT_COL_PX))


# ----------------------------------------------------------------------------
# 7) _compute_row_height resolves 0 → default, >0 → fixed
# ----------------------------------------------------------------------------

def test_compute_row_height_rules() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 200.0, 200.0))
    # row_height = 0 → default.
    var widths0 = List[Int32]()
    widths0.append(50)
    s.row(widths0^, 0)
    var r0 = s.next()
    _expect_close("row_height 0 → default", r0.h, Float32(DEFAULT_ROW_PX))
    # New row with explicit height = 30.
    var widths1 = List[Int32]()
    widths1.append(50)
    s.row(widths1^, 30)
    var r1 = s.next()
    _expect_close("row_height 30 → 30", r1.h, 30.0)


# ----------------------------------------------------------------------------
# 8) row() called mid-row resets col_index and starts the new row at the
#    bottom of the previous one (snapped via implicit _row_end).
# ----------------------------------------------------------------------------

def test_row_resets_col_index_mid_row() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 400.0, 200.0))
    # First row: 3 cols of width 50, height 24. Emit just 2, then change rows.
    var widths_a = List[Int32]()
    widths_a.append(50)
    widths_a.append(50)
    widths_a.append(50)
    s.row(widths_a^, 24)
    _ = s.next()
    _ = s.next()
    # Frame's col_index should now be 2 (mid-row).
    _expect_eq_i32("col_index after 2 nexts", s.frames[0].col_index, 2)
    # New row: 1 col of width 80, default height. Should snap cursor down
    # and reset col_index.
    var widths_b = List[Int32]()
    widths_b.append(80)
    s.row(widths_b^, 0)
    _expect_eq_i32("col_index after new row", s.frames[0].col_index, 0)
    # First slot of the new row: x = body.x = 0, y = 24 + spacing.y,
    # w = 80, h = DEFAULT_ROW_PX.
    var r0 = s.next()
    _expect_close("new row r0.x", r0.x, 0.0)
    _expect_close("new row r0.y", r0.y, 24.0 + SPACING_DEFAULT)
    _expect_close("new row r0.w", r0.w, 80.0)
    _expect_close("new row r0.h", r0.h, Float32(DEFAULT_ROW_PX))


# ----------------------------------------------------------------------------
# 9) reset() empties the stack between frames
# ----------------------------------------------------------------------------

def test_reset_empties_stack() raises:
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 100.0, 100.0))
    s.push(Rect(10.0, 10.0, 80.0, 80.0))
    _expect_eq_i32("depth before reset", s.depth(), 2)
    s.reset()
    _expect_eq_i32("depth after reset", s.depth(), 0)


# ----------------------------------------------------------------------------
# 10) Three-level deep nesting (GAP #2 from SKEPTIC_FINDINGS_M1_2026-05-28.md)
#     Verifies depth tracking, cursor positioning, and balanced close.
# ----------------------------------------------------------------------------

def test_three_level_deep_nesting() raises:
    """Push a root frame, open two nested columns (depth 3), emit a slot,
    then end both columns and pop. Verifies depth changes at each step,
    the inner-most slot is positioned correctly (cursor accounting
    through 3 levels), and all closes balance back to depth 0.

    Layout structure:
        root (0,0,400,300) push
          row [200] of height 100
            begin_column → inner1 body = (0,0,200,100), depth=2
              row [150] of height 60
                begin_column → inner2 body = (0,0,150,60), depth=3
                  next() → inner-most slot at (0,0,DEFAULT_COL_PX,DEFAULT_ROW_PX)
                end_column → depth=2
            end_column → depth=1
        pop → depth=0
    """
    var s = LayoutStack()
    s.push(Rect(0.0, 0.0, 400.0, 300.0))
    _expect_eq_i32("L0 depth after root push", s.depth(), 1)

    # Level 1: row of one 200×100 slot.
    var widths_outer = List[Int32]()
    widths_outer.append(200)
    s.row(widths_outer^, 100)

    # Open level-2 column inside the parent's first slot.
    s.begin_column()
    _expect_eq_i32("L1 depth after first begin_column", s.depth(), 2)
    var l1_body = s.frames[1].body.copy()
    _expect_close("L1 body.x", l1_body.x, 0.0)
    _expect_close("L1 body.y", l1_body.y, 0.0)
    _expect_close("L1 body.w", l1_body.w, 200.0)
    _expect_close("L1 body.h", l1_body.h, 100.0)

    # Level 2: row of one 150×60 slot.
    var widths_mid = List[Int32]()
    widths_mid.append(150)
    s.row(widths_mid^, 60)

    # Open level-3 column inside that slot.
    s.begin_column()
    _expect_eq_i32("L2 depth after second begin_column", s.depth(), 3)
    var l2_body = s.frames[2].body.copy()
    _expect_close("L2 body.x", l2_body.x, 0.0)
    _expect_close("L2 body.y", l2_body.y, 0.0)
    _expect_close("L2 body.w", l2_body.w, 150.0)
    _expect_close("L2 body.h", l2_body.h, 60.0)

    # Innermost slot — no widths template, so defaults apply.
    var inner = s.next()
    _expect_close("inner.x", inner.x, 0.0)
    _expect_close("inner.y", inner.y, 0.0)
    _expect_close("inner.w", inner.w, Float32(DEFAULT_COL_PX))
    _expect_close("inner.h", inner.h, Float32(DEFAULT_ROW_PX))

    # Close level-3, then level-2, then pop root — depth balances back.
    s.end_column()
    _expect_eq_i32("depth after first end_column", s.depth(), 2)
    s.end_column()
    _expect_eq_i32("depth after second end_column", s.depth(), 1)
    s.pop()
    _expect_eq_i32("depth after root pop", s.depth(), 0)


def main() raises:
    test_empty_stack_depth()
    test_push_grows_depth_and_stores_body()
    test_push_pop_balanced()
    test_row_three_cols_then_wrap()
    test_begin_column_end_column_nests()
    test_compute_col_width_rules()
    test_compute_row_height_rules()
    test_row_resets_col_index_mid_row()
    test_reset_empties_stack()
    test_three_level_deep_nesting()
    print("PASS: layout smoke tests (10 tests)")
