"""Text-edit widget — single-line text input, driven by the stb_textedit port.

Rewritten (M5) to run on `mojoui/core/textedit.mojo` (a pure-Mojo port of
stb_textedit, the engine behind Dear ImGui's InputText). The widget owns the
presentation + input plumbing; the engine owns the editing model. Compared to
the old byte-append stub this adds: a real caret at the cursor position,
shift-arrow / mouse-drag SELECTION with a highlight, word movement
(Ctrl+Left/Right), Home/End/Ctrl+Home/Ctrl+End, full UNDO/REDO (Ctrl+Z /
Ctrl+Y), select-all (Ctrl+A), and in-app cut/copy/paste (Ctrl+X/C/V via
`ctx.clipboard`).

State ownership:
  The caller now threads a `TextEditState` alongside the `String` buffer —
  it persists across frames (cursor, selection, undo stack live there). Same
  rationale as the combobox `is_open` flag: Mojo has no module-level state.
  Initialise once with `TextEditState(single_line=True)`.

Char model — BYTES (see core/textedit.mojo): cursor/selection are byte
offsets; ASCII-exact, multi-byte codepoints can be split (documented
limitation, matches the old widget).

JIT note (unchanged): the focused path calls `ctx.input.consume_text()` which
reaches `mojoui_get_input_text` & friends — symbols the JIT won't dlopen.
Unit tests bypass via `InputState.disable_ffi_text()` + staged `pending_text`.
The engine itself (core/textedit.mojo) is fully FFI-free and tested directly.
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
    MOJOUI_KEY_BACKSPACE, MOJOUI_KEY_DELETE,
    MOJOUI_KEY_LSHIFT, MOJOUI_KEY_RSHIFT,
    MOJOUI_KEY_LCTRL, MOJOUI_KEY_RCTRL,
    MOJOUI_KEY_A, MOJOUI_KEY_C, MOJOUI_KEY_V, MOJOUI_KEY_X,
    MOJOUI_KEY_Y, MOJOUI_KEY_Z,
    MOJOUI_BTN_LEFT,
)
from mojoui.core.textedit import (
    TextEditState,
    te_insert_char, te_key, te_click, te_drag, te_cut, te_paste,
    te_has_selection, te_stringlen,
    TE_K_LEFT, TE_K_RIGHT, TE_K_UP, TE_K_DOWN,
    TE_K_BACKSPACE, TE_K_DELETE,
    TE_K_WORDLEFT, TE_K_WORDRIGHT,
    TE_K_LINESTART, TE_K_LINEEND, TE_K_TEXTSTART, TE_K_TEXTEND,
    TE_K_UNDO, TE_K_REDO, TE_K_SHIFT,
)


@always_inline
def _char_advance(ctx: Context) -> Float32:
    """Approximate per-byte horizontal advance. Heuristic (font_size * 0.55)
    matching the old caret-x calc — proper per-glyph widths need the
    JIT-incompatible `Backend.text_width` FFI; a uniform advance is good
    enough for caret/selection placement and click-to-position in the
    single-line case. Swapping to measured widths later is localized to
    this helper + te_locate_coord's caller."""
    return Float32(ctx.theme.font_size_pt) * 0.55


def _byte_prefix(buffer: String, col: Int32) -> String:
    """Bytes [0, col) of `buffer` as a String (clamped)."""
    var n = Int(buffer.byte_length())
    var c = Int(col)
    if c <= 0:
        return String("")
    if c > n:
        c = n
    var out = List[UInt8](capacity=c)
    var ptr = buffer.unsafe_ptr()
    for i in range(c):
        out.append(ptr[i])
    return String(unsafe_from_utf8=out)


def _prefix_x(ctx: Context, buffer: String, col: Int32, advance: Float32) -> Float32:
    """X-offset (relative to text origin) of byte column `col`. Uses real
    glyph widths via Backend.text_width when a font is loaded; falls back to
    the uniform `advance` when headless (font_id == 0)."""
    if ctx.theme.font_id == 0:
        return Float32(col) * advance
    if col <= 0:
        return 0.0
    var prefix = _byte_prefix(buffer, col)
    var w = Backend.text_width(ctx.theme.font_id, ctx.theme.font_size_pt, prefix)
    # Fall back to uniform advance when measurement is unavailable (atlas not
    # baked yet / unregistered id) so caret/selection don't collapse to x=0.
    if w <= 0:
        return Float32(col) * advance
    return Float32(w)


def _locate_col(ctx: Context, buffer: String, local_x: Float32, advance: Float32) -> Float32:
    """Inverse of `_prefix_x`: the byte column nearest display x `local_x`.
    Walks measured prefix widths when a font is loaded; uniform fallback
    when headless. Returned as Float32 so the caller can feed te_locate_coord
    (the engine clamps)."""
    var n = te_stringlen(buffer)
    if ctx.theme.font_id == 0 or n == 0:
        if advance <= 0.0:
            return 0.0
        return local_x / advance
    if local_x <= 0.0:
        return 0.0
    # Find the column where prefix width first exceeds local_x, then pick the
    # nearer of (col-1, col) by the midpoint rule.
    var prev_w: Float32 = 0.0
    for col in range(1, Int(n) + 1):
        var w = _prefix_x(ctx, buffer, Int32(col), advance)
        var mid = (prev_w + w) * 0.5
        if local_x < mid:
            return Float32(col - 1)
        prev_w = w
    return Float32(n)


def _selected_bytes(buffer: String, lo: Int32, hi: Int32) -> List[UInt8]:
    var out = List[UInt8]()
    var ptr = buffer.unsafe_ptr()
    for i in range(Int(lo), Int(hi)):
        out.append(ptr[i])
    return out^


def _handle_keys(mut ctx: Context, mut buffer: String, mut state: TextEditState):
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
    var shift_bit = TE_K_SHIFT if shift else Int32(0)

    # ---- Clipboard + undo/redo + select-all (Ctrl combos) ----
    if ctrl:
        if ctx.input.key_pressed(MOJOUI_KEY_Z):
            te_key(buffer, state, TE_K_UNDO)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_Y):
            te_key(buffer, state, TE_K_REDO)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_A):
            # select all
            state.select_start = 0
            state.select_end = te_stringlen(buffer)
            state.cursor = state.select_end
            return
        if ctx.input.key_pressed(MOJOUI_KEY_C):
            if te_has_selection(state):
                var lo = state.select_start
                var hi = state.select_end
                if hi < lo:
                    lo = state.select_end
                    hi = state.select_start
                ctx.clipboard = String(unsafe_from_utf8=_selected_bytes(buffer, lo, hi))
            return
        if ctx.input.key_pressed(MOJOUI_KEY_X):
            if te_has_selection(state):
                var lo = state.select_start
                var hi = state.select_end
                if hi < lo:
                    lo = state.select_end
                    hi = state.select_start
                ctx.clipboard = String(unsafe_from_utf8=_selected_bytes(buffer, lo, hi))
                _ = te_cut(buffer, state)
            return
        if ctx.input.key_pressed(MOJOUI_KEY_V):
            if ctx.clipboard.byte_length() > 0:
                var bytes = List[UInt8]()
                var ptr = ctx.clipboard.unsafe_ptr()
                for i in range(ctx.clipboard.byte_length()):
                    bytes.append(ptr[i])
                _ = te_paste(buffer, state, bytes)
            return

    # ---- Navigation + editing keys ----
    if ctx.input.key_pressed(MOJOUI_KEY_LEFT):
        if ctrl:
            te_key(buffer, state, TE_K_WORDLEFT | shift_bit)
        else:
            te_key(buffer, state, TE_K_LEFT | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_RIGHT):
        if ctrl:
            te_key(buffer, state, TE_K_WORDRIGHT | shift_bit)
        else:
            te_key(buffer, state, TE_K_RIGHT | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_UP):
        te_key(buffer, state, TE_K_UP | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_DOWN):
        te_key(buffer, state, TE_K_DOWN | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_HOME):
        if ctrl:
            te_key(buffer, state, TE_K_TEXTSTART | shift_bit)
        else:
            te_key(buffer, state, TE_K_LINESTART | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_END):
        if ctrl:
            te_key(buffer, state, TE_K_TEXTEND | shift_bit)
        else:
            te_key(buffer, state, TE_K_LINEEND | shift_bit)
    if ctx.input.key_pressed(MOJOUI_KEY_BACKSPACE):
        te_key(buffer, state, TE_K_BACKSPACE)
    if ctx.input.key_pressed(MOJOUI_KEY_DELETE):
        te_key(buffer, state, TE_K_DELETE)


def text_edit(
    mut ctx: Context, id_str: String, mut buffer: String, mut state: TextEditState
) raises -> Bool:
    """Single-line text input backed by the stb_textedit engine. Returns
    True iff `buffer` changed this frame.

    Args:
        ctx:     Per-frame Context.
        id_str:  Caller-supplied id seed (mirrors slider/combobox).
        buffer:  The edited text. Mutated in place.
        state:   Persistent editing state (cursor/selection/undo). Caller
                 owns it across frames; init once with
                 `TextEditState(single_line=True)`.

    Interaction: click to focus + position the caret; drag to select; type
    to insert; arrows/Home/End to move (Shift to select, Ctrl for word /
    text bounds); Backspace/Delete; Ctrl+A select-all; Ctrl+C/X/V
    copy/cut/paste (in-app clipboard); Ctrl+Z/Y undo/redo.
    """
    var id = ctx.get_id(id_str)
    var rect = ctx.layout_next()
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)

    var advance = _char_advance(ctx)
    var origin_x = rect.x + Float32(ctx.theme.padding)

    # Snapshot for change detection (cheap for a text field).
    var before = buffer.copy()

    # ---- Mouse: click to place caret, drag to extend selection ----
    # Local x relative to the text origin. update_control already granted
    # focus on press; we add caret positioning on top. We resolve the byte
    # column with measured glyph widths (`_locate_col`) then feed it to the
    # engine as a logical x with a unit advance (so te_locate_coord rounds to
    # that exact column). Headless (font_id == 0) falls back to uniform.
    if (flags & CTRL_PRESSED) != 0:
        var local_x = ctx.control.mouse_pos.x - origin_x
        var col = _locate_col(ctx, buffer, local_x, advance)
        te_click(buffer, state, col, 1.0)
    elif (flags & CTRL_ACTIVE) != 0 and ctx.input.mouse_held(MOJOUI_BTN_LEFT):
        # Dragging with the button down inside an active field.
        var local_x = ctx.control.mouse_pos.x - origin_x
        var col = _locate_col(ctx, buffer, local_x, advance)
        te_drag(buffer, state, col, 1.0)

    # ---- Keyboard (focused only) ----
    if (flags & CTRL_FOCUSED) != 0:
        # Typed printable text — skip when Ctrl is held (those are commands,
        # handled in _handle_keys, not text to insert).
        var ctrl = (
            ctx.input.key_held(MOJOUI_KEY_LCTRL)
            or ctx.input.key_held(MOJOUI_KEY_RCTRL)
        )
        if not ctrl:
            var typed = ctx.input.consume_text()
            if typed.byte_length() > 0:
                var ptr = typed.unsafe_ptr()
                for i in range(typed.byte_length()):
                    te_insert_char(buffer, state, ptr[i])
        _handle_keys(ctx, buffer, state)

    # ---- Draw: bg, border, selection highlight, text, caret ----
    ctx.draw_rect(rect.copy(), ctx.theme.bg.copy())

    var border_color: Color
    if (flags & CTRL_FOCUSED) != 0:
        border_color = ctx.theme.primary.copy()
    else:
        border_color = ctx.theme.border.copy()
    _draw_border_inline(ctx, rect.copy(), border_color^, 1.0)

    if ctx.theme.font_id != 0:
        var glyph_h = Float32(ctx.theme.font_size_pt)
        var content_y = rect.y + (rect.h - glyph_h) * 0.5

        # Selection highlight (behind text). Drawn only when focused so an
        # unfocused field doesn't show a stale highlight.
        if (flags & CTRL_FOCUSED) != 0 and te_has_selection(state):
            var lo = state.select_start
            var hi = state.select_end
            if hi < lo:
                lo = state.select_end
                hi = state.select_start
            var sx0 = origin_x + _prefix_x(ctx, buffer, lo, advance)
            var sx1 = origin_x + _prefix_x(ctx, buffer, hi, advance)
            ctx.draw_rect(
                Rect(sx0, content_y, sx1 - sx0, glyph_h),
                ctx.theme.active_bg.copy(),
            )

        var text_pos = Vec2(
            origin_x,
            rect.y + (rect.h + glyph_h * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            text_pos^,
            ctx.theme.text.copy(),
            buffer,
        )

        # Caret at the cursor byte offset (focused only).
        if (flags & CTRL_FOCUSED) != 0 and ctx.caret_visible:
            var caret_x = origin_x + _prefix_x(ctx, buffer, state.cursor, advance)
            ctx.draw_rect(
                Rect(caret_x, content_y, 1.0, glyph_h),
                ctx.theme.primary.copy(),
            )

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
