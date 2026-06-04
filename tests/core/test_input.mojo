"""Smoke tests for `mojoui.core.input` — edge-detection logic + InputState API.

We cannot open a real window in this environment (the GPU is occupied by
serenitymojo training and `sapp_run` would block forever anyway), so these
tests are PURELY static + algorithmic:

  1. `_compute_edge` truth table — all four (prev_held, cur_held) transitions.
  2. `ButtonState()` default-zero constructor.
  3. `InputState()` constructs with all zero-shaped fields.
  4. Array sizing matches MOJOUI_KEY_COUNT (96) + 3 mouse buttons.
  5. Compile-only signature probes for `poll()`, `consume_text()`, and the
     `poll_input()` free wrapper — gated behind a never-True runtime guard
     so the JIT doesn't try to resolve the libmojoui_floor.so symbols
     (the existing test-ffi / test-backend tests follow the same pattern:
     `mojo run` does NOT dlopen the .so unless a symbol is actually
     materialised, so calling FFI from a JIT test causes
     "Symbols not found: [...]"; the static signature proof is what we want
     here anyway since we cannot open a real window without the GPU).

Run: cd /home/alex/MojoUI && pixi run test-input
"""

from mojoui.core.input import (
    InputState,
    ButtonState,
    MOUSE_BUTTON_COUNT,
    _compute_edge,
    poll_input,
)
from mojoui.core.types import Vec2
from mojoui.render.ffi import (
    MOJOUI_BTN_LEFT,
    MOJOUI_BTN_MIDDLE,
    MOJOUI_BTN_RIGHT,
    MOJOUI_KEY_A,
    MOJOUI_KEY_COUNT,
    MOJOUI_KEY_RETURN,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error("input smoke")


def _expect_eq_bool(name: String, got: Bool, want: Bool) raises:
    if got != want:
        print("FAIL:", name, " got:", got, " want:", want)
        raise Error("input smoke: " + name)


# ============================================================
# 1) _compute_edge — truth table (all 4 transitions)
# ============================================================


def test_edge_idle() raises:
    """(prev=False, cur=False) -> (pressed=F, held=F, released=F).

    The "no input on this key at all" baseline. Every key/button reports this
    every frame until something happens.
    """
    var st = _compute_edge(False, False)
    _expect_eq_bool("edge_idle.pressed", st.pressed, False)
    _expect_eq_bool("edge_idle.held", st.held, False)
    _expect_eq_bool("edge_idle.released", st.released, False)


def test_edge_rising() raises:
    """(prev=False, cur=True) -> (pressed=T, held=T, released=F).

    The "key just went down THIS frame" case — what `button` widgets fire on.
    """
    var st = _compute_edge(False, True)
    _expect_eq_bool("edge_rising.pressed", st.pressed, True)
    _expect_eq_bool("edge_rising.held", st.held, True)
    _expect_eq_bool("edge_rising.released", st.released, False)


def test_edge_still_held() raises:
    """(prev=True, cur=True) -> (pressed=F, held=T, released=F).

    The "key continues to be down" case — what drag/repeat widgets watch.
    `pressed` is NOT True here: it fires once at rising-edge, not every frame.
    """
    var st = _compute_edge(True, True)
    _expect_eq_bool("edge_still_held.pressed", st.pressed, False)
    _expect_eq_bool("edge_still_held.held", st.held, True)
    _expect_eq_bool("edge_still_held.released", st.released, False)


def test_edge_falling() raises:
    """(prev=True, cur=False) -> (pressed=F, held=F, released=T).

    The "key just went up THIS frame" case — what drop / commit widgets fire on.
    """
    var st = _compute_edge(True, False)
    _expect_eq_bool("edge_falling.pressed", st.pressed, False)
    _expect_eq_bool("edge_falling.held", st.held, False)
    _expect_eq_bool("edge_falling.released", st.released, True)


# ============================================================
# 2) ButtonState default constructor
# ============================================================


def test_button_state_default() raises:
    """`ButtonState()` zero-initialises all three flags to False."""
    var st = ButtonState()
    _expect_eq_bool("ButtonState().pressed", st.pressed, False)
    _expect_eq_bool("ButtonState().held", st.held, False)
    _expect_eq_bool("ButtonState().released", st.released, False)


def test_button_state_explicit() raises:
    """`ButtonState(p, h, r)` stores flags exactly as passed."""
    var st = ButtonState(True, True, False)
    _expect_eq_bool("ButtonState(T,T,F).pressed", st.pressed, True)
    _expect_eq_bool("ButtonState(T,T,F).held", st.held, True)
    _expect_eq_bool("ButtonState(T,T,F).released", st.released, False)


# ============================================================
# 3) InputState constructor + initial state
# ============================================================


def test_input_state_default_construct() raises:
    """`InputState()` constructs without error.

    Just verifies the call goes through — fields are checked individually
    in the next tests.
    """
    var inp = InputState()
    # No assertion needed; if the constructor raised, we'd never reach here.
    _ = inp.mouse_pos.x  # touch a field to ensure it's accessible


def test_input_state_initial_zero() raises:
    """All edge flags + mouse_pos / mouse_delta start at False / 0.

    Verifies the `fill=` paths in `__init__` work as advertised: 96 keys
    AND 3 mouse buttons are all-False, and the mouse vectors are (0, 0).
    """
    var inp = InputState()

    if inp.mouse_pos.x != 0.0 or inp.mouse_pos.y != 0.0:
        _fail("InputState().mouse_pos should be zero")
    if inp.mouse_delta.x != 0.0 or inp.mouse_delta.y != 0.0:
        _fail("InputState().mouse_delta should be zero")
    if inp.prev_mouse_pos.x != 0.0 or inp.prev_mouse_pos.y != 0.0:
        _fail("InputState().prev_mouse_pos should be zero")

    # Sample a couple of mouse-button slots.
    var ml = inp.mouse[Int(MOJOUI_BTN_LEFT)].copy()
    if ml.pressed or ml.held or ml.released:
        _fail("InputState().mouse[LEFT] should be all-False")
    var mr = inp.mouse[Int(MOJOUI_BTN_RIGHT)].copy()
    if mr.pressed or mr.held or mr.released:
        _fail("InputState().mouse[RIGHT] should be all-False")

    # Sample a representative key slot.
    var ka = inp.keys[Int(MOJOUI_KEY_A)].copy()
    if ka.pressed or ka.held or ka.released:
        _fail("InputState().keys[A] should be all-False")
    var kr = inp.keys[Int(MOJOUI_KEY_RETURN)].copy()
    if kr.pressed or kr.held or kr.released:
        _fail("InputState().keys[RETURN] should be all-False")


# ============================================================
# 4) Array sizing matches MOJOUI_KEY_COUNT + 3 mouse buttons
# ============================================================


def test_array_sizes_via_endpoint_access() raises:
    """Indirectly verify InputState.keys has at least MOJOUI_KEY_COUNT (96)
    slots and InputState.mouse has at least 3 slots by reading the
    last-index slot of each. If the InlineArrays were undersized this would
    out-of-bounds at compile or runtime.

    Mojo's `InlineArray` indexing is bounds-checked at runtime in debug
    builds; in release builds an OOB read is UB. Either way, in tests this
    catches a mismatch.
    """
    var inp = InputState()
    var last_key_idx = Int(MOJOUI_KEY_COUNT) - 1  # 95
    var last_btn_idx = Int(MOUSE_BUTTON_COUNT) - 1  # 2

    # Read the last legal slot of each array; if undersized this would crash.
    var last_key = inp.keys[last_key_idx].copy()
    var last_btn = inp.mouse[last_btn_idx].copy()

    # Sanity: both initial slots are idle.
    if last_key.pressed or last_key.held or last_key.released:
        _fail("InputState().keys[KEY_COUNT-1] should be idle")
    if last_btn.pressed or last_btn.held or last_btn.released:
        _fail("InputState().mouse[BTN_COUNT-1] should be idle")


def test_mouse_button_count_constant() raises:
    """MOUSE_BUTTON_COUNT must equal 3 — matches the MOJOUI_BTN_* trio in ffi.

    Comparisons launder through `Int(...)` to defeat compile-time folding
    of `comptime Int32` constants (otherwise the compiler proves every
    branch dead and emits "always evaluates to False" warnings that would
    hide real warnings from future chunks — see FRAGILE #4 in
    SKEPTIC_FINDINGS_M1_2026-05-28.md).
    """
    var btn_count = Int(MOUSE_BUTTON_COUNT)
    var btn_left = Int(MOJOUI_BTN_LEFT)
    var btn_right = Int(MOJOUI_BTN_RIGHT)
    var btn_middle = Int(MOJOUI_BTN_MIDDLE)
    if btn_count != 3:
        _fail("MOUSE_BUTTON_COUNT should be 3")
    if btn_left >= btn_count:
        _fail("MOJOUI_BTN_LEFT out of MOUSE_BUTTON_COUNT range")
    if btn_right >= btn_count:
        _fail("MOJOUI_BTN_RIGHT out of MOUSE_BUTTON_COUNT range")
    if btn_middle >= btn_count:
        _fail("MOJOUI_BTN_MIDDLE out of MOUSE_BUTTON_COUNT range")


# ============================================================
# 5) FFI-touching API surface — compile-only signature proofs
#    (gated by a runtime-False so the JIT does not try to resolve
#     mojoui_get_mouse_x / get_key / get_input_text / etc.; the FFI
#     test-ffi follows the same pattern for `run_blocking`)
# ============================================================


def test_consume_text_signature() raises:
    """`InputState.consume_text() raises -> String` — compile-only proof.

    The actual call would invoke `mojoui_input_text_length` +
    `mojoui_get_input_text` + `mojoui_clear_input_text` on the C floor;
    the JIT does not dlopen libmojoui_floor.so unless a symbol is
    materialised at runtime, so we gate behind a runtime-False guard
    (same pattern as `test_callback_type` in tests/render/test_ffi.mojo).
    """
    var never = Int(MOJOUI_KEY_COUNT) - 96  # always 0, not literal-False
    if never != 0:
        var inp = InputState()
        var _s = inp.consume_text()


def test_poll_signature() raises:
    """`InputState.poll()` — compile-only proof; gated as above."""
    var never = Int(MOJOUI_KEY_COUNT) - 96
    if never != 0:
        var inp = InputState()
        inp.poll()


def test_poll_input_free_function_signature() raises:
    """`poll_input(state)` — compile-only proof; gated as above."""
    var never = Int(MOJOUI_KEY_COUNT) - 96
    if never != 0:
        var inp = InputState()
        poll_input(inp)


# ============================================================
# 7) Convenience accessors — readable form returns the same value
# ============================================================


def test_convenience_accessors() raises:
    """`input.mouse_pressed(BTN)` == `input.mouse[Int(BTN)].pressed`, etc."""
    var inp = InputState()
    # Manually set one slot to a known pattern; the accessor must echo it.
    inp.mouse[Int(MOJOUI_BTN_LEFT)] = ButtonState(True, True, False)
    inp.keys[Int(MOJOUI_KEY_RETURN)] = ButtonState(False, True, False)

    _expect_eq_bool(
        "mouse_pressed(LEFT)", inp.mouse_pressed(MOJOUI_BTN_LEFT), True
    )
    _expect_eq_bool(
        "mouse_held(LEFT)", inp.mouse_held(MOJOUI_BTN_LEFT), True
    )
    _expect_eq_bool(
        "mouse_released(LEFT)", inp.mouse_released(MOJOUI_BTN_LEFT), False
    )
    _expect_eq_bool(
        "key_pressed(RETURN)", inp.key_pressed(MOJOUI_KEY_RETURN), False
    )
    _expect_eq_bool(
        "key_held(RETURN)", inp.key_held(MOJOUI_KEY_RETURN), True
    )
    _expect_eq_bool(
        "key_released(RETURN)", inp.key_released(MOJOUI_KEY_RETURN), False
    )


# ============================================================
# Test runner
# ============================================================


def main() raises:
    test_edge_idle()
    test_edge_rising()
    test_edge_still_held()
    test_edge_falling()
    test_button_state_default()
    test_button_state_explicit()
    test_input_state_default_construct()
    test_input_state_initial_zero()
    test_array_sizes_via_endpoint_access()
    test_mouse_button_count_constant()
    test_consume_text_signature()
    test_poll_signature()
    test_poll_input_free_function_signature()
    test_convenience_accessors()
    print("PASS: all 14 input smoke tests")
