"""Text-edit state machine — pure-Mojo port of stb_textedit (single-line).

Source: vendor/stb_textedit.h v1.14 by Sean Barrett (public domain). This is
the proven engine behind Dear ImGui's InputText. We port the SINGLE-LINE
subset: the full keyboard model (cursor movement, shift-selection, word
movement, home/end, text start/end), insert/overwrite, cut/paste, and the
complete undo/redo stack. Multi-line (the LAYOUTROW / find_charpos row-walking
machinery for up/down across wrapped lines) is intentionally omitted — in
single-line mode stb itself redirects up/down to left/right, so none of that
code path is reachable here. Multi-line lands in a later chunk.

Char unit — BYTES, not codepoints:
  `STB_TEXTEDIT_CHARTYPE` maps to `UInt8`; the engine operates on the editing
  buffer's raw UTF-8 bytes. Cursor / selection indices are byte offsets. For
  ASCII (prompts, filenames, numbers — the diffusion-UI common case) this is
  exact. A multi-byte codepoint can be split by per-byte cursor movement or
  backspace, which can transiently produce malformed UTF-8 — same limitation
  as the previous byte-level text_edit widget. Codepoint-aware movement is a
  future refinement; the engine's structure (indices + width callback) makes
  it a localized change later.

Pure / FFI-free:
  Every function here takes a `String` buffer + a `TextEditState` + plain
  ints/floats. No FFI, no Context, no rendering. This makes the whole engine
  unit-testable under `mojo run` (the JIT can't dlopen the C floor) — the
  widget layer (`widgets/text_edit.mojo`) does the FFI input + drawing and
  drives this engine.

`.copy()` discipline: `UndoRecord` is `Copyable, Movable` but reads that feed
other calls still spell `.copy()` where the borrow checker requires it.
"""

from std.math import floor


# ============================================================================
# Key codes (caller maps platform keys → these before calling te_key)
# ============================================================================
# All control keys carry bit 16 (0x10000) so they never collide with a byte
# value; SHIFT is bit 17 (0x20000), OR'd in to request selection-extending
# variants (matches stb's `K | K_SHIFT` convention).

comptime TE_K_SHIFT: Int32 = 0x20000

comptime TE_K_LEFT: Int32 = 0x10001
comptime TE_K_RIGHT: Int32 = 0x10002
comptime TE_K_UP: Int32 = 0x10003
comptime TE_K_DOWN: Int32 = 0x10004
comptime TE_K_LINESTART: Int32 = 0x10005   # Home
comptime TE_K_LINEEND: Int32 = 0x10006     # End
comptime TE_K_TEXTSTART: Int32 = 0x10007   # Ctrl+Home
comptime TE_K_TEXTEND: Int32 = 0x10008     # Ctrl+End
comptime TE_K_DELETE: Int32 = 0x10009
comptime TE_K_BACKSPACE: Int32 = 0x1000A
comptime TE_K_UNDO: Int32 = 0x1000B
comptime TE_K_REDO: Int32 = 0x1000C
comptime TE_K_WORDLEFT: Int32 = 0x1000D    # Ctrl+Left
comptime TE_K_WORDRIGHT: Int32 = 0x1000E   # Ctrl+Right

# Undo storage sizing (stb defaults).
comptime TE_UNDOSTATECOUNT: Int = 99
comptime TE_UNDOCHARCOUNT: Int = 999


# ============================================================================
# Undo data structures
# ============================================================================


@fieldwise_init
struct UndoRecord(Copyable, Movable):
    """One undo/redo entry (stb StbUndoRecord). `char_storage` = -1 when the
    record stores no characters (a pure-insert undo needs none — the chars
    are still live in the buffer)."""

    var where: Int32
    var insert_length: Int32
    var delete_length: Int32
    var char_storage: Int32

    def __init__(out self):
        self.where = 0
        self.insert_length = 0
        self.delete_length = 0
        self.char_storage = -1


struct UndoState(Movable):
    """Fixed-capacity undo/redo ring (stb StbUndoState). `undo_rec` /
    `undo_char` are pre-sized so every index in [0, COUNT) is always valid;
    the algorithm slides entries with the `_move_*` helpers below (stb uses
    memmove). Undo grows from the bottom (index 0 up to `undo_point`); redo
    grows from the top (index COUNT down to `redo_point`)."""

    var undo_rec: List[UndoRecord]
    var undo_char: List[UInt8]
    var undo_point: Int32
    var redo_point: Int32
    var undo_char_point: Int32
    var redo_char_point: Int32

    def __init__(out self):
        self.undo_rec = List[UndoRecord]()
        for _ in range(TE_UNDOSTATECOUNT):
            self.undo_rec.append(UndoRecord())
        self.undo_char = List[UInt8]()
        for _ in range(TE_UNDOCHARCOUNT):
            self.undo_char.append(0)
        self.undo_point = 0
        self.redo_point = Int32(TE_UNDOSTATECOUNT)
        self.undo_char_point = 0
        self.redo_char_point = Int32(TE_UNDOCHARCOUNT)

    def clear(mut self):
        self.undo_point = 0
        self.undo_char_point = 0
        self.redo_point = Int32(TE_UNDOSTATECOUNT)
        self.redo_char_point = Int32(TE_UNDOCHARCOUNT)


# ============================================================================
# TextEditState — the per-field state (stb STB_TexteditState)
# ============================================================================


struct TextEditState(Movable):
    """Per-textfield editing state. Caller owns one of these per text widget
    and threads it across frames (alongside the `String` buffer)."""

    var cursor: Int32
    var select_start: Int32
    var select_end: Int32
    var insert_mode: Bool
    var has_preferred_x: Bool
    var preferred_x: Float32
    var single_line: Bool
    var row_count_per_page: Int32
    var initialized: Bool
    var undostate: UndoState
    var scroll_x: Float32
    """Horizontal scroll offset (px) for single-line fields, persisted across
    frames by the widget so the caret stays inside the field box when the text
    is wider than the field. UI-only; the editing engine ignores it."""

    def __init__(out self, single_line: Bool = True):
        self.cursor = 0
        self.select_start = 0
        self.select_end = 0
        self.insert_mode = False
        self.has_preferred_x = False
        self.preferred_x = 0.0
        self.single_line = single_line
        self.row_count_per_page = 0
        self.initialized = True
        self.undostate = UndoState()
        self.scroll_x = 0.0

    def clear(mut self):
        """Reset to a known-good default (stb stb_textedit_clear_state)."""
        self.cursor = 0
        self.select_start = 0
        self.select_end = 0
        self.has_preferred_x = False
        self.preferred_x = 0.0
        self.insert_mode = False
        self.row_count_per_page = 0
        self.initialized = True
        self.undostate.clear()
        self.scroll_x = 0.0


# ============================================================================
# Buffer operations (stb STRINGLEN / GETCHAR / INSERTCHARS / DELETECHARS)
# ============================================================================


@always_inline
def te_stringlen(s: String) -> Int32:
    return Int32(s.byte_length())


@always_inline
def te_getchar(s: String, i: Int32) -> UInt8:
    """Byte i of the buffer. Caller guarantees 0 <= i < len."""
    return s.unsafe_ptr()[Int(i)]


def te_deletechars(mut s: String, where: Int32, n: Int32):
    """Delete `n` bytes starting at byte offset `where`. Rebuilds via
    List[UInt8] (current-beta has no in-place String byte splice — same
    pattern as backend.input_text)."""
    if n <= 0:
        return
    var total = s.byte_length()
    var w = Int(where)
    var cnt = Int(n)
    if w >= total:
        return
    if w + cnt > total:
        cnt = total - w
    var ptr = s.unsafe_ptr()
    var out = List[UInt8](capacity=total - cnt)
    for i in range(w):
        out.append(ptr[i])
    for i in range(w + cnt, total):
        out.append(ptr[i])
    s = String(unsafe_from_utf8=out)


def te_insertchars(mut s: String, where: Int32, chars: List[UInt8], n: Int32) -> Bool:
    """Insert `n` bytes from `chars` at byte offset `where`. Returns True
    (insertion always succeeds — there is no capacity cap on String)."""
    if n <= 0:
        return True
    var total = s.byte_length()
    var w = Int(where)
    if w > total:
        w = total
    var ptr = s.unsafe_ptr()
    var out = List[UInt8](capacity=total + Int(n))
    for i in range(w):
        out.append(ptr[i])
    for i in range(Int(n)):
        out.append(chars[i])
    for i in range(w, total):
        out.append(ptr[i])
    s = String(unsafe_from_utf8=out)
    return True


@always_inline
def _is_space(ch: UInt8) -> Bool:
    return ch == 0x20 or ch == 0x09 or ch == 0x0A or ch == 0x0D


def _single_char_list(ch: UInt8) -> List[UInt8]:
    var c = List[UInt8](capacity=1)
    c.append(ch)
    return c^


def _slice_chars(src: List[UInt8], start: Int32, n: Int32) -> List[UInt8]:
    var out = List[UInt8](capacity=Int(n))
    for i in range(Int(n)):
        out.append(src[Int(start) + i])
    return out^


# ============================================================================
# memmove-equivalent slides (bounds-safe: out-of-range writes are dropped,
# which exactly matches stb's intent — the only over-write in stb lands on a
# record being discarded). See the regression tests for coverage.
# ============================================================================


def _move_records(mut recs: List[UndoRecord], dst: Int, src: Int, count: Int):
    if count <= 0 or dst == src:
        return
    var n = len(recs)
    if dst < src:
        for i in range(count):
            var d = dst + i
            var s = src + i
            if d >= 0 and d < n and s >= 0 and s < n:
                recs[d] = recs[s].copy()
    else:
        var i = count - 1
        while i >= 0:
            var d = dst + i
            var s = src + i
            if d >= 0 and d < n and s >= 0 and s < n:
                recs[d] = recs[s].copy()
            i -= 1


def _move_chars(mut chars: List[UInt8], dst: Int, src: Int, count: Int):
    if count <= 0 or dst == src:
        return
    var n = len(chars)
    if dst < src:
        for i in range(count):
            var d = dst + i
            var s = src + i
            if d >= 0 and d < n and s >= 0 and s < n:
                chars[d] = chars[s]
    else:
        var i = count - 1
        while i >= 0:
            var d = dst + i
            var s = src + i
            if d >= 0 and d < n and s >= 0 and s < n:
                chars[d] = chars[s]
            i -= 1


# ============================================================================
# Selection / cursor helpers
# ============================================================================


@always_inline
def te_has_selection(state: TextEditState) -> Bool:
    return state.select_start != state.select_end


def te_clamp(s: String, mut state: TextEditState):
    """Make selection/cursor valid after the buffer changed (stb
    stb_textedit_clamp)."""
    var n = te_stringlen(s)
    if te_has_selection(state):
        if state.select_start > n:
            state.select_start = n
        if state.select_end > n:
            state.select_end = n
        if state.select_start == state.select_end:
            state.cursor = state.select_start
    if state.cursor > n:
        state.cursor = n


def _delete(mut s: String, mut state: TextEditState, where: Int32, length: Int32):
    """Delete with undo bookkeeping (stb stb_textedit_delete)."""
    _makeundo_delete(s, state, where, length)
    te_deletechars(s, where, length)
    state.has_preferred_x = False


def te_delete_selection(mut s: String, mut state: TextEditState):
    te_clamp(s, state)
    if te_has_selection(state):
        if state.select_start < state.select_end:
            _delete(s, state, state.select_start, state.select_end - state.select_start)
            state.select_end = state.select_start
            state.cursor = state.select_start
        else:
            _delete(s, state, state.select_end, state.select_start - state.select_end)
            state.select_start = state.select_end
            state.cursor = state.select_end
        state.has_preferred_x = False


def _sortselection(mut state: TextEditState):
    if state.select_end < state.select_start:
        var tmp = state.select_end
        state.select_end = state.select_start
        state.select_start = tmp


def _move_to_first(mut state: TextEditState):
    if te_has_selection(state):
        _sortselection(state)
        state.cursor = state.select_start
        state.select_end = state.select_start
        state.has_preferred_x = False


def _move_to_last(s: String, mut state: TextEditState):
    if te_has_selection(state):
        _sortselection(state)
        te_clamp(s, state)
        state.cursor = state.select_end
        state.select_start = state.select_end
        state.has_preferred_x = False


def _is_word_boundary(s: String, idx: Int32) -> Bool:
    if idx <= 0:
        return True
    return _is_space(te_getchar(s, idx - 1)) and not _is_space(te_getchar(s, idx))


def _move_word_left(s: String, c0: Int32) -> Int32:
    var c = c0 - 1
    while c >= 0 and not _is_word_boundary(s, c):
        c -= 1
    if c < 0:
        c = 0
    return c


def _move_word_right(s: String, c0: Int32) -> Int32:
    var n = te_stringlen(s)
    var c = c0 + 1
    while c < n and not _is_word_boundary(s, c):
        c += 1
    if c > n:
        c = n
    return c


def _prep_selection_at_cursor(mut state: TextEditState):
    if not te_has_selection(state):
        state.select_start = state.cursor
        state.select_end = state.cursor
    else:
        state.cursor = state.select_end


# ============================================================================
# Mouse (single-line: uniform char advance)
# ============================================================================


def te_locate_coord(s: String, x: Float32, char_advance: Float32) -> Int32:
    """Nearest character boundary to display x (single-line, uniform
    advance). Rounds to the nearest boundary like stb's per-char w/2 test."""
    var n = te_stringlen(s)
    if char_advance <= 0.0:
        return 0
    var idxf = floor(x / char_advance + 0.5)
    var idx = Int32(idxf)
    if idx < 0:
        idx = 0
    if idx > n:
        idx = n
    return idx


def te_click(s: String, mut state: TextEditState, x: Float32, char_advance: Float32):
    """Mouse-down: move cursor to x, collapse selection (stb
    stb_textedit_click; y ignored in single-line)."""
    state.cursor = te_locate_coord(s, x, char_advance)
    state.select_start = state.cursor
    state.select_end = state.cursor
    state.has_preferred_x = False


def te_drag(s: String, mut state: TextEditState, x: Float32, char_advance: Float32):
    """Mouse-drag: extend selection end to x (stb stb_textedit_drag)."""
    if state.select_start == state.select_end:
        state.select_start = state.cursor
    var p = te_locate_coord(s, x, char_advance)
    state.cursor = p
    state.select_end = p


# ============================================================================
# Cut / paste
# ============================================================================


def te_cut(mut s: String, mut state: TextEditState) -> Bool:
    """Delete the current selection (stb stb_textedit_cut). Caller should
    copy the selection to the clipboard FIRST. Returns True if there was a
    selection to cut."""
    if te_has_selection(state):
        te_delete_selection(s, state)
        state.has_preferred_x = False
        return True
    return False


def te_paste(mut s: String, mut state: TextEditState, text: List[UInt8]) -> Bool:
    """Replace selection (if any) with `text` at the cursor (stb
    stb_textedit_paste_internal)."""
    var n = Int32(len(text))
    te_clamp(s, state)
    te_delete_selection(s, state)
    if te_insertchars(s, state.cursor, text, n):
        _makeundo_insert(state, state.cursor, n)
        state.cursor += n
        state.has_preferred_x = False
        return True
    return False


# ============================================================================
# Character insertion (stb key() default case)
# ============================================================================


def te_insert_char(mut s: String, mut state: TextEditState, ch: UInt8):
    """Insert one byte at the cursor, honoring insert/overwrite mode and
    replacing the active selection. In single-line mode a newline byte is
    ignored."""
    if ch == 0x0A and state.single_line:
        return

    if state.insert_mode and not te_has_selection(state) and state.cursor < te_stringlen(s):
        # Overwrite mode: replace the char under the cursor.
        _makeundo_replace(s, state, state.cursor, 1, 1)
        te_deletechars(s, state.cursor, 1)
        if te_insertchars(s, state.cursor, _single_char_list(ch), 1):
            state.cursor += 1
            state.has_preferred_x = False
    else:
        te_delete_selection(s, state)
        if te_insertchars(s, state.cursor, _single_char_list(ch), 1):
            _makeundo_insert(state, state.cursor, 1)
            state.cursor += 1
            state.has_preferred_x = False


# ============================================================================
# Key handling (stb stb_textedit_key, single-line subset)
# ============================================================================


def te_key(mut s: String, mut state: TextEditState, key: Int32):
    """Process one control key (NOT character insertion — use
    te_insert_char for printable input). `key` is a TE_K_* value, optionally
    OR'd with TE_K_SHIFT to extend the selection."""
    var shift = (key & TE_K_SHIFT) != 0
    var base = key & ~TE_K_SHIFT

    # Single-line: up/down behave as left/right (stb redirect).
    if base == TE_K_UP:
        base = TE_K_LEFT
    elif base == TE_K_DOWN:
        base = TE_K_RIGHT

    if base == TE_K_LEFT:
        if shift:
            te_clamp(s, state)
            _prep_selection_at_cursor(state)
            if state.select_end > 0:
                state.select_end -= 1
            state.cursor = state.select_end
            state.has_preferred_x = False
        else:
            if te_has_selection(state):
                _move_to_first(state)
            elif state.cursor > 0:
                state.cursor -= 1
            state.has_preferred_x = False

    elif base == TE_K_RIGHT:
        if shift:
            _prep_selection_at_cursor(state)
            state.select_end += 1
            te_clamp(s, state)
            state.cursor = state.select_end
            state.has_preferred_x = False
        else:
            if te_has_selection(state):
                _move_to_last(s, state)
            else:
                state.cursor += 1
            te_clamp(s, state)
            state.has_preferred_x = False

    elif base == TE_K_WORDLEFT:
        if shift:
            if not te_has_selection(state):
                _prep_selection_at_cursor(state)
            state.cursor = _move_word_left(s, state.cursor)
            state.select_end = state.cursor
            te_clamp(s, state)
        else:
            if te_has_selection(state):
                _move_to_first(state)
            else:
                state.cursor = _move_word_left(s, state.cursor)
                te_clamp(s, state)

    elif base == TE_K_WORDRIGHT:
        if shift:
            if not te_has_selection(state):
                _prep_selection_at_cursor(state)
            state.cursor = _move_word_right(s, state.cursor)
            state.select_end = state.cursor
            te_clamp(s, state)
        else:
            if te_has_selection(state):
                _move_to_last(s, state)
            else:
                state.cursor = _move_word_right(s, state.cursor)
                te_clamp(s, state)

    elif base == TE_K_DELETE:
        if te_has_selection(state):
            te_delete_selection(s, state)
        else:
            var n = te_stringlen(s)
            if state.cursor < n:
                _delete(s, state, state.cursor, 1)
        state.has_preferred_x = False

    elif base == TE_K_BACKSPACE:
        if te_has_selection(state):
            te_delete_selection(s, state)
        else:
            te_clamp(s, state)
            if state.cursor > 0:
                _delete(s, state, state.cursor - 1, 1)
                state.cursor -= 1
        state.has_preferred_x = False

    elif base == TE_K_TEXTSTART:
        if shift:
            _prep_selection_at_cursor(state)
            state.cursor = 0
            state.select_end = 0
        else:
            state.cursor = 0
            state.select_start = 0
            state.select_end = 0
        state.has_preferred_x = False

    elif base == TE_K_TEXTEND:
        var n = te_stringlen(s)
        if shift:
            _prep_selection_at_cursor(state)
            state.cursor = n
            state.select_end = n
        else:
            state.cursor = n
            state.select_start = 0
            state.select_end = 0
        state.has_preferred_x = False

    elif base == TE_K_LINESTART:
        # Single-line: line start == text start.
        te_clamp(s, state)
        if shift:
            _prep_selection_at_cursor(state)
            state.cursor = 0
            state.select_end = state.cursor
        else:
            _move_to_first(state)
            state.cursor = 0
        state.has_preferred_x = False

    elif base == TE_K_LINEEND:
        var n = te_stringlen(s)
        te_clamp(s, state)
        if shift:
            _prep_selection_at_cursor(state)
            state.cursor = n
            state.select_end = state.cursor
        else:
            _move_to_first(state)
            state.cursor = n
        state.has_preferred_x = False

    elif base == TE_K_UNDO:
        _undo(s, state)
        state.has_preferred_x = False

    elif base == TE_K_REDO:
        _redo(s, state)
        state.has_preferred_x = False


# ============================================================================
# Undo / redo (stb undo processing)
# ============================================================================


def _flush_redo(mut u: UndoState):
    u.redo_point = Int32(TE_UNDOSTATECOUNT)
    u.redo_char_point = Int32(TE_UNDOCHARCOUNT)


def _discard_undo(mut u: UndoState):
    if u.undo_point > 0:
        if u.undo_rec[0].char_storage >= 0:
            var n = Int(u.undo_rec[0].insert_length)
            u.undo_char_point -= Int32(n)
            _move_chars(u.undo_char, 0, n, Int(u.undo_char_point))
            for i in range(Int(u.undo_point)):
                if u.undo_rec[i].char_storage >= 0:
                    u.undo_rec[i].char_storage -= Int32(n)
        u.undo_point -= 1
        _move_records(u.undo_rec, 0, 1, Int(u.undo_point))


def _discard_redo(mut u: UndoState):
    var k = TE_UNDOSTATECOUNT - 1
    if Int(u.redo_point) <= k:
        if u.undo_rec[k].char_storage >= 0:
            var n = Int(u.undo_rec[k].insert_length)
            u.redo_char_point += Int32(n)
            _move_chars(
                u.undo_char,
                Int(u.redo_char_point),
                Int(u.redo_char_point) - n,
                TE_UNDOCHARCOUNT - Int(u.redo_char_point),
            )
            for i in range(Int(u.redo_point), k):
                if u.undo_rec[i].char_storage >= 0:
                    u.undo_rec[i].char_storage += Int32(n)
        _move_records(
            u.undo_rec,
            Int(u.redo_point) + 1,
            Int(u.redo_point),
            TE_UNDOSTATECOUNT - Int(u.redo_point),
        )
        u.redo_point += 1


def _create_undo_record(mut u: UndoState, numchars: Int32) -> Int32:
    """Allocate an undo record slot. Returns its index in undo_rec, or -1 if
    the characters can't possibly fit (undo disabled for this op)."""
    _flush_redo(u)
    if Int(u.undo_point) == TE_UNDOSTATECOUNT:
        _discard_undo(u)
    if Int(numchars) > TE_UNDOCHARCOUNT:
        u.undo_point = 0
        u.undo_char_point = 0
        return -1
    while Int(u.undo_char_point) + Int(numchars) > TE_UNDOCHARCOUNT:
        _discard_undo(u)
    var idx = u.undo_point
    u.undo_point += 1
    return idx


def _createundo(mut u: UndoState, pos: Int32, insert_len: Int32, delete_len: Int32) -> Int32:
    """Create an undo record (stb stb_text_createundo). Returns the
    char_storage offset into undo_char where the caller should write
    `insert_len` chars, or -1 if there are no chars to store (or alloc
    failed)."""
    var ridx = _create_undo_record(u, insert_len)
    if ridx < 0:
        return -1
    u.undo_rec[Int(ridx)].where = pos
    u.undo_rec[Int(ridx)].insert_length = insert_len
    u.undo_rec[Int(ridx)].delete_length = delete_len
    if insert_len == 0:
        u.undo_rec[Int(ridx)].char_storage = -1
        return -1
    else:
        var storage = u.undo_char_point
        u.undo_rec[Int(ridx)].char_storage = storage
        u.undo_char_point += insert_len
        return storage


def _undo(mut s: String, mut state: TextEditState):
    if state.undostate.undo_point == 0:
        return

    # Snapshot the undo record (stb copies `u` by value before mutating).
    var u = state.undostate.undo_rec[Int(state.undostate.undo_point) - 1].copy()
    var ridx = Int(state.undostate.redo_point) - 1
    state.undostate.undo_rec[ridx].char_storage = -1
    state.undostate.undo_rec[ridx].insert_length = u.delete_length
    state.undostate.undo_rec[ridx].delete_length = u.insert_length
    state.undostate.undo_rec[ridx].where = u.where

    if u.delete_length != 0:
        if Int(state.undostate.undo_char_point) + Int(u.delete_length) >= TE_UNDOCHARCOUNT:
            state.undostate.undo_rec[ridx].insert_length = 0
        else:
            while Int(state.undostate.undo_char_point) + Int(u.delete_length) > Int(state.undostate.redo_char_point):
                if Int(state.undostate.redo_point) == TE_UNDOSTATECOUNT:
                    return
                _discard_redo(state.undostate)
            ridx = Int(state.undostate.redo_point) - 1
            var storage = state.undostate.redo_char_point - u.delete_length
            state.undostate.undo_rec[ridx].char_storage = storage
            state.undostate.redo_char_point = storage
            for i in range(Int(u.delete_length)):
                state.undostate.undo_char[Int(storage) + i] = te_getchar(s, u.where + Int32(i))
        te_deletechars(s, u.where, u.delete_length)

    if u.insert_length != 0:
        var src = _slice_chars(state.undostate.undo_char, u.char_storage, u.insert_length)
        _ = te_insertchars(s, u.where, src, u.insert_length)
        state.undostate.undo_char_point -= u.insert_length

    state.cursor = u.where + u.insert_length
    state.undostate.undo_point -= 1
    state.undostate.redo_point -= 1


def _redo(mut s: String, mut state: TextEditState):
    if Int(state.undostate.redo_point) == TE_UNDOSTATECOUNT:
        return

    var uidx = Int(state.undostate.undo_point)
    # Snapshot the redo record by value (stb copies `r`).
    var r = state.undostate.undo_rec[Int(state.undostate.redo_point)].copy()

    state.undostate.undo_rec[uidx].delete_length = r.insert_length
    state.undostate.undo_rec[uidx].insert_length = r.delete_length
    state.undostate.undo_rec[uidx].where = r.where
    state.undostate.undo_rec[uidx].char_storage = -1

    if r.delete_length != 0:
        if Int(state.undostate.undo_char_point) + Int(state.undostate.undo_rec[uidx].insert_length) > Int(state.undostate.redo_char_point):
            state.undostate.undo_rec[uidx].insert_length = 0
            state.undostate.undo_rec[uidx].delete_length = 0
        else:
            var storage = state.undostate.undo_char_point
            state.undostate.undo_rec[uidx].char_storage = storage
            var ilen = state.undostate.undo_rec[uidx].insert_length
            state.undostate.undo_char_point += ilen
            for i in range(Int(ilen)):
                state.undostate.undo_char[Int(storage) + i] = te_getchar(s, r.where + Int32(i))
        te_deletechars(s, r.where, r.delete_length)

    if r.insert_length != 0:
        var src = _slice_chars(state.undostate.undo_char, r.char_storage, r.insert_length)
        _ = te_insertchars(s, r.where, src, r.insert_length)
        state.undostate.redo_char_point += r.insert_length

    state.cursor = r.where + r.insert_length
    state.undostate.undo_point += 1
    state.undostate.redo_point += 1


def _makeundo_insert(mut state: TextEditState, where: Int32, length: Int32):
    _ = _createundo(state.undostate, where, 0, length)


def _makeundo_delete(mut s: String, mut state: TextEditState, where: Int32, length: Int32):
    var storage = _createundo(state.undostate, where, length, 0)
    if storage >= 0:
        for i in range(Int(length)):
            state.undostate.undo_char[Int(storage) + i] = te_getchar(s, where + Int32(i))


def _makeundo_replace(mut s: String, mut state: TextEditState, where: Int32, old_length: Int32, new_length: Int32):
    var storage = _createundo(state.undostate, where, old_length, new_length)
    if storage >= 0:
        for i in range(Int(old_length)):
            state.undostate.undo_char[Int(storage) + i] = te_getchar(s, where + Int32(i))
