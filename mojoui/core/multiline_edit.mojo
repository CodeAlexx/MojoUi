"""Multi-line text-edit engine — pure-Mojo, FFI-free (M8, 2026-05-28).

The single-line counterpart `mojoui/core/textedit.mojo` is a port of
stb_textedit (a gap-buffer + undo-ring + row-walking machine). For multi-line
editing we deliberately use a SIMPLER **line-array model** instead of porting
stb's LAYOUTROW/find_charpos row-walking: the document is `List[String]`
(always >= 1 line), and the cursor is a `(row, col)` pair where `col` is a BYTE
offset into `lines[row]`. Selection is a second `(row, col)` anchor.

Char unit — BYTES (ASCII-exact). Like the single-line engine, per-byte cursor
movement can split a multi-byte UTF-8 codepoint, transiently producing
malformed UTF-8. Codepoint-aware movement is a future refinement. For the
diffusion-UI common case (prompts, filenames, numbers) byte indexing is exact.

Pure / FFI-free: every function takes a `MultiLineState` + plain types. No FFI,
no Context, no rendering. Unit-testable under `mojo run` (the JIT can't dlopen
the C floor); the widget layer (`widgets/text_area.mojo`) does the FFI input +
drawing and drives this engine.

`.copy()` discipline: `String` is implicitly copyable so `List[String]`
indexing reads are fine; the indices are scalars. No `.copy()` needed here.
"""


# ============================================================================
# Byte / line helpers
# ============================================================================


def _line_len(st: MultiLineState, row: Int32) -> Int32:
    """Byte length of line `row` (caller guarantees row in range)."""
    return Int32(st.lines[Int(row)].byte_length())


def _last_row(st: MultiLineState) -> Int32:
    return Int32(len(st.lines)) - 1


def _string_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    var ptr = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(ptr[i])
    return out^


def _split_on_newlines(s: String) -> List[String]:
    """Split `s` on '\\n' bytes; always >= 1 element. A terminal '\\n'
    yields a trailing empty line (so the cursor can land below it)."""
    var lines = List[String]()
    var current = List[UInt8]()
    var ptr = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var b = ptr[i]
        if b == UInt8(10):  # '\n'
            lines.append(String(unsafe_from_utf8=current.copy()))
            current = List[UInt8]()
        else:
            current.append(b)
    lines.append(String(unsafe_from_utf8=current.copy()))
    return lines^


def _byte_substr(s: String, start: Int32, end: Int32) -> String:
    """Bytes [start, end) of `s` as a String (clamped, never raises)."""
    var n = Int(s.byte_length())
    var lo = Int(start)
    var hi = Int(end)
    if lo < 0:
        lo = 0
    if hi > n:
        hi = n
    if lo >= hi:
        return String("")
    var out = List[UInt8](capacity=hi - lo)
    var ptr = s.unsafe_ptr()
    for i in range(lo, hi):
        out.append(ptr[i])
    return String(unsafe_from_utf8=out)


# ============================================================================
# MultiLineState
# ============================================================================


struct MultiLineState(Movable):
    """Per-textarea editing state. Caller owns one per widget and threads it
    across frames. INVARIANT: `lines` always has >= 1 element (empty document
    is `[""]`)."""

    var lines: List[String]
    var cursor_row: Int32
    var cursor_col: Int32   # BYTE offset into lines[cursor_row]
    var sel_row: Int32      # selection anchor (== cursor_* when no selection)
    var sel_col: Int32
    var preferred_col: Int32  # sticky column for up/down movement

    def __init__(out self):
        self.lines = List[String]()
        self.lines.append(String(""))
        self.cursor_row = 0
        self.cursor_col = 0
        self.sel_row = 0
        self.sel_col = 0
        self.preferred_col = 0

    def clear(mut self):
        """Reset to an empty single-line document."""
        self.lines = List[String]()
        self.lines.append(String(""))
        self.cursor_row = 0
        self.cursor_col = 0
        self.sel_row = 0
        self.sel_col = 0
        self.preferred_col = 0

    def text(self) -> String:
        """Lines joined with '\\n'."""
        var out = String("")
        var n = len(self.lines)
        for i in range(n):
            out = out + self.lines[i]
            if i < n - 1:
                out = out + String("\n")
        return out

    def set_text(mut self, s: String):
        """Replace the document with `s` split on '\\n' (always >= 1 line).
        Cursor + anchor collapse to (0, 0)."""
        self.lines = _split_on_newlines(s)
        self.cursor_row = 0
        self.cursor_col = 0
        self.sel_row = 0
        self.sel_col = 0
        self.preferred_col = 0

    def has_selection(self) -> Bool:
        return self.cursor_row != self.sel_row or self.cursor_col != self.sel_col


# ============================================================================
# Clamping
# ============================================================================


def _clamp_cursor(mut st: MultiLineState):
    """Make cursor + anchor valid for the current `lines`."""
    var last = _last_row(st)
    if st.cursor_row < 0:
        st.cursor_row = 0
    if st.cursor_row > last:
        st.cursor_row = last
    var clen = _line_len(st, st.cursor_row)
    if st.cursor_col < 0:
        st.cursor_col = 0
    if st.cursor_col > clen:
        st.cursor_col = clen

    if st.sel_row < 0:
        st.sel_row = 0
    if st.sel_row > last:
        st.sel_row = last
    var slen = _line_len(st, st.sel_row)
    if st.sel_col < 0:
        st.sel_col = 0
    if st.sel_col > slen:
        st.sel_col = slen


def _collapse_anchor(mut st: MultiLineState):
    """Drop the selection: anchor follows the cursor."""
    st.sel_row = st.cursor_row
    st.sel_col = st.cursor_col


# ============================================================================
# Selection ordering / extraction
# ============================================================================


def _is_before(row_a: Int32, col_a: Int32, row_b: Int32, col_b: Int32) -> Bool:
    """True if (row_a, col_a) is strictly before (row_b, col_b)."""
    if row_a != row_b:
        return row_a < row_b
    return col_a < col_b


def ml_selected_text(st: MultiLineState) -> String:
    """The selected span as a String ('' if no selection). Newlines join
    rows."""
    if not st.has_selection():
        return String("")
    # Normalize so (r0,c0) precedes (r1,c1).
    var r0 = st.cursor_row
    var c0 = st.cursor_col
    var r1 = st.sel_row
    var c1 = st.sel_col
    if _is_before(st.sel_row, st.sel_col, st.cursor_row, st.cursor_col):
        r0 = st.sel_row
        c0 = st.sel_col
        r1 = st.cursor_row
        c1 = st.cursor_col

    if r0 == r1:
        return _byte_substr(st.lines[Int(r0)], c0, c1)

    var out = String("")
    # First (partial) line: c0 .. end.
    out = out + _byte_substr(st.lines[Int(r0)], c0, _line_len(st, r0))
    out = out + String("\n")
    # Whole middle lines.
    for r in range(Int(r0) + 1, Int(r1)):
        out = out + st.lines[r]
        out = out + String("\n")
    # Last (partial) line: start .. c1.
    out = out + _byte_substr(st.lines[Int(r1)], 0, c1)
    return out


def ml_delete_selection(mut st: MultiLineState) -> Bool:
    """Remove the selected span; cursor lands at the span start. Returns
    True if there was a selection."""
    if not st.has_selection():
        return False
    var r0 = st.cursor_row
    var c0 = st.cursor_col
    var r1 = st.sel_row
    var c1 = st.sel_col
    if _is_before(st.sel_row, st.sel_col, st.cursor_row, st.cursor_col):
        r0 = st.sel_row
        c0 = st.sel_col
        r1 = st.cursor_row
        c1 = st.cursor_col

    if r0 == r1:
        var head = _byte_substr(st.lines[Int(r0)], 0, c0)
        var tail = _byte_substr(st.lines[Int(r0)], c1, _line_len(st, r0))
        st.lines[Int(r0)] = head + tail
    else:
        var head = _byte_substr(st.lines[Int(r0)], 0, c0)
        var tail = _byte_substr(st.lines[Int(r1)], c1, _line_len(st, r1))
        st.lines[Int(r0)] = head + tail
        # Remove rows r0+1 .. r1 inclusive (rebuild list).
        var rebuilt = List[String]()
        var n = len(st.lines)
        for i in range(n):
            if i <= Int(r0) or i > Int(r1):
                rebuilt.append(st.lines[i])
        st.lines = rebuilt^

    st.cursor_row = r0
    st.cursor_col = c0
    _collapse_anchor(st)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col
    return True


# ============================================================================
# Insertion
# ============================================================================


def ml_insert_text(mut st: MultiLineState, text: String):
    """Replace selection (if any) then insert `text` (splitting on '\\n')
    at the cursor. Cursor ends after the inserted text."""
    _ = ml_delete_selection(st)
    if text.byte_length() == 0:
        return

    var parts = _split_on_newlines(text)
    var row = Int(st.cursor_row)
    var cur = st.lines[row]
    var head = _byte_substr(cur, 0, st.cursor_col)
    var tail = _byte_substr(cur, st.cursor_col, Int32(cur.byte_length()))

    if len(parts) == 1:
        # No newline in inserted text: splice in place.
        st.lines[row] = head + parts[0] + tail
        st.cursor_col = Int32(head.byte_length() + parts[0].byte_length())
    else:
        # First inserted part joins `head`; last joins `tail`; middle parts
        # become standalone lines. Rebuild the list around `row`.
        var n_parts = len(parts)
        var rebuilt = List[String]()
        for i in range(row):
            rebuilt.append(st.lines[i])
        rebuilt.append(head + parts[0])
        for i in range(1, n_parts - 1):
            rebuilt.append(parts[i])
        rebuilt.append(parts[n_parts - 1] + tail)
        for i in range(row + 1, len(st.lines)):
            rebuilt.append(st.lines[i])
        st.lines = rebuilt^
        st.cursor_row = Int32(row + n_parts - 1)
        st.cursor_col = Int32(parts[n_parts - 1].byte_length())

    _collapse_anchor(st)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_insert_newline(mut st: MultiLineState):
    """Split the current line at the cursor into two lines; cursor → start
    of the new lower line. (Replaces selection first.)"""
    _ = ml_delete_selection(st)
    var row = Int(st.cursor_row)
    var cur = st.lines[row]
    var head = _byte_substr(cur, 0, st.cursor_col)
    var tail = _byte_substr(cur, st.cursor_col, Int32(cur.byte_length()))
    st.lines[row] = head
    # Insert `tail` as a new line after `row`.
    var rebuilt = List[String]()
    for i in range(row + 1):
        rebuilt.append(st.lines[i])
    rebuilt.append(tail)
    for i in range(row + 1, len(st.lines)):
        rebuilt.append(st.lines[i])
    st.lines = rebuilt^
    st.cursor_row = Int32(row + 1)
    st.cursor_col = 0
    _collapse_anchor(st)
    _clamp_cursor(st)
    st.preferred_col = 0


# ============================================================================
# Deletion (backspace / forward delete)
# ============================================================================


def ml_backspace(mut st: MultiLineState):
    """If selection: delete it. Else delete the byte before the cursor; at
    col 0 (row > 0) merge with the previous line."""
    if ml_delete_selection(st):
        return
    var row = Int(st.cursor_row)
    if st.cursor_col > 0:
        var cur = st.lines[row]
        var head = _byte_substr(cur, 0, st.cursor_col - 1)
        var tail = _byte_substr(cur, st.cursor_col, Int32(cur.byte_length()))
        st.lines[row] = head + tail
        st.cursor_col -= 1
    elif row > 0:
        # Merge with previous line; cursor lands at the join point.
        var prev = st.lines[row - 1]
        var join = Int32(prev.byte_length())
        var here = st.lines[row]
        st.lines[row - 1] = prev + here
        var rebuilt = List[String]()
        for i in range(len(st.lines)):
            if i != row:
                rebuilt.append(st.lines[i])
        st.lines = rebuilt^
        st.cursor_row = Int32(row - 1)
        st.cursor_col = join
    _collapse_anchor(st)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_delete(mut st: MultiLineState):
    """Forward delete. At end-of-line (row < last) merge the next line up."""
    if ml_delete_selection(st):
        return
    var row = Int(st.cursor_row)
    var clen = _line_len(st, st.cursor_row)
    if st.cursor_col < clen:
        var cur = st.lines[row]
        var head = _byte_substr(cur, 0, st.cursor_col)
        var tail = _byte_substr(cur, st.cursor_col + 1, Int32(cur.byte_length()))
        st.lines[row] = head + tail
    elif row < Int(_last_row(st)):
        # Merge the next line into this one.
        var here = st.lines[row]
        var nxt = st.lines[row + 1]
        st.lines[row] = here + nxt
        var rebuilt = List[String]()
        for i in range(len(st.lines)):
            if i != row + 1:
                rebuilt.append(st.lines[i])
        st.lines = rebuilt^
    _collapse_anchor(st)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


# ============================================================================
# Cursor movement
# ============================================================================


def _maybe_collapse(mut st: MultiLineState, extend: Bool):
    if not extend:
        _collapse_anchor(st)


def ml_move_left(mut st: MultiLineState, extend: Bool):
    if st.cursor_col > 0:
        st.cursor_col -= 1
    elif st.cursor_row > 0:
        st.cursor_row -= 1
        st.cursor_col = _line_len(st, st.cursor_row)
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_move_right(mut st: MultiLineState, extend: Bool):
    var clen = _line_len(st, st.cursor_row)
    if st.cursor_col < clen:
        st.cursor_col += 1
    elif st.cursor_row < _last_row(st):
        st.cursor_row += 1
        st.cursor_col = 0
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_move_up(mut st: MultiLineState, extend: Bool):
    if st.cursor_row > 0:
        st.cursor_row -= 1
        var tlen = _line_len(st, st.cursor_row)
        st.cursor_col = st.preferred_col if st.preferred_col < tlen else tlen
    else:
        # Up on row 0 → line start, but PRESERVE preferred_col so a later
        # down/up restores the sticky column (skeptic M1 fix 2026-05-28).
        st.cursor_col = 0
    _maybe_collapse(st, extend)
    _clamp_cursor(st)


def ml_move_down(mut st: MultiLineState, extend: Bool):
    if st.cursor_row < _last_row(st):
        st.cursor_row += 1
        var tlen = _line_len(st, st.cursor_row)
        st.cursor_col = st.preferred_col if st.preferred_col < tlen else tlen
    else:
        # Down on last row → line end, but PRESERVE preferred_col (skeptic
        # M1 fix 2026-05-28).
        st.cursor_col = _line_len(st, st.cursor_row)
    _maybe_collapse(st, extend)
    _clamp_cursor(st)


def ml_move_home(mut st: MultiLineState, extend: Bool):
    st.cursor_col = 0
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = 0


def ml_move_end(mut st: MultiLineState, extend: Bool):
    st.cursor_col = _line_len(st, st.cursor_row)
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_move_doc_start(mut st: MultiLineState, extend: Bool):
    st.cursor_row = 0
    st.cursor_col = 0
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = 0


def ml_move_doc_end(mut st: MultiLineState, extend: Bool):
    st.cursor_row = _last_row(st)
    st.cursor_col = _line_len(st, st.cursor_row)
    _maybe_collapse(st, extend)
    _clamp_cursor(st)
    st.preferred_col = st.cursor_col


def ml_select_all(mut st: MultiLineState):
    """Anchor = (0, 0); cursor = (lastrow, eol)."""
    st.sel_row = 0
    st.sel_col = 0
    st.cursor_row = _last_row(st)
    st.cursor_col = _line_len(st, st.cursor_row)
    st.preferred_col = st.cursor_col


def ml_set_cursor(mut st: MultiLineState, row: Int32, col: Int32, extend: Bool):
    """Place the cursor at (row, col), clamped. Used by click/drag.
    Non-extend collapses the selection."""
    st.cursor_row = row
    st.cursor_col = col
    _clamp_cursor(st)   # clamp before collapsing so anchor follows clamped pos
    _maybe_collapse(st, extend)
    st.preferred_col = st.cursor_col


# ============================================================================
# Clipboard convenience
# ============================================================================


def ml_copy(st: MultiLineState) -> String:
    return ml_selected_text(st)


def ml_cut(mut st: MultiLineState) -> String:
    var s = ml_selected_text(st)
    _ = ml_delete_selection(st)
    return s


def ml_paste(mut st: MultiLineState, text: String):
    ml_insert_text(st, text)
