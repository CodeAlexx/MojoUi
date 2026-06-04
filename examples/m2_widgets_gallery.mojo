"""MojoUI M2 capstone — kitchen-sink widget gallery.

Static single-frame walk-through exercising every M2 widget. Simulates one
frame with the mouse at (0,0) (outside the gallery window) so every widget
remains in its default visual state. Emits all 14+ widgets inside a
`begin_window`/`end_window`, then walks the command buffer and prints
command counts per `CMD_*` kind plus a PASS line.

Run via `pixi run gallery`. The task BUILDS to a binary (NOT `mojo run` /
JIT) for the same reason `m1_button.mojo` does — see MOJO_NOTES.md "mojo
run (JIT) does NOT dlopen the shared library" + c18 JIT-eager-
materialisation. `text_edit`/`text_area`/`combobox` all reach FFI symbols
from their static call graph; building against `libmojoui_floor.so`
resolves them at link time. No live window, no `Backend.run_blocking` —
runtime visual gate deferred (GPU busy + module-level frame-callback
state unresolved per MOJO_NOTES.md).
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_NONE,
    CMD_JUMP,
    CMD_CLIP,
    CMD_RECT,
    CMD_TEXT,
    CMD_ICON,
    CMD_IMAGE,
    CMD_CUSTOM,
)
from mojoui.widgets.basic import button, label, separator
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.radio import radio
from mojoui.widgets.slider import slider
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.progress_bar import progress_bar
from mojoui.widgets.text_edit import text_edit
from mojoui.core.textedit import TextEditState
from mojoui.core.multiline_edit import MultiLineState
from mojoui.widgets.text_area import text_area
from mojoui.widgets.combobox import combobox
from mojoui.widgets.collapsing_header import collapsing_header
from mojoui.widgets.image import image
from mojoui.widgets.scroll_area import begin_scroll_area, end_scroll_area
from mojoui.widgets.window_panel import begin_window, end_window
from mojoui.widgets.tab_bar import tab_bar
from mojoui.widgets.tree import TreeItem, TreeState, tree_view, TREE_ID_NONE
from mojoui.widgets.table import TableColumn, table, TABLE_ROW_NONE


# ---------------------------------------------------------------------------
# Gallery scene state — owned by `main()`, threaded through `_emit_frame`.
# Every widget that takes a `mut`-reference parameter (checkbox, radio,
# slider, drag_value, text_edit, text_area, combobox, collapsing_header,
# scroll_area, window_panel) needs caller-owned storage; this struct
# centralises it. Mirrors the egui `DemoApp` / microui `style_window`
# state-blob convention.
# ---------------------------------------------------------------------------


struct GalleryState:
    var button_a_clicks: Int32
    var button_b_clicks: Int32
    var bold: Bool
    var italic: Bool
    var fruit: Int32        # 1=apple, 2=banana, 3=cherry
    var gain: Float32
    var cfg: Float32
    var progress: Float32
    var texture_id: UInt32
    var name_buffer: String
    var name_edit_state: TextEditState
    var notes_buffer: String
    var notes_edit_state: MultiLineState
    var sampler_options: List[String]
    var sampler_index: Int32
    var combo_open: Bool
    var advanced_open: Bool
    var use_experimental: Bool
    var warn_on_cancel: Bool
    var scroll_y: Float32
    var window_rect: Rect
    # Advanced widgets folded into the kitchen sink (tab_bar / tree / table).
    var adv_tabs: List[String]
    var adv_tab: Int32
    var tree_items: List[TreeItem]
    var tree_state: TreeState
    var tcols: List[TableColumn]
    var trows: List[List[String]]
    var table_selected: Int32

    def __init__(out self):
        self.button_a_clicks = 0
        self.button_b_clicks = 0
        self.bold = True
        self.italic = False
        self.fruit = 2
        self.gain = 0.6
        self.cfg = 7.5
        self.progress = 0.42
        # texture_id 0 = built-in 1x1 white (see MAP.md §5 gotchas) — safe
        # to draw without a real upload; the renderer will sample white.
        self.texture_id = UInt32(0)
        self.name_buffer = String("user")
        self.name_edit_state = TextEditState(single_line=True)
        self.notes_buffer = String("first line\nsecond line")
        self.notes_edit_state = MultiLineState()
        self.notes_edit_state.set_text(self.notes_buffer)
        var opts = List[String]()
        opts.append(String("euler"))
        opts.append(String("dpm++"))
        opts.append(String("ddim"))
        self.sampler_options = opts^
        self.sampler_index = 0
        self.combo_open = False
        self.advanced_open = True
        self.use_experimental = False
        self.warn_on_cancel = True
        self.scroll_y = 0.0
        self.window_rect = Rect(20.0, 20.0, 760.0, 540.0)

        var atabs = List[String]()
        atabs.append(String("Tree"))
        atabs.append(String("Table"))
        self.adv_tabs = atabs^
        self.adv_tab = 0

        var items = List[TreeItem]()
        items.append(TreeItem(Int64(1), String("mojoui"), Int32(0), True))
        items.append(TreeItem(Int64(2), String("core"), Int32(1), True))
        items.append(TreeItem(Int64(3), String("context.mojo"), Int32(2), False))
        items.append(TreeItem(Int64(4), String("widgets"), Int32(1), False))
        items.append(TreeItem(Int64(5), String("README.md"), Int32(0), False))
        self.tree_items = items^
        var ts = TreeState()
        ts.set_expanded(Int64(1), True)
        ts.set_expanded(Int64(2), True)
        self.tree_state = ts^

        var cols = List[TableColumn]()
        cols.append(TableColumn(String("Widget"), 180.0))
        cols.append(TableColumn(String("Status"), 120.0))
        self.tcols = cols^
        var rows = List[List[String]]()
        var rr0 = List[String]()
        rr0.append(String("tree")); rr0.append(String("done"))
        rows.append(rr0^)
        var rr1 = List[String]()
        rr1.append(String("table")); rr1.append(String("done"))
        rows.append(rr1^)
        var rr2 = List[String]()
        rr2.append(String("tab_bar")); rr2.append(String("done"))
        rows.append(rr2^)
        self.trows = rows^
        self.table_selected = TABLE_ROW_NONE


# ---------------------------------------------------------------------------
# Helpers to construct fresh `List[Int32]` row widths each call. `layout_row`
# takes `var widths: List[Int32]` (by-move ownership per c13 finding) so we
# can't reuse a single list across rows; each call needs a fresh list.
# ---------------------------------------------------------------------------


def _row1(a: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    return w^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    return w^


def _row3(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    return w^


def _row4(a: Int32, b: Int32, c: Int32, d: Int32) -> List[Int32]:
    var w = List[Int32]()
    w.append(a)
    w.append(b)
    w.append(c)
    w.append(d)
    return w^


# ---------------------------------------------------------------------------
# Single-frame emit. Every widget appears exactly once except `button` (twice:
# Button A + Button B) and `checkbox` (4 times: bold/italic + the two
# advanced-section toggles + radio group implicit) — that's intentional, the
# point is to exercise EACH widget API at least once. Mouse is at (0,0)
# (outside the window rect 20..780 / 20..560) so no widget claims hover
# this frame.
# ---------------------------------------------------------------------------


def _emit_gallery_frame(mut ctx: Context, mut state: GalleryState) raises:
    """Emit every widget in one frame inside a draggable window."""
    _ = begin_window(
        ctx, String("gallery"), String("MojoUI M2 Gallery"),
        state.window_rect,
    )

    # ----- Basic widgets: button + label + checkbox + separator -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Basic widgets =="))
    ctx.layout_row(_row4(180, 180, 180, 180), 32)
    if button(ctx, String("Button A")):
        state.button_a_clicks = state.button_a_clicks + 1
    if button(ctx, String("Button B")):
        state.button_b_clicks = state.button_b_clicks + 1
    _ = checkbox(ctx, String("Bold"), state.bold)
    _ = checkbox(ctx, String("Italic"), state.italic)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Radio group -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Radio group =="))
    ctx.layout_row(_row3(200, 200, 200), 28)
    _ = radio(ctx, String("Apple"), Int32(1), state.fruit)
    _ = radio(ctx, String("Banana"), Int32(2), state.fruit)
    _ = radio(ctx, String("Cherry"), Int32(3), state.fruit)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Numeric: slider + drag_value -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Numeric =="))
    ctx.layout_row(_row2(400, 200), 28)
    _ = slider(ctx, state.gain, 0.0, 1.0, String("gain"))
    _ = drag_value(ctx, state.cfg, String("cfg"), 0.1)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Progress + image -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Progress + image =="))
    ctx.layout_row(_row2(400, 200), 24)
    progress_bar(ctx, state.progress)
    image(ctx, state.texture_id)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Text input: text_edit + text_area -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Text input =="))
    ctx.layout_row(_row1(700), 28)
    _ = text_edit(ctx, String("name_input"), state.name_buffer, state.name_edit_state)
    ctx.layout_row(_row1(700), 80)
    _ = text_area(ctx, String("notes_area"), state.notes_buffer, state.notes_edit_state)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Combo + collapsing -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Combo + collapsing =="))
    ctx.layout_row(_row2(350, 350), 28)
    _ = combobox(
        ctx, String("sampler"), state.sampler_options,
        state.sampler_index, state.combo_open,
    )
    if collapsing_header(ctx, String("Advanced settings"), state.advanced_open):
        ctx.layout_row(_row1(700), 24)
        _ = checkbox(ctx, String("Use experimental"), state.use_experimental)
        ctx.layout_row(_row1(700), 24)
        _ = checkbox(ctx, String("Warn on cancel"), state.warn_on_cancel)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Scroll area: 20 buttons inside a 120-px-tall viewport -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Scroll area (20 items) =="))
    _ = begin_scroll_area(ctx, String("scroll"), Int32(120), state.scroll_y)
    for i in range(20):
        ctx.layout_row(_row1(680), 22)
        _ = button(ctx, String("Scrolled item ") + String(i))
    end_scroll_area(ctx)
    ctx.layout_row(_row1(700), 4)
    separator(ctx)

    # ----- Advanced widgets: tab_bar selecting between tree + table -----
    ctx.layout_row(_row1(700), 24)
    label(ctx, String("== Advanced (tab_bar / tree / table) =="))
    ctx.layout_row(_row1(700), 28)
    state.adv_tab = tab_bar(
        ctx, String("adv_tabs"), state.adv_tabs, Float32(90.0), state.adv_tab
    )
    if state.adv_tab == Int32(0):
        ctx.layout_row(_row1(700), 120)
        _ = tree_view(ctx, String("gallery_tree"), state.tree_items, state.tree_state)
    else:
        ctx.layout_row(_row1(700), 120)
        state.table_selected = table(
            ctx, String("gallery_table"), state.tcols, state.trows, state.table_selected
        )

    end_window(ctx)


# ---------------------------------------------------------------------------
# Command-buffer walker. Counts each `CMD_*` kind. JUMP follows
# `read_jump_dst` (per c12/c18 walker contract) with a forward-progress
# guard so a malformed self-loop doesn't hang the gate.
# ---------------------------------------------------------------------------


def _count_by_kind(ctx: Context) -> List[Int]:
    """Walk `ctx.commands`. Returns a length-8 list indexed by `CMD_*`.

    Index layout:
        [0] CMD_NONE   (should be 0 in a well-formed buffer)
        [1] CMD_JUMP
        [2] CMD_CLIP
        [3] CMD_RECT
        [4] CMD_TEXT
        [5] CMD_ICON
        [6] CMD_IMAGE
        [7] CMD_CUSTOM (reserved — should be 0)
    """
    var counts = List[Int]()
    for _ in range(8):
        counts.append(0)
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    var prev_off: Int32 = -1
    while off < end_off:
        if off <= prev_off:
            print("ABORT: walker not progressing at offset", Int(off))
            return counts^
        prev_off = off
        var kind = ctx.commands.kind_at(off)
        var size = ctx.commands.size_at(off)
        var k = Int(kind)
        if k >= 0 and k < 8:
            counts[k] = counts[k] + 1
        if kind == CMD_JUMP:
            off = ctx.commands.read_jump_dst(off)
            continue
        off = off + size
    return counts^


def main() raises:
    """Build the gallery scene, walk the command buffer, print PASS line.

    No `Backend.run_blocking`, no `begin_frame` (which polls FFI input).
    `begin_frame_no_input` threads mouse_pos=(0,0), pressed=False,
    released=False so every widget stays in its default visual state and
    no FFI symbols need to materialise at JIT time (this binary is built,
    but the same code under `mojo run` would also work for the no-FFI-
    reaching widgets — the gated FFI calls inside `text_edit`/`text_area`/
    `combobox` are what require the build path).
    """
    var ctx = Context()
    # c10 deterministic-FFI trick: id 1 is what `mojoui_load_font(NULL)`
    # would return in a live window. Static demo doesn't load fonts (no GL
    # context), but plumbing a non-zero id through makes CMD_TEXT records
    # look realistic for the walker counts.
    ctx.set_default_font(UInt32(1))

    var state = GalleryState()

    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False,
    )
    _emit_gallery_frame(ctx, state)
    ctx.end_frame()

    var byte_count = ctx.commands.byte_count()
    var counts = _count_by_kind(ctx)
    print("M2 gallery emitted", byte_count, "bytes of commands")
    print("  CMD_NONE:   ", counts[Int(CMD_NONE)])
    print("  CMD_JUMP:   ", counts[Int(CMD_JUMP)])
    print("  CMD_CLIP:   ", counts[Int(CMD_CLIP)])
    print("  CMD_RECT:   ", counts[Int(CMD_RECT)])
    print("  CMD_TEXT:   ", counts[Int(CMD_TEXT)])
    print("  CMD_ICON:   ", counts[Int(CMD_ICON)])
    print("  CMD_IMAGE:  ", counts[Int(CMD_IMAGE)])
    print("  CMD_CUSTOM: ", counts[Int(CMD_CUSTOM)])

    # Gate assertions: every widget must have emitted SOMETHING. The
    # weakest invariant is non-empty command buffer + at least one rect
    # and one text command. JUMP and CLIP come from window_panel +
    # scroll_area; IMAGE comes from the lone `image()` call.
    if byte_count <= 0:
        print("FAIL: command buffer is empty")
        raise Error("empty command buffer")
    if counts[Int(CMD_RECT)] == 0:
        print("FAIL: no CMD_RECT commands emitted")
        raise Error("no rect commands")
    if counts[Int(CMD_TEXT)] == 0:
        print("FAIL: no CMD_TEXT commands emitted")
        raise Error("no text commands")
    if counts[Int(CMD_JUMP)] == 0:
        print("FAIL: no CMD_JUMP command emitted (window_panel missing?)")
        raise Error("no jump commands")
    if counts[Int(CMD_CLIP)] == 0:
        print("FAIL: no CMD_CLIP commands emitted (scroll_area missing?)")
        raise Error("no clip commands")
    if counts[Int(CMD_IMAGE)] == 0:
        print("FAIL: no CMD_IMAGE command emitted (image widget missing?)")
        raise Error("no image commands")

    print("PASS: M2 widget gallery exercised 14+ widgets in one static frame")
