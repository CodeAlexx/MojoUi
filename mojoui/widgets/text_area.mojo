"""Text-area widget — multi-line text input, driven by the line-array engine.

Rewritten (M8, 2026-05-28) to run on `mojoui/core/multiline_edit.mojo` (a
pure-Mojo line-array editor). The widget owns presentation + input plumbing;
the engine owns the editing model. Compared to the old byte-append stub this
adds: real (row, col) cursor movement, up/down with sticky preferred-column,
shift-arrow / mouse-drag SELECTION with per-line highlight, Home/End/Ctrl+Home/
Ctrl+End, select-all (Ctrl+A), and in-app cut/copy/paste (Ctrl+X/C/V via
`ctx.clipboard`).

BREAKING signature change (mirrors text_edit's TextEditState change):
    OLD: text_area(ctx, id_str, mut buffer) -> Bool
    NEW: text_area(ctx, id_str, mut buffer, mut state: MultiLineState) -> Bool

`MultiLineState` is authoritative for content + cursor. Sync contract:
  - Caller seeds `state.set_text(initial)` once before the first frame.
  - Each frame the widget keeps `state` authoritative and writes
    `buffer = state.text()` when changed; returns True iff changed.

Char model — BYTES (see core/multiline_edit.mojo): cursor cols are byte
offsets; ASCII-exact, multi-byte codepoints can be split (documented
limitation, matches the single-line engine).

Caret/selection use a uniform per-byte advance (`_char_advance` =
font_size_pt * 0.55). Real glyph widths via `Backend.text_width` is Phase 3.

Vertical scroll-to-caret is NOT implemented this phase (DEFERRED) — long
content past the rect height is clipped (one CMD_CLIP) but the view does not
follow the caret. Combine with a future scroll_area for tall documents.

JIT note (unchanged from text_edit): the focused path calls
`ctx.input.consume_text()` which reaches `mojoui_get_input_text` & friends —
symbols the JIT won't dlopen. Unit tests bypass via
`InputState.disable_ffi_text()` + staged `pending_text`. The engine itself
(core/multiline_edit.mojo) is fully FFI-free and tested directly.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.render.backend import Backend
from mojoui.core.control import (
    CTRL_FOCUSED, CTRL_PRESSED, CTRL_ACTIVE, OPT_FOCUSABLE,
)
from mojoui.render.ffi import (
    MOJOUI_KEY_LEFT, MOJOUI_KEY_RIGHT, MOJOUI_KEY_UP, MOJOUI_KEY_DOWN,
    MOJOUI_KEY_HOME, MOJOUI_KEY_END,
    MOJOUI_KEY_BACKSPACE, MOJOUI_KEY_DELETE, MOJOUI_KEY_RETURN,
    MOJOUI_KEY_LSHIFT, MOJOUI_KEY_RSHIFT,
    MOJOUI_KEY_LCTRL, MOJOUI_KEY_RCTRL,
    MOJOUI_KEY_A, MOJOUI_KEY_C, MOJOUI_KEY_V, MOJOUI_KEY_X,
    MOJOUI_BTN_LEFT,
)
from mojoui.core.multiline_edit import (
    MultiLineState,
    ml_insert_text, ml_insert_newline, ml_backspace, ml_delete,
    ml_move_left, ml_move_right, ml_move_up, ml_move_down,
    ml_move_home, ml_move_end, ml_move_doc_start, ml_move_doc_end,
    ml_select_all, ml_set_cursor, ml_selected_text, ml_cut, ml_paste,
)


@always_inline
def _char_advance(ctx: Context) -> Float32:
    """Approximate per-byte horizontal advance (font_size * 0.55). Uniform —
    real glyph widths via Backend.text_width is Phase 3. Used for caret /
    selection / click positioning."""
    return Float32(ctx.theme.font_size_pt) * 0.55


@always_inline
def _line_height(ctx: Context) -> Float32:
    return Float32(ctx.theme.font_size_pt) + 4.0


def _byte_prefix(line: String, col: Int32) -> String:
    """Bytes [0, col) of `line` (clamped)."""
    var n = Int(line.byte_length())
    var c = Int(col)
    if c <= 0:
        return String("")
    if c > n:
        c = n
    var out = List[UInt8](capacity=c)
    var ptr = line.unsafe_ptr()
    for i in range(c):
        out.append(ptr[i])
    return String(unsafe_from_utf8=out)


def _prefix_x(ctx: Context, line: String, col: Int32, advance: Float32) -> Float32:
    """X-offset of byte column `col` within `line`. Measured glyph widths via
    Backend.text_width when a font is loaded; uniform `advance` fallback when
    headless (font_id == 0)."""
    if ctx.theme.font_id == 0:
        return Float32(col) * advance
    if col <= 0:
        return 0.0
    var prefix = _byte_prefix(line, col)
    var w = Backend.text_width(ctx.theme.font_id, ctx.theme.font_size_pt, prefix)
    # text_width returns 0 when the atlas isn't baked yet (or the id isn't
    # registered, e.g. headless tests with a fake font_id). Fall back to the
    # uniform advance so caret/selection still position sensibly instead of
    # collapsing every column to x=0.
    if w <= 0:
        return Float32(col) * advance
    return Float32(w)


def _locate_col_in_line(
    ctx: Context, line: String, local_x: Float32, advance: Float32
) -> Int32:
    """The byte column in `line` nearest display x `local_x`. Measured prefix
    walk when a font is loaded; uniform fallback when headless."""
    var n = Int32(line.byte_length())
    if ctx.theme.font_id == 0 or n == 0:
        if advance <= 0.0 or local_x <= 0.0:
            return 0
        var c = Int32(local_x / advance + 0.5)
        if c > n:
            c = n
        return c
    if local_x <= 0.0:
        return 0
    var prev_w: Float32 = 0.0
    for col in range(1, Int(n) + 1):
        var w = _prefix_x(ctx, line, Int32(col), advance)
        var mid = (prev_w + w) * 0.5
        if local_x < mid:
            return Int32(col - 1)
        prev_w = w
    return n


def _handle_keys(mut ctx: Context, mut state: MultiLineState):
    """Translate this frame's key edges + modifiers into engine calls.
    Called only while focused."""
    var shift = (
        ctx.input.key_held(MOJOUI_KEY_LSHIFT)
        or ctx.input.key_held(MOJOUI_KEY_RSHIFT)
    )
    var ctrl = (
        ctx.input.key_held(MOJOUI_KEY_LCTRL)
        or ctx.input.key_held(MOJOUI_KEY_RCTRL)
    )

    # ---- Clipboard + select-all (Ctrl combos) ----
    if ctrl:
        if ctx.input.key_pressed(MOJOUI_KEY_A):
            ml_select_all(state)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_C):
            if state.has_selection():
                ctx.clipboard = ml_selected_text(state)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_X):
            if state.has_selection():
                ctx.clipboard = ml_cut(state)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_V):
            if ctx.clipboard.byte_length() > 0:
                ml_paste(state, ctx.clipboard)
            return

    # ---- Navigation + editing keys ----
    # Movement + Backspace/Delete auto-repeat while held (key_repeat);
    # Home/End/Return stay edge-only.
    if ctx.input.key_repeat(MOJOUI_KEY_LEFT):
        ml_move_left(state, shift)
    if ctx.input.key_repeat(MOJOUI_KEY_RIGHT):
        ml_move_right(state, shift)
    if ctx.input.key_repeat(MOJOUI_KEY_UP):
        ml_move_up(state, shift)
    if ctx.input.key_repeat(MOJOUI_KEY_DOWN):
        ml_move_down(state, shift)
    if ctx.input.key_pressed(MOJOUI_KEY_HOME):
        if ctrl:
            ml_move_doc_start(state, shift)
        else:
            ml_move_home(state, shift)
    if ctx.input.key_pressed(MOJOUI_KEY_END):
        if ctrl:
            ml_move_doc_end(state, shift)
        else:
            ml_move_end(state, shift)
    if ctx.input.key_pressed(MOJOUI_KEY_RETURN):
        ml_insert_newline(state)
    if ctx.input.key_repeat(MOJOUI_KEY_BACKSPACE):
        ml_backspace(state)
    if ctx.input.key_repeat(MOJOUI_KEY_DELETE):
        ml_delete(state)


def _coord_from_mouse(
    ctx: Context, state: MultiLineState, rect: Rect
) -> Vec2:
    """Map the current mouse position to a (row, col) cursor coordinate as a
    Vec2 (.x = row, .y = col). Clamped; the engine re-clamps in
    ml_set_cursor."""
    var pad = Float32(ctx.theme.padding)
    var lh = _line_height(ctx)
    var adv = _char_advance(ctx)
    var local_y = ctx.control.mouse_pos.y - rect.y - pad
    var local_x = ctx.control.mouse_pos.x - rect.x - pad
    var row: Int32 = 0
    if lh > 0.0 and local_y > 0.0:
        row = Int32(local_y / lh)
    if row < 0:
        row = 0
    var last = Int32(len(state.lines)) - 1
    if row > last:
        row = last
    # Measured byte column within the resolved row (glyph widths).
    var col = _locate_col_in_line(ctx, state.lines[Int(row)], local_x, adv)
    if col < 0:
        col = 0
    return Vec2(Float32(row), Float32(col))


def text_area(
    mut ctx: Context, id_str: String, mut buffer: String, mut state: MultiLineState
) raises -> Bool:
    """Multi-line text input backed by the line-array engine. Returns True
    iff `buffer` changed this frame.

    Args:
        ctx:     Per-frame Context.
        id_str:  Caller-supplied id seed (mirrors text_edit/slider).
        buffer:  The edited text. Written from `state.text()` when changed.
        state:   Persistent editing state (lines/cursor/selection). Caller
                 owns it across frames; seed once with
                 `state.set_text(initial)`.

    Interaction: click to focus + position the caret; drag to select; type
    to insert; Enter for a newline; arrows/Home/End to move (Shift to select,
    Ctrl+Home/End = doc start/end); Backspace/Delete; Ctrl+A select-all;
    Ctrl+C/X/V copy/cut/paste (in-app clipboard).
    """
    var id = ctx.get_id(id_str)
    var rect = ctx.layout_next()
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)

    var before = buffer.copy()

    # ---- Mouse: click to place caret, drag to extend selection ----
    if (flags & CTRL_PRESSED) != 0:
        var rc = _coord_from_mouse(ctx, state, rect.copy())
        ml_set_cursor(state, Int32(rc.x), Int32(rc.y), False)
    elif (flags & CTRL_ACTIVE) != 0 and ctx.input.mouse_held(MOJOUI_BTN_LEFT):
        var rc = _coord_from_mouse(ctx, state, rect.copy())
        ml_set_cursor(state, Int32(rc.x), Int32(rc.y), True)

    # ---- Keyboard (focused only) ----
    if (flags & CTRL_FOCUSED) != 0:
        var ctrl = (
            ctx.input.key_held(MOJOUI_KEY_LCTRL)
            or ctx.input.key_held(MOJOUI_KEY_RCTRL)
        )
        if not ctrl:
            var typed = ctx.input.consume_text()
            if typed.byte_length() > 0:
                ml_insert_text(state, typed)
        _handle_keys(ctx, state)

    # ---- Draw: bg, border, clip, selection highlight, text, caret ----
    ctx.draw_rect(rect.copy(), ctx.theme.bg.copy())

    var border_color: Color
    if (flags & CTRL_FOCUSED) != 0:
        border_color = ctx.theme.primary.copy()
    else:
        border_color = ctx.theme.border.copy()
    _draw_border_inline(ctx, rect.copy(), border_color^, 1.0)

    # Clip content to the rect so long documents don't overflow.
    ctx.draw_clip(rect.copy())

    if ctx.theme.font_id != 0:
        var pad = Float32(ctx.theme.padding)
        var lh = _line_height(ctx)
        var adv = _char_advance(ctx)
        var glyph_h = Float32(ctx.theme.font_size_pt)
        var origin_x = rect.x + pad
        var origin_y = rect.y + pad
        var focused = (flags & CTRL_FOCUSED) != 0

        # Selection highlight (focused only, behind text). Normalize span.
        if focused and state.has_selection():
            var r0 = state.cursor_row
            var c0 = state.cursor_col
            var r1 = state.sel_row
            var c1 = state.sel_col
            if (state.sel_row < state.cursor_row) or (
                state.sel_row == state.cursor_row and state.sel_col < state.cursor_col
            ):
                r0 = state.sel_row
                c0 = state.sel_col
                r1 = state.cursor_row
                c1 = state.cursor_col
            for r in range(Int(r0), Int(r1) + 1):
                var line_len = Int32(state.lines[r].byte_length())
                var start_col: Int32 = 0
                var end_col = line_len
                if Int32(r) == r0:
                    start_col = c0
                if Int32(r) == r1:
                    end_col = c1
                var line_r = state.lines[r]
                var sx0 = origin_x + _prefix_x(ctx, line_r, start_col, adv)
                var sx1 = origin_x + _prefix_x(ctx, line_r, end_col, adv)
                # Visual cue for a captured newline (whole line + below).
                if Int32(r) != r1 and end_col == line_len:
                    sx1 = sx1 + adv * 0.5
                var hy = origin_y + Float32(r) * lh
                if sx1 > sx0:
                    ctx.draw_rect(
                        Rect(sx0, hy, sx1 - sx0, glyph_h),
                        ctx.theme.active_bg.copy(),
                    )

        # Text per line.
        var n_lines = len(state.lines)
        for li in range(n_lines):
            var line_pos = Vec2(
                origin_x, origin_y + Float32(li) * lh + glyph_h * 0.7
            )
            ctx.draw_text(
                ctx.theme.font_id,
                ctx.theme.font_size_pt,
                line_pos^,
                ctx.theme.text.copy(),
                state.lines[li],
            )

        # Caret at the cursor (row, col) — focused only.
        if focused and ctx.caret_visible:
            var cur_line = state.lines[Int(state.cursor_row)]
            var caret_x = origin_x + _prefix_x(ctx, cur_line, state.cursor_col, adv)
            var caret_y = origin_y + Float32(state.cursor_row) * lh
            ctx.draw_rect(
                Rect(caret_x, caret_y, 1.0, glyph_h),
                ctx.theme.primary.copy(),
            )

    ctx.reset_clip()

    # ---- Sync buffer + detect change ----
    var changed = buffer != before
    if (flags & CTRL_FOCUSED) != 0 or changed:
        buffer = state.text()
    return buffer != before


def _draw_border_inline(
    mut ctx: Context, rect: Rect, color: Color, thickness: Float32
):
    """4-thin-rects rectangular outline (kept private per the no-cross-module-
    private-import convention)."""
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    ctx.draw_rect(
        Rect(rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness),
        color.copy(),
    )
    ctx.draw_rect(
        Rect(
            rect.x + rect.w - thickness,
            rect.y + thickness,
            thickness,
            rect.h - 2.0 * thickness,
        ),
        color.copy(),
    )
