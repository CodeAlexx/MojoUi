"""MojoUI m4 — live kitchen-sink demo (interactive).

Combines the m2_widgets_gallery widget set (button, label, checkbox, radio,
slider, drag_value, progress_bar, text_edit, text_area, combobox,
collapsing_header, separator) with the m3_interactive_demo live-loop
infrastructure (Backend.init, store_user_state, run_blocking, lazy font
load, command-buffer walker).

Build + run: `pixi run kitchen`. Build-then-run (NOT `mojo run`) because
text_edit/text_area/combobox reach FFI symbols the JIT can't dlopen.
Extra `-Xlinker -lm` for tessellator sin/cos. Close the window to exit.
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_CLIP, CMD_RECT, CMD_TEXT, CMD_ICON, CMD_IMAGE,
    CMD_TRIANGLES,
    CmdTriangles,
    read_cmd_rect, read_cmd_text, read_cmd_triangles,
)
from mojoui.render.backend import Backend
from mojoui.theme.tokens import Theme
from mojoui.theme.themes import dark_theme, light_theme, high_contrast_theme
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
from mojoui.app.state import store_user_state, retrieve_user_state


struct KitchenState(Movable):
    """Persistent state for every widget AND the Context itself. Stack-
    allocated in main(); pointer stashed via c50 store_user_state before
    run_blocking. Crucially `ctx` lives ACROSS frames so InputState's
    edge detector (prev_held vs cur_held) and ControlState's active/focus
    slots survive — otherwise CTRL_RELEASED never fires and checkboxes,
    buttons, comboboxes silently swallow every click.
    """

    var ctx: Context              # persistent across frames (key bug fix)
    var counter: Int32
    var theme_idx: Int32
    var bold: Bool
    var italic: Bool
    var fruit: Int32              # 1=apple, 2=banana, 3=cherry
    var gain: Float32             # slider 0..1
    var cfg: Float32              # drag_value
    var progress: Float32         # progress_bar 0..1
    var progress_dir: Float32     # +/- per frame for animated progress
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
    var font_id: UInt32           # 0 until first-frame lazy-load
    var blink_frame: Int32        # frame counter driving caret blink

    def __init__(out self):
        self.ctx = Context()
        self.counter = 0
        self.blink_frame = 0
        self.theme_idx = 0
        self.bold = True
        self.italic = False
        self.fruit = 2
        self.gain = 0.6
        self.cfg = 7.5
        self.progress = 0.42
        self.progress_dir = 0.005
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
        self.font_id = 0


def _theme_for_index(idx: Int32) -> Theme:
    if idx == 1:
        return light_theme()
    elif idx == 2:
        return high_contrast_theme()
    return dark_theme()


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


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    """Walks ctx.commands; dispatches RECT/TEXT/TRIANGLES to Backend.
    CMD_CLIP / CMD_ICON / CMD_IMAGE skipped (no live backend path)."""
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                print("MojoUI m4: non-forward JUMP at", Int(prev_off))
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


def _frame() -> None:
    """sokol_app frame callback. Recover state (incl. persistent Context),
    build one immediate-mode frame with all 12+ widgets, walk command
    buffer, present.
    """
    var state_ptr = retrieve_user_state[KitchenState]()

    if state_ptr[].font_id == 0:
        state_ptr[].font_id = Backend.load_font(String(""))
        # First-frame theme bump for 4K legibility: larger default font +
        # roomier rows. Done once after font_id is known so all subsequent
        # frames use these settings. font_size_pt MUST be one of the C
        # floor's pre-baked sizes (12/14/16/18/24 per c_floor/mojoui_fonts.c
        # g_size_table) — asking for 22 returns NULL atlas and draw_text
        # silently no-ops, so use 24.
        state_ptr[].ctx.theme.font_id = state_ptr[].font_id
        state_ptr[].ctx.theme.font_size_pt = Int32(24)
        state_ptr[].ctx.theme.row_height = Int32(40)
        state_ptr[].ctx.theme.padding = Int32(10)
        state_ptr[].ctx.theme.spacing = Int32(6)

    # Animate the progress bar so it's visibly alive.
    var p = state_ptr[].progress + state_ptr[].progress_dir
    if p >= 1.0:
        p = 1.0
        state_ptr[].progress_dir = -0.005
    if p <= 0.0:
        p = 0.0
        state_ptr[].progress_dir = 0.005
    state_ptr[].progress = p

    var current_theme = _theme_for_index(state_ptr[].theme_idx)
    var bg = current_theme.colors.bg_default.copy()

    Backend.frame_begin(bg^)

    state_ptr[].ctx.set_default_font(state_ptr[].font_id)

    var win = Backend.window_size()
    state_ptr[].ctx.begin_frame(win.copy())

    # Caret blink (Phase 5): no monotonic-clock FFI yet, so approximate ~1 Hz
    # at 60 fps with a 60-frame period (on for 30, off for 30). Drives
    # ctx.caret_visible which the text widgets gate their caret draw on.
    state_ptr[].blink_frame = (state_ptr[].blink_frame + Int32(1)) % Int32(60)
    state_ptr[].ctx.caret_visible = state_ptr[].blink_frame < Int32(30)

    # Reference-bind ctx so the widget calls below read as plain `ctx.xxx`
    # but still target the persistent state_ptr[].ctx in place (no move).
    ref ctx = state_ptr[].ctx

    # ----- Title + theme switcher -----
    ctx.layout_row(_row1(900), Int32(32))
    label(ctx, String("MojoUI m4 — Kitchen Sink (live)"))

    ctx.layout_row(_row3(160, 160, 200), Int32(34))
    if button(ctx, String("Dark")):
        state_ptr[].theme_idx = Int32(0)
    if button(ctx, String("Light")):
        state_ptr[].theme_idx = Int32(1)
    if button(ctx, String("High contrast")):
        state_ptr[].theme_idx = Int32(2)

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Basic: counter button + bool checkboxes -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Basic =="))
    ctx.layout_row(_row4(180, 280, 160, 160), Int32(32))
    if button(ctx, String("Click me")):
        state_ptr[].counter = state_ptr[].counter + Int32(1)
    var counter_msg = String("Clicks: ") + String(state_ptr[].counter)
    label(ctx, counter_msg^)
    var bold_local = state_ptr[].bold
    _ = checkbox(ctx, String("Bold"), bold_local)
    state_ptr[].bold = bold_local
    var italic_local = state_ptr[].italic
    _ = checkbox(ctx, String("Italic"), italic_local)
    state_ptr[].italic = italic_local

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Radio group -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Radio =="))
    ctx.layout_row(_row3(200, 200, 200), Int32(28))
    var fruit_local = state_ptr[].fruit
    _ = radio(ctx, String("Apple"), Int32(1), fruit_local)
    _ = radio(ctx, String("Banana"), Int32(2), fruit_local)
    _ = radio(ctx, String("Cherry"), Int32(3), fruit_local)
    state_ptr[].fruit = fruit_local

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Numeric: slider + drag_value -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Numeric =="))
    ctx.layout_row(_row2(500, 300), Int32(28))
    var gain_local = state_ptr[].gain
    if slider(ctx, gain_local, Float32(0.0), Float32(1.0), String("gain")):
        state_ptr[].gain = gain_local
    var cfg_local = state_ptr[].cfg
    if drag_value(ctx, cfg_local, String("cfg"), Float32(0.1)):
        state_ptr[].cfg = cfg_local

    ctx.layout_row(_row1(900), Int32(22))
    var slider_msg = (
        String("gain=") + String(state_ptr[].gain)
        + String("  cfg=") + String(state_ptr[].cfg)
    )
    label(ctx, slider_msg^)

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Progress (animated) -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Progress =="))
    ctx.layout_row(_row1(700), Int32(24))
    progress_bar(ctx, state_ptr[].progress)

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Text input: text_edit + text_area -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Text input =="))
    ctx.layout_row(_row1(700), Int32(28))
    var name_local = state_ptr[].name_buffer
    try:
        _ = text_edit(
            ctx, String("name_input"), name_local,
            state_ptr[].name_edit_state,
        )
    except e:
        print("text_edit error:", String(e))
    state_ptr[].name_buffer = name_local^
    ctx.layout_row(_row1(700), Int32(80))
    var notes_local = state_ptr[].notes_buffer
    try:
        _ = text_area(
            ctx,
            String("notes_area"),
            notes_local,
            state_ptr[].notes_edit_state,
        )
    except e:
        print("text_area error:", String(e))
    state_ptr[].notes_buffer = notes_local^

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Combo + collapsing header (menu) -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("== Combobox / menu + collapsing =="))
    ctx.layout_row(_row1(350), Int32(28))
    var sampler_idx_local = state_ptr[].sampler_index
    var combo_open_local = state_ptr[].combo_open
    _ = combobox(
        ctx, String("sampler"), state_ptr[].sampler_options,
        sampler_idx_local, combo_open_local,
    )
    state_ptr[].sampler_index = sampler_idx_local
    state_ptr[].combo_open = combo_open_local

    var advanced_local = state_ptr[].advanced_open
    if collapsing_header(ctx, String("Advanced settings"), advanced_local):
        ctx.layout_row(_row1(700), Int32(24))
        var ue_local = state_ptr[].use_experimental
        _ = checkbox(ctx, String("Use experimental"), ue_local)
        state_ptr[].use_experimental = ue_local
        ctx.layout_row(_row1(700), Int32(24))
        var wc_local = state_ptr[].warn_on_cancel
        _ = checkbox(ctx, String("Warn on cancel"), wc_local)
        state_ptr[].warn_on_cancel = wc_local
    state_ptr[].advanced_open = advanced_local

    ctx.layout_row(_row1(900), Int32(6))
    separator(ctx)

    # ----- Footer / help -----
    ctx.layout_row(_row1(900), Int32(22))
    label(ctx, String("Tab cycles focus | close window to exit"))

    ctx.end_frame()

    try:
        _render_command_buffer(ctx)
    except e:
        print("MojoUI walker error:", String(e))
    Backend.frame_end()


def main() raises:
    var state = KitchenState()
    var state_ptr = UnsafePointer(to=state)
    store_user_state(state_ptr)

    var rc = Backend.init(
        Int32(1600), Int32(1100), String("MojoUI m4 — Kitchen Sink"),
    )
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening kitchen-sink window — font loads lazily on first frame.")
    Backend.run_blocking(_frame)

    print(
        "PASS: m4 kitchen-sink exited cleanly. counter=", Int(state.counter),
        "gain=", state.gain, "cfg=", state.cfg,
        "fruit=", Int(state.fruit), "sampler=", Int(state.sampler_index),
    )
