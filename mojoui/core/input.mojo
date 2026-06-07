"""Per-frame input state with edge detection — Mojo `InputState` over the raw FFI.

`mojoui.render.ffi` exposes the raw, level-only physical state of the keyboard
+ mouse maintained by the C floor (`mojoui_get_mouse_x/y/button`,
`mojoui_get_key`, `mojoui_get_input_text`/`length`/`clear`). The C side does NOT
remember the previous frame — it only knows "is this key/button down right now?".

This module turns that level-only stream into the **edge-triggered** model the
microui-style 6-step widget recipe needs:

  * `pressed`  — True ONLY on the single frame the key/button transitioned
                 from up to down (rising edge).
  * `held`     — True every frame the key/button is currently down
                 (level-triggered, identical to the raw FFI bit).
  * `released` — True ONLY on the single frame the key/button transitioned
                 from down to up (falling edge).

Edge detection is a per-button/per-key XOR between this frame's level and the
previous frame's level, computed by `InputState.poll()` from the FFI. The same
pattern is used by microui's `mu_input_*` setters (per
`internal audit notes` §Input Handling) — except microui
takes pushed events from the host, while MojoUI pulls the current level from
the C floor each frame. Same edge math, different transport.

Lifecycle (consumed by `mojoui/core/context.mojo` in chunk 16):

    var input = InputState()
    while not Backend.should_close():
        Backend.frame_begin(clear)
        input.poll()                              # snapshot + edge compute
        if input.mouse[MOJOUI_BTN_LEFT].pressed:  # mouse just went down
            ...
        if input.key_pressed(MOJOUI_KEY_RETURN):  # enter rising edge
            ...
        var typed = input.consume_text()          # drain C-side text buffer
        # ... widget update_control + draw ...
        Backend.frame_end()

Text input is kept separate: `consume_text()` drains the C-side text-input
buffer (a `static char[]` filled by sokol_app's SAPP_EVENTTYPE_CHAR handler)
and clears it so the next frame starts empty — same shape as microui's
`input_text[32]` field which is also edge-cleared at end-of-frame.

This module does NOT do: hover/focus/active state (that's `core/control.mojo`,
chunk 14), ID hashing (`core/id.mojo`, chunk 11), or routing events to widgets
(`core/context.mojo`, chunk 16). It is the pure "state snapshot + edge math"
layer.
"""

from std.builtin.type_aliases import MutAnyOrigin
from std.memory import UnsafePointer

from mojoui.core.types import Vec2
from mojoui.render.ffi import (
    MOJOUI_BTN_LEFT,
    MOJOUI_BTN_MIDDLE,
    MOJOUI_BTN_RIGHT,
    MOJOUI_KEY_COUNT,
    clear_input_text as _ffi_clear_input_text,
    clear_scroll as _ffi_clear_scroll,
    get_input_text as _ffi_get_input_text,
    get_key as _ffi_get_key,
    get_mouse_button as _ffi_get_mouse_button,
    get_mouse_x as _ffi_get_mouse_x,
    get_mouse_y as _ffi_get_mouse_y,
    get_scroll_x as _ffi_get_scroll_x,
    get_scroll_y as _ffi_get_scroll_y,
    input_text_length as _ffi_input_text_length,
)


# ============================================================
# Constants
# ============================================================


# `comptime` (not `alias`) for compile-time constants per current beta — see
# Mojo implementation notes "`comptime` not `alias`".
#
# MOUSE_BUTTON_COUNT mirrors the three MOJOUI_BTN_* indices defined in
# mojoui/render/ffi.mojo (LEFT=0, RIGHT=1, MIDDLE=2). If the C floor ever
# grows a fourth (X1/X2), bump this AND extend the InlineArrays below.
comptime MOUSE_BUTTON_COUNT: Int32 = 3

# Concrete Int sizes for the InlineArray declarations. InlineArray's count
# parameter is a runtime-Int-shaped compile-time value, and current beta
# does not accept an Int32-typed `comptime` directly there — so we mirror the
# `MOJOUI_KEY_COUNT` value (= 96) and MOUSE_BUTTON_COUNT (= 3) as plain Int
# `comptime`s here. Any drift between these and the ffi-side constants would
# be caught by `test_keys_array_size` in tests/core/test_input.mojo.
comptime _KEY_SLOTS: Int = 96
comptime _MOUSE_SLOTS: Int = 3


# ============================================================
# Internal edge-detection primitive
# ============================================================


def _compute_edge(prev_held: Bool, cur_held: Bool) -> ButtonState:
    """Compute the three-edge state for one button/key given its level
    this frame vs the previous frame.

    Truth table (prev_held, cur_held) -> (pressed, held, released):
        (False, False) -> (False, False, False)   # idle
        (False, True ) -> (True,  True,  False)   # rising edge
        (True,  True ) -> (False, True,  False)   # still held
        (True,  False) -> (False, False, True )   # falling edge

    Pure: no FFI, no side effects, easy to unit-test in isolation.
    """
    return ButtonState(
        pressed=cur_held and not prev_held,
        held=cur_held,
        released=(not cur_held) and prev_held,
    )


# ============================================================
# ButtonState — three-edge per-button/key snapshot
# ============================================================


struct ButtonState(Copyable, Movable):
    """Three-edge per-button state, computed per-frame by `_compute_edge`.

    `pressed` and `released` are single-frame edges; `held` is the current
    level. A widget should typically check `pressed` to consume a click,
    `held` to track drag, and `released` to commit a drop.
    """

    var pressed: Bool
    var held: Bool
    var released: Bool

    @always_inline
    def __init__(out self):
        self.pressed = False
        self.held = False
        self.released = False

    @always_inline
    def __init__(out self, pressed: Bool, held: Bool, released: Bool):
        self.pressed = pressed
        self.held = held
        self.released = released

    @always_inline
    def __eq__(self, other: ButtonState) -> Bool:
        return (
            self.pressed == other.pressed
            and self.held == other.held
            and self.released == other.released
        )

    @always_inline
    def __ne__(self, other: ButtonState) -> Bool:
        return not self.__eq__(other)


# ============================================================
# InputState — per-frame input snapshot consumed by Context
# ============================================================


struct InputState(Copyable, Movable):
    """Per-frame mouse + keyboard + text-input snapshot with edge detection.

    Storage:
        mouse_pos        — current mouse position (Float32 pixels, top-left origin)
        mouse_delta      — (mouse_pos - prev_mouse_pos) computed in `poll()`
        prev_mouse_pos   — internal: the previous frame's mouse_pos
        mouse[3]         — three-edge state per mouse button, indexed by MOJOUI_BTN_*
        prev_mouse_held  — internal: the previous frame's raw level per button
        keys[96]         — three-edge state per key, indexed by MOJOUI_KEY_* (UNKNOWN..COUNT-1)
        prev_keys_held   — internal: the previous frame's raw level per key

    The previous-state buffers are kept inside the struct so each `InputState`
    is a self-contained per-frame snapshot — no hidden globals, no other
    "where is the prev frame" book-keeping anywhere else. This matches
    microui's all-in-`mu_Context` discipline (per microui reference notes).

    Construction (`__init__`) zeros everything, so the first `poll()` call
    sees an entirely-up previous frame: any keys/buttons that were already
    physically down on startup will register as `pressed` once. That's the
    same behaviour microui has after `mu_init` and is what widget code
    expects (no spurious "missed press" on first frame).

    The text-input channel is NOT part of `poll()`: text is left in the
    C-side static buffer until `consume_text()` is called. This mirrors
    microui's pattern where `input_text` is a separate field that the widget
    code (e.g. `mu_textbox_raw`) drains explicitly.
    """

    var mouse_pos: Vec2
    var mouse_delta: Vec2
    var scroll_delta: Vec2
    var prev_mouse_pos: Vec2
    var mouse: InlineArray[ButtonState, _MOUSE_SLOTS]
    var prev_mouse_held: InlineArray[Bool, _MOUSE_SLOTS]
    var keys: InlineArray[ButtonState, _KEY_SLOTS]
    var prev_keys_held: InlineArray[Bool, _KEY_SLOTS]
    var pending_text: String
    """Pre-staged UTF-8 text drained by `consume_text()` BEFORE the FFI path.

    Two uses:
      1. Tests inject typed text directly (`inp.pending_text = String("ab")`)
         and call `disable_ffi_text()` so `consume_text()` returns the
         injected bytes without resolving `mojoui_get_input_text` (which the
         JIT would otherwise trip on — see Mojo implementation notes c15/c16 JIT note).
      2. Production code can stage text from a non-FFI source (e.g. an
         in-process simulated input feed for headless integration tests).
    Always cleared after a successful drain."""
    var _use_ffi_text: Bool
    """When True (default), `consume_text()` falls back to the C-floor FFI
    after draining `pending_text`. When False (tests), `consume_text()` returns
    `pending_text` then sets it to "" and SKIPS the FFI entirely — this is
    what keeps the JIT from materialising `mojoui_get_input_text` / the other
    text-input symbols in unit tests. Toggled via `disable_ffi_text()` /
    `enable_ffi_text()`."""

    def __init__(out self):
        """All-zero initial state.

        Per the struct doc, this means any key/button physically down on
        startup will register as a single `pressed` edge on the first
        `poll()` call — matches microui's post-init behaviour.
        """
        self.mouse_pos = Vec2.zero()
        self.mouse_delta = Vec2.zero()
        self.scroll_delta = Vec2.zero()
        self.prev_mouse_pos = Vec2.zero()
        self.mouse = InlineArray[ButtonState, _MOUSE_SLOTS](
            fill=ButtonState(False, False, False)
        )
        self.prev_mouse_held = InlineArray[Bool, _MOUSE_SLOTS](fill=False)
        self.keys = InlineArray[ButtonState, _KEY_SLOTS](
            fill=ButtonState(False, False, False)
        )
        self.prev_keys_held = InlineArray[Bool, _KEY_SLOTS](fill=False)
        self.pending_text = String("")
        self._use_ffi_text = True

    # ----- Test seam: bypass FFI text path entirely (c24) ---------------

    @always_inline
    def disable_ffi_text(mut self):
        """Test seam: turn off the FFI fall-through in `consume_text()`.

        After this call, `consume_text()` returns whatever is in
        `pending_text` (and clears it) without ever calling
        `mojoui_input_text_length` / `mojoui_get_input_text` /
        `mojoui_clear_input_text`. Used by widget unit tests (text_edit etc.)
        to keep the JIT from eagerly materialising the FFI symbols.
        Production code never calls this.
        """
        self._use_ffi_text = False

    @always_inline
    def enable_ffi_text(mut self):
        """Re-enable the FFI fall-through in `consume_text()`. Default state.
        Provided as the symmetric pair to `disable_ffi_text()` so tests can
        toggle if needed."""
        self._use_ffi_text = True

    # ----- Per-frame snapshot ------------------------------------------

    def poll(mut self):
        """Read current state from the C floor; compute edges vs previous frame.

        Order:
          1. Sample mouse position (`get_mouse_x/y`), compute `mouse_delta`
             relative to the previous frame, advance `prev_mouse_pos`.
          2. Sample wheel/trackpad scroll delta and drain it from the C floor.
          3. For each mouse button (LEFT/RIGHT/MIDDLE): sample current level
             via `get_mouse_button`, derive ButtonState via `_compute_edge`,
             store in `self.mouse[i]`, update `prev_mouse_held[i]`.
          4. For each key (0..MOJOUI_KEY_COUNT-1): same pattern via `get_key`.

        Text input is NOT polled here — it remains in the C-side static
        buffer until `consume_text()` is called explicitly.
        """
        # ----- Mouse position + delta -----
        var new_pos = Vec2(
            Float32(Int(_ffi_get_mouse_x())),
            Float32(Int(_ffi_get_mouse_y())),
        )
        self.mouse_delta = new_pos - self.prev_mouse_pos
        self.prev_mouse_pos = self.mouse_pos.copy()
        self.mouse_pos = new_pos.copy()

        self.scroll_delta = Vec2(_ffi_get_scroll_x(), _ffi_get_scroll_y())
        _ffi_clear_scroll()

        # ----- Mouse buttons -----
        for i in range(_MOUSE_SLOTS):
            var cur_held = _ffi_get_mouse_button(Int32(i)) != 0
            var prev = self.prev_mouse_held[i]
            self.mouse[i] = _compute_edge(prev, cur_held)
            self.prev_mouse_held[i] = cur_held

        # ----- Keys -----
        for i in range(_KEY_SLOTS):
            var cur_held = _ffi_get_key(Int32(i)) != 0
            var prev = self.prev_keys_held[i]
            self.keys[i] = _compute_edge(prev, cur_held)
            self.prev_keys_held[i] = cur_held

    # ----- Text input drainage -----------------------------------------

    def consume_text(mut self) raises -> String:
        """Drain newly-typed UTF-8 text; return as `String`.

        Drain order:
          1. If `pending_text` is non-empty, return its contents and clear it
             (the test-injection path AND the staged-input-feed path).
          2. Otherwise — and only when `_use_ffi_text` is True (the default)
             — drain the C-floor's input-text buffer via the FFI: same
             byte-copy-through-`List[UInt8]` pattern as `Backend.input_text()`
             in `mojoui/render/backend.mojo` (per Mojo implementation notes
             "`String(unsafe_from_utf8=List[UInt8])`").
          3. When `_use_ffi_text` is False (tests that called
             `disable_ffi_text()`), return "" without touching FFI — this
             keeps the JIT from materialising `mojoui_get_input_text` /
             `mojoui_input_text_length` / `mojoui_clear_input_text` in unit
             tests that aren't linked against libmojoui_floor.so.

        Returns "" when nothing was typed; always clears whichever channel
        it drained so the next frame starts fresh.
        """
        if self.pending_text.byte_length() > 0:
            var staged = self.pending_text.copy()
            self.pending_text = String("")
            return staged
        if not self._use_ffi_text:
            return String("")
        var n = _ffi_input_text_length()
        if n <= 0:
            # Defensive clear — harmless if the buffer is already empty.
            _ffi_clear_input_text()
            return String("")
        var ptr_i8 = _ffi_get_input_text()
        var ptr_u8 = ptr_i8.bitcast[UInt8]()
        var n_int = Int(n)
        var bytes = List[UInt8](capacity=n_int)
        for i in range(n_int):
            bytes.append(ptr_u8[i])
        var s = String(unsafe_from_utf8=bytes)
        _ffi_clear_input_text()
        return s

    # ----- Convenience edge accessors ----------------------------------
    #
    # These exist so widget code reads as `input.mouse_pressed(BTN_LEFT)`
    # rather than `input.mouse[Int(BTN_LEFT)].pressed`. Equivalent.

    @always_inline
    def mouse_pressed(self, button: Int32) -> Bool:
        """True if `button` (MOJOUI_BTN_*) transitioned down THIS FRAME."""
        return self.mouse[Int(button)].pressed

    @always_inline
    def mouse_held(self, button: Int32) -> Bool:
        """True every frame `button` (MOJOUI_BTN_*) is currently down."""
        return self.mouse[Int(button)].held

    @always_inline
    def mouse_released(self, button: Int32) -> Bool:
        """True if `button` (MOJOUI_BTN_*) transitioned up THIS FRAME."""
        return self.mouse[Int(button)].released

    @always_inline
    def key_pressed(self, mojoui_key: Int32) -> Bool:
        """True if `mojoui_key` (MOJOUI_KEY_*) transitioned down THIS FRAME."""
        return self.keys[Int(mojoui_key)].pressed

    @always_inline
    def key_held(self, mojoui_key: Int32) -> Bool:
        """True every frame `mojoui_key` (MOJOUI_KEY_*) is currently down."""
        return self.keys[Int(mojoui_key)].held

    @always_inline
    def key_released(self, mojoui_key: Int32) -> Bool:
        """True if `mojoui_key` (MOJOUI_KEY_*) transitioned up THIS FRAME."""
        return self.keys[Int(mojoui_key)].released


# ============================================================
# Free-function alias (`poll_input(state)`) — convenience wrapper
# ============================================================


def poll_input(mut state: InputState):
    """Free-function form of `InputState.poll()` for callers that prefer
    `poll_input(state)` over `state.poll()`. Identical behaviour.

    The chunk-16 `Context` will call `state.poll()` directly; this wrapper
    exists so that ad-hoc test/demo code can spell the call the way the
    chunk-15 contract describes (`poll_input()` as a top-level entry point).
    """
    state.poll()
