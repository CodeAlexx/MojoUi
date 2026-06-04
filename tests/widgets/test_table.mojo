"""Smoke tests for `mojoui/widgets/table.mojo`.

Run: `pixi run test-table`

Pure `mojo run`. Header at row 0, data row r at y = (r+1) * row_height.
row_height set to 24. CMD_TEXT count = header titles + populated cells.

Covers:
  1. No columns → no-op, returns input selection.
  2. Render: 3 cols + 2 rows → 3 header + 6 cell = 9 CMD_TEXT.
  3. Empty rows → only the 3 header CMD_TEXT.
  4. Short row leaves trailing columns blank (fewer cells drawn).
  5. Click data row 1 → selected becomes 1.
  6. No interaction keeps selection.
"""

from mojoui.core.types import Vec2
from mojoui.core.context import Context
from mojoui.core.commands import CMD_TEXT
from mojoui.widgets.table import TableColumn, table, TABLE_ROW_NONE


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


def _cols() -> List[TableColumn]:
    var c = List[TableColumn]()
    c.append(TableColumn(String("Name"), 160.0))
    c.append(TableColumn(String("Type"), 100.0))
    c.append(TableColumn(String("Size"), 80.0))
    return c^


def _rows() -> List[List[String]]:
    var rows = List[List[String]]()
    var r0 = List[String]()
    r0.append(String("main.mojo")); r0.append(String("file")); r0.append(String("4 KB"))
    var r1 = List[String]()
    r1.append(String("widgets")); r1.append(String("dir")); r1.append(String("--"))
    rows.append(r0^)
    rows.append(r1^)
    return rows^


def _begin(mut ctx: Context, mouse: Vec2, pressed: Bool, released: Bool) raises:
    ctx.set_default_font(UInt32(1))
    ctx.theme.row_height = Int32(24)
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse.copy(), pressed, released)
    var widths = List[Int32]()
    widths.append(Int32(400))
    ctx.layout_row(widths^, Int32(24))


def test_no_columns_noop() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var empty = List[TableColumn]()
    var before = ctx.commands.byte_count()
    var sel = table(ctx, String("t"), empty, _rows(), Int32(3))
    if sel != Int32(3):
        _fail("no-columns table should return input selection")
    if ctx.commands.byte_count() != before:
        _fail("no-columns table should emit nothing")
    ctx.end_frame()
    print("PASS: test_no_columns_noop")


def test_render_header_and_cells() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    _ = table(ctx, String("t"), _cols(), _rows(), TABLE_ROW_NONE)
    var texts = _count_kind(ctx, Int32(CMD_TEXT))
    # 3 header titles + 2 rows * 3 cells = 9.
    if texts != Int32(9):
        _fail("3 cols + 2 rows should emit 9 CMD_TEXT, got " + String(Int(texts)))
    ctx.end_frame()
    print("PASS: test_render_header_and_cells")


def test_empty_rows_header_only() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var no_rows = List[List[String]]()
    _ = table(ctx, String("t"), _cols(), no_rows, TABLE_ROW_NONE)
    var texts = _count_kind(ctx, Int32(CMD_TEXT))
    if texts != Int32(3):
        _fail("empty rows should emit just 3 header CMD_TEXT, got " + String(Int(texts)))
    ctx.end_frame()
    print("PASS: test_empty_rows_header_only")


def test_short_row_blank_trailing() raises:
    """A row with 1 cell under 3 columns draws only that 1 cell."""
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var rows = List[List[String]]()
    var r = List[String]()
    r.append(String("solo"))
    rows.append(r^)
    _ = table(ctx, String("t"), _cols(), rows, TABLE_ROW_NONE)
    var texts = _count_kind(ctx, Int32(CMD_TEXT))
    # 3 header + 1 cell = 4.
    if texts != Int32(4):
        _fail("short row should draw 3 header + 1 cell = 4, got " + String(Int(texts)))
    ctx.end_frame()
    print("PASS: test_short_row_blank_trailing")


def test_click_selects_row() raises:
    """Header at y 0..24; data row 0 at 24..48; data row 1 at 48..72.
    Click row 1 at y=60."""
    var ctx = Context()
    var sel: Int32 = TABLE_ROW_NONE
    _begin(ctx, Vec2(100.0, 60.0), True, False)
    sel = table(ctx, String("t"), _cols(), _rows(), sel)
    ctx.end_frame()
    _begin(ctx, Vec2(100.0, 60.0), False, True)
    sel = table(ctx, String("t"), _cols(), _rows(), sel)
    ctx.end_frame()
    if sel != Int32(1):
        _fail("clicking data row 1 should select 1, got " + String(sel))
    print("PASS: test_click_selects_row")


def test_no_interaction_keeps_selection() raises:
    var ctx = Context()
    _begin(ctx, Vec2(900.0, 900.0), False, False)
    var sel = table(ctx, String("t"), _cols(), _rows(), Int32(0))
    if sel != Int32(0):
        _fail("no click should keep selection 0, got " + String(sel))
    ctx.end_frame()
    print("PASS: test_no_interaction_keeps_selection")


def main() raises:
    test_no_columns_noop()
    test_render_header_and_cells()
    test_empty_rows_header_only()
    test_short_row_blank_trailing()
    test_click_selects_row()
    test_no_interaction_keeps_selection()
    print("PASS: all 6 table tests")
