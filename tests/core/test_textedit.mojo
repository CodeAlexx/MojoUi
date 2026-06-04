"""Smoke tests for the stb_textedit single-line port (mojoui/core/textedit.mojo).

Run: `pixi run test-textedit`

These exercise the engine directly (no FFI, no Context) — String buffer +
TextEditState + plain calls. Coverage: insertion + cursor advance, backspace,
delete, left/right + shift-selection, type-over-selection, word movement,
home/end, text start/end, cut, paste, and the undo/redo stack (single + multi-
edit, redo-invalidation-on-new-edit), plus click/drag mouse positioning.
"""

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


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _eq(s: String, want: String, ctx: String) raises:
    if s != want:
        _fail(ctx + ": expected [" + want + "] got [" + s + "]")


def _eqi(got: Int32, want: Int, ctx: String) raises:
    if Int(got) != want:
        _fail(ctx + ": expected " + String(want) + " got " + String(Int(got)))


def _type(mut s: String, mut st: TextEditState, text: String):
    """Type each byte of `text` through te_insert_char."""
    var ptr = text.unsafe_ptr()
    for i in range(text.byte_length()):
        te_insert_char(s, st, ptr[i])


# ----------------------------------------------------------------------------


def test_insert_advances_cursor() raises:
    var s = String("")
    var st = TextEditState(single_line=True)
    _type(s, st, String("abc"))
    _eq(s, String("abc"), "insert")
    _eqi(st.cursor, 3, "cursor after insert")


def test_backspace() raises:
    var s = String("")
    var st = TextEditState(single_line=True)
    _type(s, st, String("abc"))
    te_key(s, st, TE_K_BACKSPACE)
    _eq(s, String("ab"), "backspace text")
    _eqi(st.cursor, 2, "backspace cursor")
    # backspace at start is a no-op
    te_key(s, st, TE_K_TEXTSTART)
    te_key(s, st, TE_K_BACKSPACE)
    _eq(s, String("ab"), "backspace at start no-op")
    _eqi(st.cursor, 0, "cursor still 0")


def test_delete_forward() raises:
    var s = String("abc")
    var st = TextEditState(single_line=True)
    st.cursor = 0
    te_key(s, st, TE_K_DELETE)
    _eq(s, String("bc"), "delete forward")
    _eqi(st.cursor, 0, "delete keeps cursor")


def test_left_right_movement() raises:
    var s = String("abc")
    var st = TextEditState(single_line=True)
    st.cursor = 3
    te_key(s, st, TE_K_LEFT)
    _eqi(st.cursor, 2, "left")
    te_key(s, st, TE_K_LEFT)
    te_key(s, st, TE_K_LEFT)
    te_key(s, st, TE_K_LEFT)  # clamp at 0
    _eqi(st.cursor, 0, "left clamps at 0")
    te_key(s, st, TE_K_RIGHT)
    _eqi(st.cursor, 1, "right")
    # up/down redirect to left/right in single-line
    te_key(s, st, TE_K_DOWN)
    _eqi(st.cursor, 2, "down acts as right")
    te_key(s, st, TE_K_UP)
    _eqi(st.cursor, 1, "up acts as left")


def test_shift_arrow_selection() raises:
    var s = String("hello")
    var st = TextEditState(single_line=True)
    st.cursor = 0
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    if not te_has_selection(st):
        _fail("shift+right should create a selection")
    _eqi(st.select_start, 0, "sel start")
    _eqi(st.select_end, 2, "sel end")
    _eqi(st.cursor, 2, "cursor at sel end")
    # shrink with shift+left
    te_key(s, st, TE_K_LEFT | TE_K_SHIFT)
    _eqi(st.select_end, 1, "sel end after shift+left")


def test_type_over_selection_replaces() raises:
    var s = String("hello")
    var st = TextEditState(single_line=True)
    # select "hel" (0..3)
    st.cursor = 0
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_insert_char(s, st, UInt8(ord("X")))
    _eq(s, String("Xlo"), "type over selection")
    _eqi(st.cursor, 1, "cursor after replace")
    if te_has_selection(st):
        _fail("selection should be cleared after type-over")


def test_word_movement() raises:
    var s = String("foo bar baz")
    var st = TextEditState(single_line=True)
    st.cursor = 0
    te_key(s, st, TE_K_WORDRIGHT)
    # word-right from 0 lands at start of "bar" (index 4)
    _eqi(st.cursor, 4, "wordright to 'bar'")
    te_key(s, st, TE_K_WORDRIGHT)
    _eqi(st.cursor, 8, "wordright to 'baz'")
    te_key(s, st, TE_K_WORDLEFT)
    _eqi(st.cursor, 4, "wordleft back to 'bar'")


def test_home_end_textstart_textend() raises:
    var s = String("hello world")
    var st = TextEditState(single_line=True)
    st.cursor = 5
    te_key(s, st, TE_K_LINEEND)
    _eqi(st.cursor, 11, "End → text length (single line)")
    te_key(s, st, TE_K_LINESTART)
    _eqi(st.cursor, 0, "Home → 0 (single line)")
    te_key(s, st, TE_K_TEXTEND)
    _eqi(st.cursor, 11, "Ctrl+End → len")
    te_key(s, st, TE_K_TEXTSTART)
    _eqi(st.cursor, 0, "Ctrl+Home → 0")


def test_cut() raises:
    var s = String("hello")
    var st = TextEditState(single_line=True)
    st.cursor = 0
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)  # select "he"
    var did = te_cut(s, st)
    if not did:
        _fail("cut should report True when a selection exists")
    _eq(s, String("llo"), "cut removes selection")
    # cut with no selection → False, no change
    var did2 = te_cut(s, st)
    if did2:
        _fail("cut with no selection should be False")
    _eq(s, String("llo"), "cut no-op leaves buffer")


def test_paste() raises:
    var s = String("ac")
    var st = TextEditState(single_line=True)
    st.cursor = 1
    var ins = List[UInt8]()
    ins.append(UInt8(ord("X")))
    ins.append(UInt8(ord("Y")))
    var ok = te_paste(s, st, ins)
    if not ok:
        _fail("paste should succeed")
    _eq(s, String("aXYc"), "paste at cursor")
    _eqi(st.cursor, 3, "cursor after paste")


def test_paste_over_selection() raises:
    var s = String("abcd")
    var st = TextEditState(single_line=True)
    # select "bc" (1..3)
    st.cursor = 1
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    var ins = List[UInt8]()
    ins.append(UInt8(ord("Z")))
    _ = te_paste(s, st, ins)
    _eq(s, String("aZd"), "paste replaces selection")


def test_undo_single_insert() raises:
    var s = String("")
    var st = TextEditState(single_line=True)
    _type(s, st, String("hi"))
    _eq(s, String("hi"), "before undo")
    te_key(s, st, TE_K_UNDO)
    te_key(s, st, TE_K_UNDO)
    _eq(s, String(""), "undo both inserts")


def test_undo_redo_roundtrip() raises:
    var s = String("")
    var st = TextEditState(single_line=True)
    _type(s, st, String("abc"))
    # 3 inserts → 3 undos back to empty
    te_key(s, st, TE_K_UNDO)
    _eq(s, String("ab"), "undo 1")
    te_key(s, st, TE_K_UNDO)
    _eq(s, String("a"), "undo 2")
    te_key(s, st, TE_K_REDO)
    _eq(s, String("ab"), "redo 1")
    te_key(s, st, TE_K_REDO)
    _eq(s, String("abc"), "redo 2")


def test_undo_delete() raises:
    var s = String("hello")
    var st = TextEditState(single_line=True)
    st.cursor = 5
    te_key(s, st, TE_K_BACKSPACE)  # delete 'o'
    te_key(s, st, TE_K_BACKSPACE)  # delete 'l'
    _eq(s, String("hel"), "after two backspaces")
    te_key(s, st, TE_K_UNDO)
    _eq(s, String("hell"), "undo restores 'l'")
    te_key(s, st, TE_K_UNDO)
    _eq(s, String("hello"), "undo restores 'o'")
    te_key(s, st, TE_K_REDO)
    _eq(s, String("hell"), "redo removes 'o' again")


def test_undo_after_selection_replace() raises:
    var s = String("hello")
    var st = TextEditState(single_line=True)
    # select "hel", type X → "Xlo"
    st.cursor = 0
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_key(s, st, TE_K_RIGHT | TE_K_SHIFT)
    te_insert_char(s, st, UInt8(ord("X")))
    _eq(s, String("Xlo"), "replaced")
    # undo the insert of X, then undo the deletion of "hel"
    te_key(s, st, TE_K_UNDO)
    te_key(s, st, TE_K_UNDO)
    _eq(s, String("hello"), "undo restores original after selection-replace")


def test_new_edit_invalidates_redo() raises:
    var s = String("")
    var st = TextEditState(single_line=True)
    _type(s, st, String("ab"))
    te_key(s, st, TE_K_UNDO)        # → "a"
    _eq(s, String("a"), "after undo")
    _type(s, st, String("Z"))       # new edit → "aZ", redo invalidated
    _eq(s, String("aZ"), "after new edit")
    te_key(s, st, TE_K_REDO)        # redo should do nothing now
    _eq(s, String("aZ"), "redo after new edit is a no-op")


def test_click_positions_cursor() raises:
    var s = String("abcdef")
    var st = TextEditState(single_line=True)
    # uniform advance 10px. Click at x=25 → nearest boundary round(25/10)=3.
    te_click(s, st, 25.0, 10.0)
    _eqi(st.cursor, 3, "click positions cursor at boundary 3")
    if te_has_selection(st):
        _fail("click should collapse selection")
    # click beyond end clamps to len
    te_click(s, st, 999.0, 10.0)
    _eqi(st.cursor, 6, "click beyond end clamps to len")


def test_drag_extends_selection() raises:
    var s = String("abcdef")
    var st = TextEditState(single_line=True)
    te_click(s, st, 5.0, 10.0)   # cursor → round(0.5)=1? round(5/10+0.5)=1
    te_drag(s, st, 45.0, 10.0)   # drag to round(4.5+0.5)=5
    if not te_has_selection(st):
        _fail("drag should create a selection")
    _eqi(st.select_end, 5, "drag selection end")


def main() raises:
    test_insert_advances_cursor()
    test_backspace()
    test_delete_forward()
    test_left_right_movement()
    test_shift_arrow_selection()
    test_type_over_selection_replaces()
    test_word_movement()
    test_home_end_textstart_textend()
    test_cut()
    test_paste()
    test_paste_over_selection()
    test_undo_single_insert()
    test_undo_redo_roundtrip()
    test_undo_delete()
    test_undo_after_selection_replace()
    test_new_edit_invalidates_redo()
    test_click_positions_cursor()
    test_drag_extends_selection()
    print("PASS: textedit core smoke tests (18 tests)")
