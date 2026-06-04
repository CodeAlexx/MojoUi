"""Smoke tests for `mojoui/core/control.mojo`.

Run: `pixi run test-control`

Covers the per-widget interaction state machine: ControlState defaults,
begin_frame snapshot+roll, update_control across the no-hover / hover /
press / hold / release lifecycle, hover mutual exclusion under overlapping
rects, and OPT_NO_INTERACT skip.
"""

from mojoui.core.types import Vec2, Rect
from mojoui.core.id import ImmediateId, IMM_ID_NONE
from mojoui.core.control import (
    ControlState,
    update_control,
    CTRL_HOVERED,
    CTRL_FOCUSED,
    CTRL_ACTIVE,
    CTRL_PRESSED,
    CTRL_RELEASED,
    CTRL_CHANGED,
    OPT_NONE,
    OPT_HOLD_FOCUS,
    OPT_NO_INTERACT,
    OPT_AUTO_FOCUS,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


@always_inline
def _has(flags: Int32, bit: Int32) -> Bool:
    return (flags & bit) != 0


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


def test_default_state_is_none() raises:
    """Test 1: fresh ControlState() has every slot == IMM_ID_NONE and mouse at 0,0,
    no edges asserted."""
    var s = ControlState()
    if UInt32(s.hover) != UInt32(IMM_ID_NONE):
        _fail("default hover != IMM_ID_NONE")
    if UInt32(s.focus) != UInt32(IMM_ID_NONE):
        _fail("default focus != IMM_ID_NONE")
    if UInt32(s.active) != UInt32(IMM_ID_NONE):
        _fail("default active != IMM_ID_NONE")
    if UInt32(s.prev_hover) != UInt32(IMM_ID_NONE):
        _fail("default prev_hover != IMM_ID_NONE")
    if UInt32(s.prev_focus) != UInt32(IMM_ID_NONE):
        _fail("default prev_focus != IMM_ID_NONE")
    if UInt32(s.prev_active) != UInt32(IMM_ID_NONE):
        _fail("default prev_active != IMM_ID_NONE")
    if UInt32(s.hover_root) != UInt32(IMM_ID_NONE):
        _fail("default hover_root != IMM_ID_NONE")
    if s.mouse_pos.x != 0.0 or s.mouse_pos.y != 0.0:
        _fail("default mouse_pos != (0,0)")
    if s.mouse_pressed_this_frame:
        _fail("default mouse_pressed_this_frame should be False")
    if s.mouse_released_this_frame:
        _fail("default mouse_released_this_frame should be False")


def test_begin_frame_rolls_prev_and_clears_hover() raises:
    """Test 2: begin_frame snapshots current hover/focus/active into prev_*,
    clears hover (recomputed each frame), and records mouse_pos + edges."""
    var s = ControlState()
    # Seed some state as if a previous frame had hover/focus/active set.
    s.hover = ImmediateId(101)
    s.focus = ImmediateId(202)
    s.active = ImmediateId(303)
    s.hover_root = ImmediateId(404)
    s.begin_frame(Vec2(50.0, 60.0), False, False)

    if UInt32(s.prev_hover) != UInt32(101):
        _fail("prev_hover not rolled from hover")
    if UInt32(s.prev_focus) != UInt32(202):
        _fail("prev_focus not rolled from focus")
    if UInt32(s.prev_active) != UInt32(303):
        _fail("prev_active not rolled from active")
    if UInt32(s.hover) != UInt32(IMM_ID_NONE):
        _fail("hover must be cleared by begin_frame (recomputed each frame)")
    if UInt32(s.hover_root) != UInt32(IMM_ID_NONE):
        _fail("hover_root must be cleared by begin_frame")
    if UInt32(s.focus) != UInt32(202):
        _fail("focus must NOT be cleared by begin_frame (sticky)")
    if UInt32(s.active) != UInt32(303):
        _fail("active must NOT be cleared by begin_frame (cleared in end_frame)")
    if s.mouse_pos.x != 50.0 or s.mouse_pos.y != 60.0:
        _fail("mouse_pos not recorded")
    if s.mouse_pressed_this_frame:
        _fail("mouse_pressed should be False")
    if s.mouse_released_this_frame:
        _fail("mouse_released should be False")


def test_no_hover_when_mouse_outside() raises:
    """Test 3: mouse outside the rect — no hover, no flags, no slot writes."""
    var s = ControlState()
    s.begin_frame(Vec2(500.0, 500.0), False, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    var flags = update_control(s, id, rect, OPT_NONE)
    if flags != 0:
        _fail("flags should be 0 when mouse is outside")
    if UInt32(s.hover) != UInt32(IMM_ID_NONE):
        _fail("hover should remain NONE when mouse outside")
    if UInt32(s.focus) != UInt32(IMM_ID_NONE):
        _fail("focus should remain NONE")
    if UInt32(s.active) != UInt32(IMM_ID_NONE):
        _fail("active should remain NONE")


def test_hover_only_when_no_press() raises:
    """Test 4: mouse INSIDE rect, no press — only CTRL_HOVERED set, focus/active
    remain NONE."""
    var s = ControlState()
    s.begin_frame(Vec2(20.0, 20.0), False, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    var flags = update_control(s, id, rect, OPT_NONE)
    if not _has(flags, CTRL_HOVERED):
        _fail("CTRL_HOVERED expected")
    if _has(flags, CTRL_PRESSED):
        _fail("CTRL_PRESSED unexpected (no press this frame)")
    if _has(flags, CTRL_FOCUSED):
        _fail("CTRL_FOCUSED unexpected (no press to grant focus)")
    if _has(flags, CTRL_ACTIVE):
        _fail("CTRL_ACTIVE unexpected (no press to activate)")
    if _has(flags, CTRL_RELEASED):
        _fail("CTRL_RELEASED unexpected (no active to release)")
    if UInt32(s.hover) != UInt32(id):
        _fail("hover slot should be set to id")


def test_press_grants_hover_focus_active() raises:
    """Test 5: mouse INSIDE rect with press — HOVERED | PRESSED | FOCUSED | ACTIVE
    all reported; focus + active slots claimed."""
    var s = ControlState()
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    var flags = update_control(s, id, rect, OPT_NONE)
    if not _has(flags, CTRL_HOVERED):
        _fail("CTRL_HOVERED expected after press-in")
    if not _has(flags, CTRL_PRESSED):
        _fail("CTRL_PRESSED expected on press edge")
    if not _has(flags, CTRL_FOCUSED):
        _fail("CTRL_FOCUSED expected after press grants focus")
    if not _has(flags, CTRL_ACTIVE):
        _fail("CTRL_ACTIVE expected after press claims active")
    if _has(flags, CTRL_RELEASED):
        _fail("CTRL_RELEASED unexpected on press frame")
    if UInt32(s.hover) != UInt32(id):
        _fail("hover slot should be id after press")
    if UInt32(s.focus) != UInt32(id):
        _fail("focus slot should be id after press")
    if UInt32(s.active) != UInt32(id):
        _fail("active slot should be id after press")


def test_hold_keeps_focus_and_active() raises:
    """Test 6: continuation of test 5 — next frame mouse still inside rect, no
    new press, no release — still HOVERED | FOCUSED | ACTIVE (no PRESSED edge,
    no RELEASED edge)."""
    var s = ControlState()
    # Frame 1: press inside
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()

    # Frame 2: holding — mouse still inside, no new edges
    s.begin_frame(Vec2(20.0, 20.0), False, False)
    var flags = update_control(s, id, rect, OPT_NONE)
    if not _has(flags, CTRL_HOVERED):
        _fail("CTRL_HOVERED expected during hold")
    if not _has(flags, CTRL_FOCUSED):
        _fail("CTRL_FOCUSED expected during hold (sticky)")
    if not _has(flags, CTRL_ACTIVE):
        _fail("CTRL_ACTIVE expected during hold (not cleared without release)")
    if _has(flags, CTRL_PRESSED):
        _fail("CTRL_PRESSED unexpected during hold (no new press edge)")
    if _has(flags, CTRL_RELEASED):
        _fail("CTRL_RELEASED unexpected during hold (no release edge)")


def test_release_emits_click_and_clears_active() raises:
    """Test 7: continuation of test 6 — release inside rect: HOVERED | FOCUSED |
    RELEASED reported; end_frame clears active."""
    var s = ControlState()
    # Frame 1: press
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()
    # Frame 2: hold
    s.begin_frame(Vec2(20.0, 20.0), False, False)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()
    # Frame 3: release inside
    s.begin_frame(Vec2(20.0, 20.0), False, True)
    var flags = update_control(s, id, rect, OPT_NONE)
    if not _has(flags, CTRL_HOVERED):
        _fail("CTRL_HOVERED expected on release frame (mouse still inside)")
    if not _has(flags, CTRL_FOCUSED):
        _fail("CTRL_FOCUSED expected on release (focus persists)")
    if not _has(flags, CTRL_RELEASED):
        _fail("CTRL_RELEASED expected — this is the click event")
    if not _has(flags, CTRL_ACTIVE):
        _fail("CTRL_ACTIVE expected during update_control (cleared by end_frame)")
    if _has(flags, CTRL_PRESSED):
        _fail("CTRL_PRESSED unexpected on release frame")
    s.end_frame()
    if UInt32(s.active) != UInt32(IMM_ID_NONE):
        _fail("end_frame must clear active on mouse-release")
    # Focus persists across the click — it's sticky.
    if UInt32(s.focus) != UInt32(id):
        _fail("focus must persist after click (sticky)")


def test_release_outside_is_drag_cancel() raises:
    """Released-while-not-over does NOT trigger CTRL_RELEASED (drag-cancel
    semantic). Active slot still cleared in end_frame."""
    var s = ControlState()
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    # Press inside
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()
    # Release OUTSIDE rect
    s.begin_frame(Vec2(500.0, 500.0), False, True)
    var flags = update_control(s, id, rect, OPT_NONE)
    if _has(flags, CTRL_RELEASED):
        _fail("CTRL_RELEASED must NOT fire when release lands outside rect")
    if _has(flags, CTRL_HOVERED):
        _fail("CTRL_HOVERED must NOT fire when mouse is outside rect")
    if not _has(flags, CTRL_ACTIVE):
        _fail("CTRL_ACTIVE should still be set this frame (cleared by end_frame)")
    s.end_frame()
    if UInt32(s.active) != UInt32(IMM_ID_NONE):
        _fail("end_frame must clear active on release even when outside")


def test_hover_mutual_exclusion_last_wins() raises:
    """Test 8: two widgets at overlapping rects, mouse inside both.
    update_control(A) then update_control(B) — only B is hover (last wins).
    Mirrors immediate-mode "deeper containers called last" pattern."""
    var s = ControlState()
    s.begin_frame(Vec2(30.0, 30.0), False, False)
    var rect_outer = Rect(0.0, 0.0, 100.0, 100.0)
    var rect_inner = Rect(20.0, 20.0, 40.0, 40.0)
    var id_outer = ImmediateId(1)
    var id_inner = ImmediateId(2)

    var flags_outer = update_control(s, id_outer, rect_outer, OPT_NONE)
    if not _has(flags_outer, CTRL_HOVERED):
        _fail("outer widget should briefly claim hover")
    if UInt32(s.hover) != UInt32(id_outer):
        _fail("after outer call, hover should be outer")

    var flags_inner = update_control(s, id_inner, rect_inner, OPT_NONE)
    if not _has(flags_inner, CTRL_HOVERED):
        _fail("inner widget should claim hover (mouse also inside it)")
    if UInt32(s.hover) != UInt32(id_inner):
        _fail("after inner call, hover must be inner (last evaluated wins)")


def test_no_interact_returns_zero() raises:
    """Test 9: OPT_NO_INTERACT short-circuits — returns 0 even with mouse
    inside, never sets hover/focus/active."""
    var s = ControlState()
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    var flags = update_control(s, id, rect, OPT_NO_INTERACT)
    if flags != 0:
        _fail("OPT_NO_INTERACT must return 0 flags")
    if UInt32(s.hover) != UInt32(IMM_ID_NONE):
        _fail("OPT_NO_INTERACT must not claim hover")
    if UInt32(s.focus) != UInt32(IMM_ID_NONE):
        _fail("OPT_NO_INTERACT must not claim focus on press")
    if UInt32(s.active) != UInt32(IMM_ID_NONE):
        _fail("OPT_NO_INTERACT must not claim active on press")


def test_press_outside_focused_widget_drops_focus() raises:
    """Press-outside a focused widget drops focus (microui-style click-out
    blur). The focused widget sees mouse_pressed && !mouse_over and clears
    its own focus slot."""
    var s = ControlState()
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    # Frame 1: press inside grants focus
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()
    s.begin_frame(Vec2(20.0, 20.0), False, True)
    _ = update_control(s, id, rect, OPT_NONE)
    s.end_frame()
    if UInt32(s.focus) != UInt32(id):
        _fail("setup: focus should be on widget after click")
    # Frame 3: press OUTSIDE the focused widget
    s.begin_frame(Vec2(500.0, 500.0), True, False)
    _ = update_control(s, id, rect, OPT_NONE)
    if UInt32(s.focus) != UInt32(IMM_ID_NONE):
        _fail("press-outside should clear focus (default — no OPT_HOLD_FOCUS)")


def test_hold_focus_keeps_focus_on_press_outside() raises:
    """OPT_HOLD_FOCUS prevents the click-outside-blurs-focus behavior. Used
    by widgets that open auxiliary UI (popups)."""
    var s = ControlState()
    var rect = Rect(10.0, 10.0, 50.0, 30.0)
    var id = ImmediateId(42)
    # Grant focus first
    s.begin_frame(Vec2(20.0, 20.0), True, False)
    _ = update_control(s, id, rect, OPT_HOLD_FOCUS)
    s.end_frame()
    s.begin_frame(Vec2(20.0, 20.0), False, True)
    _ = update_control(s, id, rect, OPT_HOLD_FOCUS)
    s.end_frame()
    # Press outside — focus should be PRESERVED with OPT_HOLD_FOCUS
    s.begin_frame(Vec2(500.0, 500.0), True, False)
    _ = update_control(s, id, rect, OPT_HOLD_FOCUS)
    if UInt32(s.focus) != UInt32(id):
        _fail("OPT_HOLD_FOCUS should keep focus despite press-outside")


def test_set_focus_helper() raises:
    """ControlState.set_focus / is_hovered / is_focused / is_active sanity."""
    var s = ControlState()
    s.set_focus(ImmediateId(7))
    if not s.is_focused(ImmediateId(7)):
        _fail("set_focus(7); is_focused(7) should be True")
    if s.is_focused(ImmediateId(8)):
        _fail("is_focused(8) should be False after set_focus(7)")
    s.hover = ImmediateId(3)
    s.active = ImmediateId(4)
    if not s.is_hovered(ImmediateId(3)):
        _fail("is_hovered(3) should be True")
    if not s.is_active(ImmediateId(4)):
        _fail("is_active(4) should be True")
    s.set_focus(IMM_ID_NONE)
    if s.is_focused(ImmediateId(7)):
        _fail("set_focus(IMM_ID_NONE) should clear focus")


def test_ctrl_changed_bit_exists() raises:
    """CTRL_CHANGED is exposed for widget code to OR into its own flags
    (slider/text-edit/checkbox). update_control itself never sets it.
    Bit-non-overlap is enforced at compile time by the comptime `1 << N`
    definitions — there's no runtime overlap check needed."""
    if Int32(CTRL_CHANGED) == 0:
        _fail("CTRL_CHANGED should be non-zero (a real bit)")
    # Smoke: OR'ing CTRL_CHANGED into a flag word does not corrupt other bits
    var w: Int32 = CTRL_HOVERED | CTRL_FOCUSED
    var w2: Int32 = w | CTRL_CHANGED
    if not _has(w2, CTRL_HOVERED):
        _fail("OR'ing CTRL_CHANGED should preserve CTRL_HOVERED")
    if not _has(w2, CTRL_FOCUSED):
        _fail("OR'ing CTRL_CHANGED should preserve CTRL_FOCUSED")
    if not _has(w2, CTRL_CHANGED):
        _fail("OR'ing CTRL_CHANGED should set CTRL_CHANGED")


def main() raises:
    test_default_state_is_none()
    test_begin_frame_rolls_prev_and_clears_hover()
    test_no_hover_when_mouse_outside()
    test_hover_only_when_no_press()
    test_press_grants_hover_focus_active()
    test_hold_keeps_focus_and_active()
    test_release_emits_click_and_clears_active()
    test_release_outside_is_drag_cancel()
    test_hover_mutual_exclusion_last_wins()
    test_no_interact_returns_zero()
    test_press_outside_focused_widget_drops_focus()
    test_hold_focus_keeps_focus_on_press_outside()
    test_set_focus_helper()
    test_ctrl_changed_bit_exists()
    print("PASS: control smoke tests (14 tests)")
