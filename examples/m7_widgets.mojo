"""MojoUI m7 — advanced widgets demo (tab bar / tree view / data table).

A top tab bar switches between three panels:
  - "Tree"  — a collapsible file-tree (click a parent to expand/collapse,
              click any row to select it).
  - "Table" — a data table of the widgets shipped this session; click a row
              to select it.
  - "About" — a short text panel.

The bottom status line reports the current selection in each panel.

Build + run: `pixi run widgets`. Build-then-run scaffold (FFI input symbols
the JIT cannot dlopen), same as kitchen/menus/nodegraph.
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_RECT, CMD_TEXT, CMD_TRIANGLES,
    CmdTriangles, read_cmd_rect, read_cmd_text, read_cmd_triangles,
)
from mojoui.render.backend import Backend
from mojoui.widgets.tab_bar import tab_bar
from mojoui.widgets.tree import TreeItem, TreeState, tree_view, TREE_ID_NONE
from mojoui.widgets.table import TableColumn, table, TABLE_ROW_NONE
from mojoui.app.state import store_user_state, retrieve_user_state


comptime _TAB_H: Float32 = 36.0


struct WidgetsDemoState(Movable):
    var ctx: Context
    var tabs: List[String]
    var active_tab: Int32
    var tree_items: List[TreeItem]
    var tree_state: TreeState
    var tcols: List[TableColumn]
    var trows: List[List[String]]
    var table_selected: Int32
    var font_id: UInt32

    def __init__(out self):
        self.ctx = Context()

        var tabs = List[String]()
        tabs.append(String("Tree"))
        tabs.append(String("Table"))
        tabs.append(String("About"))
        self.tabs = tabs^
        self.active_tab = 0

        var items = List[TreeItem]()
        items.append(TreeItem(Int64(1), String("mojoui"), Int32(0), True))
        items.append(TreeItem(Int64(2), String("core"), Int32(1), True))
        items.append(TreeItem(Int64(3), String("context.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(4), String("layout.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(5), String("widgets"), Int32(1), True))
        items.append(TreeItem(Int64(6), String("tab_bar.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(7), String("tree.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(8), String("table.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(9), String("README.md"), Int32(0), False))
        self.tree_items = items^

        var ts = TreeState()
        ts.set_expanded(Int64(1), True)
        ts.set_expanded(Int64(5), True)
        self.tree_state = ts^

        var cols = List[TableColumn]()
        cols.append(TableColumn(String("Widget"), 200.0))
        cols.append(TableColumn(String("Tests"), 90.0))
        cols.append(TableColumn(String("Status"), 140.0))
        self.tcols = cols^

        var rows = List[List[String]]()
        var make = List[String]()
        make.append(String("tab_bar")); make.append(String("5")); make.append(String("done"))
        rows.append(make^)
        var r2 = List[String]()
        r2.append(String("tree")); r2.append(String("6")); r2.append(String("done"))
        rows.append(r2^)
        var r3 = List[String]()
        r3.append(String("table")); r3.append(String("6")); r3.append(String("done"))
        rows.append(r3^)
        var r4 = List[String]()
        r4.append(String("context_menu")); r4.append(String("-")); r4.append(String("done"))
        rows.append(r4^)
        var r5 = List[String]()
        r5.append(String("progress badge")); r5.append(String("6")); r5.append(String("done"))
        rows.append(r5^)
        self.trows = rows^
        self.table_selected = TABLE_ROW_NONE

        self.font_id = 0


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                return
            continue
        var size = ctx.commands.size_at(off)
        if kind == CMD_RECT:
            var cmd = read_cmd_rect(ctx.commands, off)
            Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(ctx.commands, off)
            _ = Backend.draw_text(
                cmd.font_id, cmd.size_pt, cmd.text,
                cmd.pos.copy(), cmd.color.copy(),
            )
        elif kind == CMD_TRIANGLES:
            var cmd = read_cmd_triangles(ctx.commands, off)
            _dispatch_triangles(cmd)
        off = off + size


def _ui(mut s: WidgetsDemoState, win_w: Float32, win_h: Float32) raises:
    ref ctx = s.ctx

    var status = String("about")

    # ---- Panel row ----
    var pr = List[Int32]()
    pr.append(Int32(Int(win_w)))
    ctx.layout_row(pr^, Int32(Int(win_h - _TAB_H)))

    if s.active_tab == Int32(0):
        _ = tree_view(ctx, String("file_tree"), s.tree_items, s.tree_state)
        status = String("tree: selected id ") + String(s.tree_state.selected)
    elif s.active_tab == Int32(1):
        s.table_selected = table(
            ctx, String("widget_table"), s.tcols, s.trows, s.table_selected
        )
        status = String("table: selected row ") + String(s.table_selected)
    else:
        if ctx.theme.font_id != 0:
            ctx.draw_text(
                ctx.theme.font_id, Int32(18),
                Vec2(Float32(20.0), _TAB_H + Float32(50.0)),
                ctx.theme.text.copy(),
                String("MojoUI advanced widgets: tab_bar, tree, table."),
            )
            ctx.draw_text(
                ctx.theme.font_id, Int32(16),
                Vec2(Float32(20.0), _TAB_H + Float32(84.0)),
                Color(170, 175, 190, 255),
                String("All pure-Mojo, headless-tested. Click the Tree / Table tabs."),
            )

    # ---- Status line ----
    if ctx.theme.font_id != 0:
        ctx.draw_text(
            ctx.theme.font_id, Int32(16),
            Vec2(Float32(12.0), win_h - Float32(12.0)),
            Color(150, 200, 160, 255),
            status,
        )


def _frame() -> None:
    var sp = retrieve_user_state[WidgetsDemoState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
        sp[].ctx.theme.font_size_pt = Int32(16)
        sp[].ctx.theme.row_height = Int32(28)
        sp[].ctx.theme.padding = Int32(8)
        sp[].ctx.theme.spacing = Int32(6)

    var win_w = Float32(1200.0)
    var win_h = Float32(800.0)
    sp[].ctx.begin_frame(Vec2(win_w, win_h))
    Backend.frame_begin(Color(18, 18, 22, 255))

    try:
        _ui(sp[], win_w, win_h)
    except e:
        print("MojoUI m7 UI error:", String(e))

    sp[].ctx.end_frame()
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m7 walker error:", String(e))
    Backend.frame_end()


def main() raises:
    var state = WidgetsDemoState()
    var sp = UnsafePointer(to=state)
    store_user_state(sp)

    var rc = Backend.init(Int32(1200), Int32(800), String("MojoUI m7 — Widgets"))
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening widgets demo — click the Tree / Table / About tabs.")
    Backend.run_blocking(_frame)
    # Reference `state` AFTER run_blocking so Mojo's ASAP destruction does
    # NOT free the stack-allocated state (and the pointer the frame callback
    # holds) early. Without a post-run use the struct is destroyed right
    # after UnsafePointer(to=state), dangling the callback's pointer.
    print("PASS: m7 widgets exited cleanly. active_tab=", state.active_tab)
