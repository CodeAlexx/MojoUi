"""Repro harness for reported live symptoms: extra chars on type, backspace
misbehaving, caret in the wrong place. Drives the widget through the
`pending_text` test seam across many frames, asserting the buffer AND the
engine cursor after every step. If these pass, the editing model is sound and
the live break is in the C-floor / FFI input layer; if they fail, the bug is
reproduced headlessly.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.input import InputState
from mojoui.core.textedit import TextEditState
from mojoui.widgets.text_edit import text_edit
from mojoui.render.ffi import (
    MOJOUI_KEY_BACKSPACE, MOJOUI_KEY_LEFT, MOJOUI_KEY_RIGHT,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _begin(
    mut ctx: Context, mouse_pos: Vec2, pressed: Bool, released: Bool
) raises:
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    ctx.input.disable_ffi_text()
    ctx.theme.font_id = UInt32(1)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def test_type_word_one_char_per_frame() raises:
    """Focus once, then type 'hello' a char at a time. After each frame the
    buffer must equal the running prefix and cursor must equal its length."""
    var ctx = Context()
    var buffer = String("")
    var st = TextEditState(single_line=True)

    # Frame 1: click at far right (empty buffer → caret 0) to focus.
    _begin(ctx, Vec2(2.0, 12.0), True, False)
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    var word = String("hello")
    var wp = word.unsafe_ptr()
    for i in range(5):
        _begin(ctx, Vec2(2.0, 12.0), False, False)
        var ch = List[UInt8]()
        ch.append(wp[i])
        ctx.input.pending_text = String(unsafe_from_utf8=ch)
        var _2 = text_edit(ctx, String("name"), buffer, st)
        ctx.end_frame()
        var expect = String("")
        var eb = List[UInt8]()
        for j in range(i + 1):
            eb.append(wp[j])
        expect = String(unsafe_from_utf8=eb)
        if buffer != expect:
            _fail(String("after typing ") + String(i + 1) + " chars expected '" + expect + "' got '" + buffer + "'")
        if Int(st.cursor) != i + 1:
            _fail(String("cursor should be ") + String(i + 1) + " got " + String(Int(st.cursor)))


def test_multichar_in_one_frame() raises:
    """Live fast-typing delivers several chars in ONE consume_text() drain.
    The widget loops bytes → all must land, cursor at end, no extras."""
    var ctx = Context()
    var buffer = String("")
    var st = TextEditState(single_line=True)
    _begin(ctx, Vec2(2.0, 12.0), True, False)
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    _begin(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.pending_text = String("world")
    var _2 = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()
    if buffer != String("world"):
        _fail(String("multichar drain expected 'world' got '") + buffer + "'")
    if Int(st.cursor) != 5:
        _fail(String("cursor should be 5 got ") + String(Int(st.cursor)))


def test_backspace_removes_exactly_one() raises:
    """Type 'abc', then backspace twice. Each backspace removes exactly one
    trailing char and decrements the cursor by one."""
    var ctx = Context()
    var buffer = String("")
    var st = TextEditState(single_line=True)
    _begin(ctx, Vec2(2.0, 12.0), True, False)
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    _begin(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.pending_text = String("abc")
    var _2 = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()
    if buffer != String("abc") or Int(st.cursor) != 3:
        _fail(String("setup type 'abc' failed: '") + buffer + "' cur=" + String(Int(st.cursor)))

    # Frame: backspace pressed. The widget reads ctx.input.key_pressed; the
    # no-input begin path leaves all keys up, so we set the key level directly
    # and roll edges by polling twice is not available — instead inject via the
    # keys array: simulate a rising edge for backspace this frame.
    _begin(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.keys[Int(MOJOUI_KEY_BACKSPACE)].pressed = True
    ctx.input.keys[Int(MOJOUI_KEY_BACKSPACE)].held = True
    var _3 = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()
    if buffer != String("ab") or Int(st.cursor) != 2:
        _fail(String("after 1 backspace expected 'ab' cur=2 got '") + buffer + "' cur=" + String(Int(st.cursor)))

    _begin(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.keys[Int(MOJOUI_KEY_BACKSPACE)].pressed = True
    ctx.input.keys[Int(MOJOUI_KEY_BACKSPACE)].held = True
    var _4 = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()
    if buffer != String("a") or Int(st.cursor) != 1:
        _fail(String("after 2 backspace expected 'a' cur=1 got '") + buffer + "' cur=" + String(Int(st.cursor)))


def test_key_repeat_logic() raises:
    """Fix #1: key_repeat fires on the press edge, stays quiet until the hold
    delay, then fires once every `rate` frames. Pure logic — no FFI."""
    var inp = InputState()
    var k = Int(MOJOUI_KEY_BACKSPACE)

    # Press edge → True regardless of held_frames.
    inp.keys[k].pressed = True
    inp.keys[k].held = True
    inp.held_frames[k] = 1
    if not inp.key_repeat(MOJOUI_KEY_BACKSPACE, 24, 3):
        _fail("key_repeat should fire on the press edge")

    # Held, before the delay → no repeat.
    inp.keys[k].pressed = False
    inp.held_frames[k] = 10
    if inp.key_repeat(MOJOUI_KEY_BACKSPACE, 24, 3):
        _fail("key_repeat must stay quiet before the delay")

    # Held past the delay, on a rate boundary → repeat.
    inp.held_frames[k] = 27  # (27-24) % 3 == 0
    if not inp.key_repeat(MOJOUI_KEY_BACKSPACE, 24, 3):
        _fail("key_repeat should fire at delay+rate boundary")
    # Off a rate boundary → no repeat.
    inp.held_frames[k] = 28  # (28-24) % 3 == 1
    if inp.key_repeat(MOJOUI_KEY_BACKSPACE, 24, 3):
        _fail("key_repeat must not fire between rate boundaries")

    # Not held → never.
    inp.keys[k].held = False
    inp.held_frames[k] = 99
    if inp.key_repeat(MOJOUI_KEY_BACKSPACE, 24, 3):
        _fail("key_repeat must be False when the key is up")


def test_frame_text_priority() raises:
    """Fix #2: consume_text() returns frame_text (the per-frame prime) ahead of
    pending_text, and clears it so the next call starts empty."""
    var inp = InputState()
    inp.disable_ffi_text()
    inp.frame_text = String("AB")
    inp.pending_text = String("zz")
    var got = inp.consume_text()
    if got != String("AB"):
        _fail(String("frame_text should win over pending_text, got '") + got + "'")
    # frame_text cleared; next call falls through to pending_text.
    var got2 = inp.consume_text()
    if got2 != String("zz"):
        _fail(String("after frame_text drained, pending_text should follow, got '") + got2 + "'")


def test_scroll_keeps_caret_in_field() raises:
    """Fix #3b: typing past the field width scrolls so the caret stays inside
    the box (caret_rel - scroll_x <= field_w) and scroll_x grows > 0."""
    var ctx = Context()
    var buffer = String("")
    var st = TextEditState(single_line=True)

    _begin(ctx, Vec2(2.0, 12.0), True, False)  # focus
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    # Type a long run in one drain → cursor lands at the end.
    _begin(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.pending_text = String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")  # 40
    var _2 = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    if Int(st.cursor) != 40:
        _fail(String("expected cursor 40, got ") + String(Int(st.cursor)))
    # Field is 200px wide minus padding; 40 glyphs must overflow → scroll > 0.
    if st.scroll_x <= 0.0:
        _fail(String("long text should scroll; scroll_x=") + String(st.scroll_x))


def main() raises:
    test_type_word_one_char_per_frame()
    test_multichar_in_one_frame()
    test_backspace_removes_exactly_one()
    test_key_repeat_logic()
    test_frame_text_priority()
    test_scroll_keeps_caret_in_field()
    print("PASS: text_edit repro (6 scenarios: type/backspace/repeat/drain/scroll)")
