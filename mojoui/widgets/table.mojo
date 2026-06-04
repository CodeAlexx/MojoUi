"""Data table widget — header row + selectable data rows in columns.

A simple grid: a header row of column titles followed by data rows, each a
list of cell strings. Exactly one data row can be selected. Caller owns the
`selected_row` index (microui convention). Cell content is caller-formatted
strings — the table does no type formatting.

    var cols = List[TableColumn]()
    cols.append(TableColumn(String("Name"), 160.0))
    cols.append(TableColumn(String("Type"), 100.0))
    cols.append(TableColumn(String("Size"), 80.0))
    var rows = List[List[String]]()
    rows.append([String("main.mojo"), String("file"), String("4 KB")])
    rows.append([String("widgets"),   String("dir"),  String("--")])
    var selected: Int32 = -1
    selected = table(ctx, String("files"), cols, rows, selected)

Layout: like `tree`/`popup`, takes ONE `layout_next()` slot for top-left +
(ignored) width, and lays the header + data rows downward at
`theme.row_height` each. Column widths come from `TableColumn.width`; the
table's total width is the sum of column widths. Vertical space is the
caller's responsibility (height isn't fed back to the layout cursor).

Interaction: clicking a data row selects it (returns the new selection).
`selected_row == -1` means no selection. A row index past the data is
simply never highlighted (harmless if rows shrink under a stale index).

`.copy()` discipline per MOJO_NOTES.md.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_HOVERED, CTRL_RELEASED, OPT_NONE


comptime _HEADER_UNDERLINE_H: Float32 = 2.0
"""Thickness of the line under the header row (px)."""

comptime TABLE_ROW_NONE: Int32 = -1
"""Sentinel for 'no row selected'."""


struct TableColumn(Copyable, Movable):
    """One column: a header `title` and a fixed pixel `width`."""

    var title: String
    var width: Float32

    def __init__(out self, title: String, width: Float32):
        self.title = title.copy()
        self.width = width


def _total_width(columns: List[TableColumn]) -> Float32:
    var w: Float32 = 0.0
    for i in range(len(columns)):
        w = w + columns[i].width
    return w


def table(
    mut ctx: Context,
    id_str: String,
    columns: List[TableColumn],
    rows: List[List[String]],
    selected_row: Int32,
) -> Int32:
    """Render a header + data rows; return the selected row index.

    Args:
        ctx:          Per-frame Context.
        id_str:       Id seed; per-row ids derive under it.
        columns:      Column titles + widths.
        rows:         Row-major cell strings. A short row (fewer cells than
                      columns) just leaves trailing columns blank.
        selected_row: Currently-selected data-row index, or
                      `TABLE_ROW_NONE`. Clicking a row returns its index.

    Returns: the selected row index after this frame.
    """
    var n_cols = len(columns)
    if n_cols == 0:
        return selected_row

    ctx.push_id_str(id_str)
    var origin = ctx.layout_next()
    var row_h = Float32(ctx.theme.row_height)
    var pad = Float32(ctx.theme.padding)
    var table_w = _total_width(columns)
    var result = selected_row

    # ---- Header row ----
    var header_rect = Rect(origin.x, origin.y, table_w, row_h)
    ctx.draw_rect(header_rect.copy(), ctx.theme.active_bg.copy())
    if ctx.theme.font_id != 0:
        var hx = origin.x
        var hy = origin.y + (row_h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5
        for c in range(n_cols):
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                Vec2(hx + pad, hy),
                ctx.theme.text.copy(),
                columns[c].title,
            )
            hx = hx + columns[c].width
    # Header underline.
    ctx.draw_rect(
        Rect(origin.x, origin.y + row_h - _HEADER_UNDERLINE_H, table_w, _HEADER_UNDERLINE_H),
        ctx.theme.border.copy(),
    )

    # ---- Data rows ----
    var n_rows = len(rows)
    for r in range(n_rows):
        var row_y = origin.y + Float32(r + 1) * row_h
        var row_rect = Rect(origin.x, row_y, table_w, row_h)
        var row_id = ctx.get_id(String(r))
        var flags = ctx.update_control(row_id, row_rect.copy(), OPT_NONE)
        if (flags & CTRL_RELEASED) != 0:
            result = Int32(r)

        # Row background: selected > hovered > none.
        if result == Int32(r):
            ctx.draw_rect(row_rect.copy(), ctx.theme.active_bg.copy())
        elif (flags & CTRL_HOVERED) != 0:
            ctx.draw_rect(row_rect.copy(), ctx.theme.hover_bg.copy())

        if ctx.theme.font_id != 0:
            var cx = origin.x
            var cy = row_y + (row_h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5
            var n_cells = len(rows[r])
            for c in range(n_cols):
                if c < n_cells:
                    ctx.draw_text(
                        ctx.theme.font_id,
                        ctx.theme.font_size_pt,
                        Vec2(cx + pad, cy),
                        ctx.theme.text.copy(),
                        rows[r][c],
                    )
                cx = cx + columns[c].width

    ctx.pop_id()
    return result
