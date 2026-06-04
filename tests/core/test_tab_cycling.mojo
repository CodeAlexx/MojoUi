"""Smoke tests for `mojoui/core/control.mojo` Tab focus cycling (c52).

Run: `pixi run test-tab-cycling`

Covers the OPT_FOCUSABLE registration path and the Tab / Shift-Tab focus
advancement logic added in chunk 52 to close the M3 gate's keyboard-nav
criterion (deferred since M1).

Test plan (7 tests):

  1. fresh `ControlState()` has `focusable_this_frame` empty.
  2. `update_control(OPT_FOCUSABLE)` appends id to `focusable_this_frame`.
  3. `update_control(OPT_NONE)` does NOT append id.
  4. Tab cycles forward through registered widgets and wraps to first.
  5. Shift-Tab cycles backward through registered widgets and wraps to last.
  6. Tab from focus-on-last wraps to first.
  7. `begin_frame` clears `focusable_this_frame` between frames.
"""

from mojoui.core.types import Vec2, Rect
from mojoui.core.id import ImmediateId, IMM_ID_NONE
from mojoui.core.control import (
    ControlState,
    update_control,
    OPT_NONE,
    OPT_FOCUSABLE,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_default_focusable_is_empty() raises:
    """Test 1: a fresh ControlState has an empty focusable_this_frame list."""
    var s = ControlState()
    if len(s.focusable_this_frame) != 0:
        _fail("default focusable_this_frame should be empty")


def test_opt_focusable_registers_id() raises:
    """Test 2: update_control with OPT_FOCUSABLE appends the widget id to
    the focusable_this_frame registry."""
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    # Mouse outside the rect so the call is a pure registration (no
    # hover/active/focus state change).
    s.begin_frame(Vec2(500.0, 500.0), False, False, False, False)
    var idA = ImmediateId(111)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    if len(s.focusable_this_frame) != 1:
        _fail("focusable list should contain exactly 1 entry")
    if UInt32(s.focusable_this_frame[0]) != UInt32(idA):
        _fail("focusable_this_frame[0] should equal idA")


def test_no_opt_focusable_does_not_register() raises:
    """Test 3: update_control without OPT_FOCUSABLE does NOT add to the
    focusable list."""
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    s.begin_frame(Vec2(500.0, 500.0), False, False, False, False)
    var idA = ImmediateId(111)
    _ = update_control(s, idA, r.copy(), OPT_NONE)
    if len(s.focusable_this_frame) != 0:
        _fail("OPT_NONE should NOT add id to focusable list")


def test_tab_cycles_forward_and_wraps() raises:
    """Test 4: Tab advances focus through 3 widgets A→B→C→A.

    Sequence (mouse outside every rect so update_control only registers):
      Frame 1: register A, B, C with no focus; end_frame Tab → focus=A.
      Frame 2: re-register A, B, C with focus=A; end_frame Tab → focus=B.
      Frame 3: re-register A, B, C with focus=B; end_frame Tab → focus=C.
      Frame 4: re-register A, B, C with focus=C; end_frame Tab → focus=A.
    """
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    var idA = ImmediateId(111)
    var idB = ImmediateId(222)
    var idC = ImmediateId(333)

    # Frame 1: no focus → Tab → focus=A (wraps to first).
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idA):
        _fail("frame 1 Tab from no-focus should land on A (first)")

    # Frame 2: focus=A → Tab → focus=B.
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idB):
        _fail("frame 2 Tab from A should land on B")

    # Frame 3: focus=B → Tab → focus=C.
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idC):
        _fail("frame 3 Tab from B should land on C")

    # Frame 4: focus=C (last) → Tab → focus=A (wraps).
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idA):
        _fail("frame 4 Tab from C (last) should wrap to A")


def test_shift_tab_cycles_backward_and_wraps() raises:
    """Test 5: Shift-Tab reverses. focus=B → Shift-Tab → A; Shift-Tab
    again → C (wraps backward past A)."""
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    var idA = ImmediateId(111)
    var idB = ImmediateId(222)
    var idC = ImmediateId(333)
    # Seed focus=B directly (bypass the begin_frame/Tab sequence — we want
    # to isolate the Shift-Tab logic specifically).
    s.focus = idB

    # Frame 1: focus=B → Shift-Tab → focus=A.
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, True)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idA):
        _fail("Shift-Tab from B should land on A")

    # Frame 2: focus=A (first) → Shift-Tab → focus=C (wraps to last).
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, True)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idC):
        _fail("Shift-Tab from A (first) should wrap to C (last)")


def test_tab_from_last_wraps_to_first() raises:
    """Test 6: focus=last → Tab → focus=first. Same shape as test 4 frame 4
    but isolated to make the wrap invariant explicit."""
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    var idA = ImmediateId(111)
    var idB = ImmediateId(222)
    var idC = ImmediateId(333)
    # Seed focus to the last entry directly.
    s.focus = idC
    s.begin_frame(Vec2(500.0, 500.0), False, False, True, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idC, r.copy(), OPT_FOCUSABLE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(idA):
        _fail("Tab from last should wrap to first")


def test_focusable_cleared_each_frame() raises:
    """Test 7: focusable_this_frame is cleared at begin_frame — no
    cross-frame accumulation."""
    var s = ControlState()
    var r = Rect(0.0, 0.0, 100.0, 30.0)
    var idA = ImmediateId(111)
    var idB = ImmediateId(222)

    # Frame 1: register 2 widgets.
    s.begin_frame(Vec2(500.0, 500.0), False, False, False, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    _ = update_control(s, idB, r.copy(), OPT_FOCUSABLE)
    if len(s.focusable_this_frame) != 2:
        _fail("frame 1 should have 2 focusable entries")
    s.end_frame()

    # Frame 2: register 1 widget. The list should be size 1, NOT 3 (which
    # is what would happen if the list was not cleared in begin_frame).
    s.begin_frame(Vec2(500.0, 500.0), False, False, False, False)
    _ = update_control(s, idA, r.copy(), OPT_FOCUSABLE)
    if len(s.focusable_this_frame) != 1:
        _fail(
            "frame 2 should have exactly 1 focusable entry; "
            "begin_frame must clear the list"
        )


# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------


def main() raises:
    test_default_focusable_is_empty()
    test_opt_focusable_registers_id()
    test_no_opt_focusable_does_not_register()
    test_tab_cycles_forward_and_wraps()
    test_shift_tab_cycles_backward_and_wraps()
    test_tab_from_last_wraps_to_first()
    test_focusable_cleared_each_frame()
    print("PASS: all 7 tab-cycling smoke tests")
