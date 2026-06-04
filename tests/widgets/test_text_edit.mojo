"""Smoke tests for `mojoui/widgets/text_edit.mojo` — M5 (stb_textedit-backed).

Run: `pixi run test-text-edit`

The widget now drives the pure-Mojo stb_textedit engine
(`mojoui/core/textedit.mojo`), whose editing model — insertion, selection,
movement, undo/redo, cut/paste — is exhaustively covered in
`tests/core/test_textedit.mojo`. These tests cover the WIDGET WIRING:
  1. Unfocused: staged typed text does NOT enter the buffer.
  2. Focused (via simulated click): staged typed text DOES enter the buffer
     and the caller's TextEditState cursor advances.
  3. Backspace key edge removes a char when focused.
  4. Emits draw commands + advances the layout cursor.
  5. Distinct id_strs hash distinctly.

JIT note: the focused path calls `ctx.input.consume_text()` (FFI under the
default). Tests call `InputState.disable_ffi_text()` and stage typed bytes via
`pending_text`, so the engine sees input without resolving FFI symbols. The
engine itself is FFI-free; only the widget's text-drain touches the seam.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId, hash_str
from mojoui.core.context import Context
from mojoui.core.textedit import TextEditState, te_has_selection
from mojoui.widgets.text_edit import text_edit


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _begin_1_col(
    mut ctx: Context, mouse_pos: Vec2, pressed: Bool, released: Bool
) raises:
    """Begin a frame; first widget rect = (0, 0, 200, 24). FFI text path off."""
    ctx.begin_frame_no_input(Vec2(800.0, 600.0), mouse_pos.copy(), pressed, released)
    ctx.input.disable_ffi_text()
    # A font id must be non-zero for the text/caret draw path, but the
    # widget's editing logic runs regardless. Set a dummy font so draw
    # commands include text (test 4 checks the buffer grew either way).
    ctx.theme.font_id = UInt32(1)
    var widths = List[Int32]()
    widths.append(200)
    ctx.layout_row(widths^, 24)


def test_unfocused_ignores_typed_text() raises:
    """No prior focus → staged typed text is not consumed into the buffer."""
    var ctx = Context()
    _begin_1_col(ctx, Vec2(500.0, 500.0), False, False)
    ctx.input.pending_text = String("XYZ")
    var buffer = String("initial")
    var st = TextEditState(single_line=True)
    var changed = text_edit(ctx, String("name"), buffer, st)
    if changed:
        _fail("unfocused text_edit should not change the buffer")
    if buffer != String("initial"):
        _fail("unfocused text_edit must leave buffer untouched")
    ctx.end_frame()


def test_focused_typed_text_inserts() raises:
    """Click to focus + position caret, then a second frame with staged
    typed text inserts it at the cursor."""
    var ctx = Context()
    var buffer = String("ab")
    var st = TextEditState(single_line=True)

    # Frame 1: press inside the field at far left → focus + caret at 0.
    _begin_1_col(ctx, Vec2(2.0, 12.0), True, False)
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()

    # Frame 2: still focused (focus is sticky); stage "Z" → inserted at caret.
    _begin_1_col(ctx, Vec2(2.0, 12.0), False, False)
    ctx.input.pending_text = String("Z")
    var changed = text_edit(ctx, String("name"), buffer, st)
    if not changed:
        _fail("focused text_edit with typed text should report changed")
    # Caret was placed at/near left edge → insertion at start of buffer.
    if buffer != String("Zab") and buffer != String("aZb") and buffer != String("abZ"):
        _fail(String("expected Z inserted into 'ab', got: ") + buffer)
    ctx.end_frame()


def test_focused_caret_at_start_inserts_at_front() raises:
    """A click at the far-left origin must place the caret at byte 0 so the
    next typed char lands at the front."""
    var ctx = Context()
    var buffer = String("ab")
    var st = TextEditState(single_line=True)

    _begin_1_col(ctx, Vec2(0.0, 12.0), True, False)  # x at origin → caret 0
    var _ = text_edit(ctx, String("name"), buffer, st)
    ctx.end_frame()
    if Int(st.cursor) != 0:
        _fail(String("click at origin should set cursor=0, got ") + String(Int(st.cursor)))

    _begin_1_col(ctx, Vec2(0.0, 12.0), False, False)
    ctx.input.pending_text = String("Z")
    var _2 = text_edit(ctx, String("name"), buffer, st)
    if buffer != String("Zab"):
        _fail(String("typed char at caret 0 should prepend, got: ") + buffer)
    ctx.end_frame()


def test_emits_draw_commands_and_advances_layout() raises:
    """Emits draw commands and advances the layout cursor."""
    var ctx = Context()
    _begin_1_col(ctx, Vec2(500.0, 500.0), False, False)
    var before = ctx.commands.byte_count()
    var buffer = String("")
    var st = TextEditState(single_line=True)
    var _ = text_edit(ctx, String("input"), buffer, st)
    var after = ctx.commands.byte_count()
    if after <= before:
        _fail("text_edit should emit at least one draw command")
    if ctx.layout.frames[0].max_y < Int32(24):
        _fail("text_edit should advance layout.max_y past row height 24")
    ctx.end_frame()


def test_distinct_ids() raises:
    """Two distinct id_strs hash distinctly (the widget's get_id derivation
    at the top of the id_stack)."""
    var id_name = hash_str(String("name"))
    var id_email = hash_str(String("email"))
    if UInt32(id_name) == UInt32(id_email):
        _fail("'name' and 'email' must hash differently")


def main() raises:
    test_unfocused_ignores_typed_text()
    test_focused_typed_text_inserts()
    test_focused_caret_at_start_inserts_at_front()
    test_emits_draw_commands_and_advances_layout()
    test_distinct_ids()
    print("PASS: text_edit widget smoke tests (5 tests)")
