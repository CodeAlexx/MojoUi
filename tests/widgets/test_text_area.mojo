"""Smoke tests for `mojoui/widgets/text_area.mojo` — M8 (line-array-backed).

Run: `pixi run test-text-area`

The widget now drives the pure-Mojo line-array engine
(`mojoui/core/multiline_edit.mojo`), whose editing model is exhaustively
covered in `tests/core/test_multiline_edit.mojo`. These tests cover the WIDGET
WIRING:
  1. Unfocused: staged typed text does NOT enter the buffer.
  2. Focused (via simulated click): staged typed text inserts.
  3. RETURN creates a 2nd line (state.lines length 2).
  4. Click positions the cursor on the right row.
  5. Selection highlight + caret emit draw commands.
  6. Distinct id_strs hash distinctly.

JIT note: same as test_text_edit.mojo — the focused path calls
`ctx.input.consume_text()` (FFI under the default), so this test is
BUILD-THEN-RUN (links libmojoui_floor.so). Tests call
`InputState.disable_ffi_text()` + stage typed bytes via `pending_text`.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, hash_str
from mojoui.core.context import Context
from mojoui.core.commands import CMD_RECT
from mojoui.core.multiline_edit import MultiLineState
from mojoui.render.ffi import MOJOUI_KEY_RETURN
from mojoui.widgets.text_area import text_area


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _count_rect(ctx: Context) -> Int32:
    var n: Int32 = 0
    var total = Int32(ctx.commands.byte_count())
    var off: Int32 = 0
    while off < total:
        if ctx.commands.kind_at(off) == Int32(CMD_RECT):
            n = n + 1
        var step = ctx.commands.size_at(off)
        if step <= 0:
            break
        off = off + step
    return n


def _begin_1_col(
    mut ctx: Context, mouse_pos: Vec2, pressed: Bool, released: Bool
) raises:
    """Begin a frame; first widget rect = (0, 0, 200, 60). FFI text off."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    ctx.input.disable_ffi_text()
    ctx.theme.font_id = UInt32(1)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 60)


def test_unfocused_ignores_typed_text() raises:
    var ctx = Context()
    _begin_1_col(ctx, Vec2(500.0, 500.0), False, False)
    ctx.input.pending_text = String("XYZ")
    var buffer = String("initial")
    var st = MultiLineState()
    st.set_text(buffer)
    var changed = text_area(ctx, String("notes"), buffer, st)
    if changed:
        _fail("unfocused text_area should not change the buffer")
    if buffer != String("initial"):
        _fail("unfocused text_area must leave buffer untouched")
    ctx.end_frame()


def test_focused_typed_text_inserts() raises:
    var ctx = Context()
    var buffer = String("ab")
    var st = MultiLineState()
    st.set_text(buffer)

    # Frame 1: press inside the field → focus + caret.
    _begin_1_col(ctx, Vec2(2.0, 8.0), True, False)
    var _ = text_area(ctx, String("notes"), buffer, st)
    ctx.end_frame()

    # Frame 2: still focused; stage "Z" → inserted.
    _begin_1_col(ctx, Vec2(2.0, 8.0), False, False)
    ctx.input.pending_text = String("Z")
    var changed = text_area(ctx, String("notes"), buffer, st)
    if not changed:
        _fail("focused text_area with typed text should report changed")
    if buffer != String("Zab") and buffer != String("aZb") and buffer != String("abZ"):
        _fail(String("expected Z inserted into 'ab', got: ") + buffer)
    ctx.end_frame()


def test_return_creates_second_line() raises:
    var ctx = Context()
    var buffer = String("hello")
    var st = MultiLineState()
    st.set_text(buffer)

    # Frame 1: click to focus.
    _begin_1_col(ctx, Vec2(2.0, 8.0), True, False)
    var _ = text_area(ctx, String("notes"), buffer, st)
    ctx.end_frame()

    # Frame 2: press RETURN.
    _begin_1_col(ctx, Vec2(2.0, 8.0), False, False)
    ctx.input.keys[Int(MOJOUI_KEY_RETURN)].pressed = True
    var changed = text_area(ctx, String("notes"), buffer, st)
    if not changed:
        _fail("RETURN should change the buffer")
    if len(st.lines) != 2:
        _fail(String("RETURN should create 2 lines, got ") + String(len(st.lines)))
    ctx.end_frame()


def test_click_positions_cursor_row() raises:
    var ctx = Context()
    var buffer = String("line0\nline1\nline2")
    var st = MultiLineState()
    st.set_text(buffer)
    # Click near vertical middle of the 2nd row. line_height = 14+4 = 18.
    # pad = 6. row 1 spans y in [6+18, 6+36) → ~ y=30.
    _begin_1_col(ctx, Vec2(8.0, 30.0), True, False)
    var _ = text_area(ctx, String("notes"), buffer, st)
    if Int(st.cursor_row) != 1:
        _fail(String("click at y=30 should land on row 1, got ") + String(Int(st.cursor_row)))
    ctx.end_frame()


def test_selection_and_caret_emit_commands() raises:
    var ctx = Context()
    var buffer = String("hello")
    var st = MultiLineState()
    st.set_text(buffer)
    # Build a selection programmatically before the draw: anchor at 0,
    # cursor at 3.
    st.sel_col = 0
    st.cursor_col = 3

    _begin_1_col(ctx, Vec2(2.0, 8.0), True, False)
    var before = ctx.commands.byte_count()
    var _ = text_area(ctx, String("notes"), buffer, st)
    var after = ctx.commands.byte_count()
    if after <= before:
        _fail("text_area should emit draw commands")
    if ctx.layout.frames[0].max_y < Int32(60):
        _fail("text_area should advance layout.max_y past row height 60")
    ctx.end_frame()


def test_focused_selection_renders_highlight() raises:
    """Skeptic H1 coverage: the selection-highlight render branch must
    actually run. Focus on frame 1, then on frame 2 set a selection WITHOUT
    a collapsing press, and confirm the highlight adds CMD_RECT(s) over the
    no-selection baseline."""
    # Baseline: focused, NO selection.
    var ctx_a = Context()
    var buf_a = String("hello")
    var sa = MultiLineState()
    sa.set_text(buf_a)
    _begin_1_col(ctx_a, Vec2(2.0, 8.0), True, False)  # frame 1: click → focus
    var _a1 = text_area(ctx_a, String("notes"), buf_a, sa)
    ctx_a.end_frame()
    _begin_1_col(ctx_a, Vec2(2.0, 8.0), False, False)  # frame 2: no press
    var _a2 = text_area(ctx_a, String("notes"), buf_a, sa)
    var base_rects = _count_rect(ctx_a)
    ctx_a.end_frame()

    # With a selection live at draw time.
    var ctx_b = Context()
    var buf_b = String("hello")
    var sb = MultiLineState()
    sb.set_text(buf_b)
    _begin_1_col(ctx_b, Vec2(2.0, 8.0), True, False)  # frame 1: focus
    var _b1 = text_area(ctx_b, String("notes"), buf_b, sb)
    ctx_b.end_frame()
    _begin_1_col(ctx_b, Vec2(2.0, 8.0), False, False)  # frame 2: no press
    sb.sel_row = 0
    sb.sel_col = 0
    sb.cursor_row = 0
    sb.cursor_col = 3  # select "hel"
    var _b2 = text_area(ctx_b, String("notes"), buf_b, sb)
    var sel_rects = _count_rect(ctx_b)
    ctx_b.end_frame()

    if sel_rects <= base_rects:
        _fail(
            String("focused selection should emit extra highlight rect(s): ")
            + String(Int(sel_rects)) + String(" vs baseline ")
            + String(Int(base_rects))
        )


def test_distinct_ids() raises:
    var a = hash_str(String("notes"))
    var b = hash_str(String("prompt"))
    if UInt32(a) == UInt32(b):
        _fail("'notes' and 'prompt' must hash differently")


def main() raises:
    test_unfocused_ignores_typed_text()
    test_focused_typed_text_inserts()
    test_return_creates_second_line()
    test_click_positions_cursor_row()
    test_selection_and_caret_emit_commands()
    test_focused_selection_renders_highlight()
    test_distinct_ids()
    print("PASS: text_area widget smoke tests (7 tests)")
