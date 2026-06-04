"""Tests for `mojoui/core/multiline_edit.mojo` — the line-array multi-line
editing engine (M8, 2026-05-28).

Pure-Mojo / FFI-free → runs under `mojo run` (no build-then-run needed).
Covers insert + cursor, newline splitting, type-replaces-selection, backspace
(within line / merge at col0), forward delete (within line / merge at eol),
left/right across line boundaries, up/down with preferred-col clamping,
home/end, doc-start/end, shift-arrow selection across rows, select-all,
selected_text across rows, cut/copy/paste (single + multi-line), set_text/text
round-trip, and the empty-doc >= 1 line invariant.

Run: `pixi run test-multiline-edit`
"""

from mojoui.core.multiline_edit import (
    MultiLineState,
    ml_insert_text, ml_insert_newline, ml_backspace, ml_delete,
    ml_move_left, ml_move_right, ml_move_up, ml_move_down,
    ml_move_home, ml_move_end, ml_move_doc_start, ml_move_doc_end,
    ml_select_all, ml_set_cursor, ml_selected_text, ml_delete_selection,
    ml_cut, ml_copy, ml_paste,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _expect_str(got: String, want: String, ctx: String) raises:
    if got != want:
        _fail(ctx + String(": expected '") + want + String("' got '") + got + String("'"))


def _expect_int(got: Int32, want: Int32, ctx: String) raises:
    if got != want:
        _fail(ctx + String(": expected ") + String(Int(want)) + String(" got ") + String(Int(got)))


def test_insert_and_cursor() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello"))
    _expect_str(st.text(), String("hello"), "insert basic")
    _expect_int(st.cursor_row, 0, "insert row")
    _expect_int(st.cursor_col, 5, "insert col")
    _expect_int(Int32(len(st.lines)), 1, "insert nlines")


def test_newline_splits_line() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("abcd"))
    ml_move_left(st, False)  # cursor at col 3
    ml_insert_newline(st)
    _expect_int(Int32(len(st.lines)), 2, "newline nlines")
    _expect_str(st.lines[0], String("abc"), "newline line0")
    _expect_str(st.lines[1], String("d"), "newline line1")
    _expect_int(st.cursor_row, 1, "newline cursor row")
    _expect_int(st.cursor_col, 0, "newline cursor col")


def test_type_replaces_selection() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello"))
    ml_set_cursor(st, 0, 1, False)
    ml_set_cursor(st, 0, 4, True)  # select "ell"
    _expect_str(ml_selected_text(st), String("ell"), "type-replace selection")
    ml_insert_text(st, String("X"))
    _expect_str(st.text(), String("hXo"), "type-replace result")
    _expect_int(st.cursor_col, 2, "type-replace cursor")


def test_backspace_within_line() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("abc"))
    ml_backspace(st)
    _expect_str(st.text(), String("ab"), "backspace within line")
    _expect_int(st.cursor_col, 2, "backspace cursor")


def test_backspace_at_col0_merges() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab\ncd"))
    ml_set_cursor(st, 1, 0, False)  # start of "cd"
    ml_backspace(st)
    _expect_int(Int32(len(st.lines)), 1, "merge nlines")
    _expect_str(st.text(), String("abcd"), "merge result")
    _expect_int(st.cursor_row, 0, "merge cursor row")
    _expect_int(st.cursor_col, 2, "merge cursor col (join point)")


def test_delete_at_eol_merges() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab\ncd"))
    ml_set_cursor(st, 0, 2, False)  # end of "ab"
    ml_delete(st)
    _expect_int(Int32(len(st.lines)), 1, "fwd-merge nlines")
    _expect_str(st.text(), String("abcd"), "fwd-merge result")
    _expect_int(st.cursor_row, 0, "fwd-merge cursor row")
    _expect_int(st.cursor_col, 2, "fwd-merge cursor col")


def test_delete_within_line() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("abc"))
    ml_set_cursor(st, 0, 1, False)
    ml_delete(st)
    _expect_str(st.text(), String("ac"), "fwd-delete within line")


def test_left_right_across_boundaries() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab\ncd"))
    ml_set_cursor(st, 1, 0, False)  # start of "cd"
    ml_move_left(st, False)         # wrap to end of "ab"
    _expect_int(st.cursor_row, 0, "left-wrap row")
    _expect_int(st.cursor_col, 2, "left-wrap col")
    ml_move_right(st, False)        # wrap forward to start of "cd"
    _expect_int(st.cursor_row, 1, "right-wrap row")
    _expect_int(st.cursor_col, 0, "right-wrap col")


def test_up_down_preferred_col() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello\nhi\nworld"))
    # Cursor at end of "world" (row 2, col 5). preferred_col = 5.
    ml_move_up(st, False)  # row 1 "hi" len 2 → clamp col to 2
    _expect_int(st.cursor_row, 1, "up row")
    _expect_int(st.cursor_col, 2, "up clamped col")
    ml_move_up(st, False)  # row 0 "hello" → preferred 5 restored
    _expect_int(st.cursor_row, 0, "up2 row")
    _expect_int(st.cursor_col, 5, "up2 preferred restored")
    ml_move_down(st, False)  # back to "hi" clamp to 2
    _expect_int(st.cursor_col, 2, "down clamped col")
    ml_move_down(st, False)  # "world" preferred 5
    _expect_int(st.cursor_col, 5, "down preferred restored")


def test_home_end() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello\nworld"))
    ml_set_cursor(st, 1, 3, False)
    ml_move_home(st, False)
    _expect_int(st.cursor_col, 0, "home col")
    _expect_int(st.cursor_row, 1, "home row")
    ml_move_end(st, False)
    _expect_int(st.cursor_col, 5, "end col")


def test_doc_start_end() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello\nworld"))
    ml_move_doc_start(st, False)
    _expect_int(st.cursor_row, 0, "doc-start row")
    _expect_int(st.cursor_col, 0, "doc-start col")
    ml_move_doc_end(st, False)
    _expect_int(st.cursor_row, 1, "doc-end row")
    _expect_int(st.cursor_col, 5, "doc-end col")


def test_shift_arrow_selection_across_rows() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab\ncd"))
    ml_set_cursor(st, 0, 1, False)  # cursor at "a|b"
    ml_move_down(st, True)          # extend down to row1
    if not st.has_selection():
        _fail("shift-down should produce a selection")
    # Selection from (0,1) to (1,1) → "b\nc"
    _expect_str(ml_selected_text(st), String("b\nc"), "shift-down selection text")


def test_select_all() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab\ncd\nef"))
    ml_select_all(st)
    _expect_str(ml_selected_text(st), String("ab\ncd\nef"), "select-all text")
    _expect_int(st.cursor_row, 2, "select-all cursor row")
    _expect_int(st.cursor_col, 2, "select-all cursor col")


def test_selected_text_multi_row() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello\nbig\nworld"))
    ml_set_cursor(st, 0, 2, False)  # "he|llo"
    ml_set_cursor(st, 2, 3, True)   # extend to "wor|ld"
    _expect_str(ml_selected_text(st), String("llo\nbig\nwor"), "multi-row selection")


def test_cut() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello"))
    ml_set_cursor(st, 0, 1, False)
    ml_set_cursor(st, 0, 4, True)  # select "ell"
    var cut = ml_cut(st)
    _expect_str(cut, String("ell"), "cut returns selection")
    _expect_str(st.text(), String("ho"), "cut removes selection")
    if st.has_selection():
        _fail("cut should collapse selection")


def test_copy() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("hello"))
    ml_set_cursor(st, 0, 0, False)
    ml_set_cursor(st, 0, 3, True)
    var c = ml_copy(st)
    _expect_str(c, String("hel"), "copy returns selection")
    _expect_str(st.text(), String("hello"), "copy does not modify")


def test_paste_single_and_multi() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("ab"))
    ml_paste(st, String("XY"))
    _expect_str(st.text(), String("abXY"), "paste single-line")
    ml_paste(st, String("1\n2"))
    _expect_int(Int32(len(st.lines)), 2, "paste multi-line nlines")
    _expect_str(st.text(), String("abXY1\n2"), "paste multi-line result")
    _expect_int(st.cursor_row, 1, "paste multi cursor row")
    _expect_int(st.cursor_col, 1, "paste multi cursor col")


def test_set_text_text_roundtrip() raises:
    var st = MultiLineState()
    st.set_text(String("one\ntwo\nthree"))
    _expect_int(Int32(len(st.lines)), 3, "set_text nlines")
    _expect_str(st.text(), String("one\ntwo\nthree"), "round-trip")
    _expect_int(st.cursor_row, 0, "set_text cursor row")
    _expect_int(st.cursor_col, 0, "set_text cursor col")


def test_empty_doc_invariant() raises:
    var st = MultiLineState()
    _expect_int(Int32(len(st.lines)), 1, "fresh doc has 1 line")
    ml_backspace(st)  # nothing to delete
    _expect_int(Int32(len(st.lines)), 1, "backspace on empty keeps 1 line")
    ml_delete(st)
    _expect_int(Int32(len(st.lines)), 1, "delete on empty keeps 1 line")
    ml_insert_text(st, String("\n"))  # a lone newline → 2 lines
    _expect_int(Int32(len(st.lines)), 2, "lone newline → 2 lines")
    ml_select_all(st)
    _ = ml_delete_selection(st)
    _expect_int(Int32(len(st.lines)), 1, "delete-all keeps >= 1 line")
    _expect_str(st.text(), String(""), "delete-all empties text")


def test_clear() raises:
    var st = MultiLineState()
    ml_insert_text(st, String("a\nb\nc"))
    st.clear()
    _expect_int(Int32(len(st.lines)), 1, "clear nlines")
    _expect_str(st.text(), String(""), "clear text")


def test_preferred_col_survives_edge_bump() raises:
    """Skeptic M1 regression: vertical movement at a document boundary must
    NOT clobber the sticky preferred column. Doc with a short middle/last
    line; ride the column down past the short line and back up."""
    var st = MultiLineState()
    st.set_text(String("hello\nworldwide\nab"))
    # Establish preferred_col = 5 via horizontal moves from (0,0).
    var k = 0
    while k < 5:
        ml_move_right(st, False)
        k += 1
    _expect_int(st.cursor_col, 5, "start col")
    ml_move_down(st, False)  # → (1,5)
    _expect_int(st.cursor_row, 1, "down1 row")
    _expect_int(st.cursor_col, 5, "down1 col")
    ml_move_down(st, False)  # → (2,2): "ab" clamps col, pref stays 5
    _expect_int(st.cursor_row, 2, "down2 row")
    _expect_int(st.cursor_col, 2, "down2 col")
    ml_move_down(st, False)  # edge bump on last row — must preserve pref=5
    ml_move_up(st, False)    # → (1, min(5, len "worldwide"=9) = 5)
    _expect_int(st.cursor_row, 1, "up row")
    _expect_int(st.cursor_col, 5, "preferred col restored after edge bump")


def test_utf8_roundtrip() raises:
    """Multi-byte UTF-8 content survives set_text/text round-trip and splits
    on '\\n' by line (not by byte). Per-byte cursor ops may still split a
    codepoint — that's the documented limitation; this only guards storage."""
    var st = MultiLineState()
    var s = String("héllo\n中文\nab")
    st.set_text(s)
    _expect_str(st.text(), s, "utf8 roundtrip")
    _expect_int(Int32(len(st.lines)), 3, "utf8 nlines")


def main() raises:
    test_insert_and_cursor()
    test_newline_splits_line()
    test_type_replaces_selection()
    test_backspace_within_line()
    test_backspace_at_col0_merges()
    test_delete_at_eol_merges()
    test_delete_within_line()
    test_left_right_across_boundaries()
    test_up_down_preferred_col()
    test_home_end()
    test_doc_start_end()
    test_shift_arrow_selection_across_rows()
    test_select_all()
    test_selected_text_multi_row()
    test_cut()
    test_copy()
    test_paste_single_and_multi()
    test_set_text_text_roundtrip()
    test_empty_doc_invariant()
    test_clear()
    test_preferred_col_survives_edge_bump()
    test_utf8_roundtrip()
    print("PASS: multiline_edit engine tests (22 tests)")
