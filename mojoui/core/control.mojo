"""Per-widget interaction state machine for MojoUI.

`ControlState` is the per-frame ownership record of WHO has the mouse hover,
WHO has keyboard focus, and WHO is currently being clicked (active). Owned by
`Context` (chunk 16); consumed every frame by widget functions (chunk 17+) via
`update_control(ctx.controls, id, rect, opts)` as step 3 of the 6-step microui
recipe (`get_id → layout_next → update_control → behavior → draw → return`).

Invariants (mirror microui per /home/alex/mojoui-audit/AUDIT_microui.md
"Focus / Hover / Active State"): at most ONE id is `hover`, ONE is `focus`,
ONE is `active`. These are three distinct slots — a button can be hovered +
focused + active simultaneously (the user-is-mid-click state).

The mouse-edge inputs (`mouse_pressed_this_frame`, `mouse_released_this_frame`)
are pre-computed by `core/input.mojo` (chunk 15) from raw FFI level state and
threaded in via `begin_frame()`. This module does NOT poll input itself.

Return flags from `update_control`: bit-or of `CTRL_*` constants. Widget code
typically pattern-matches the result to drive its behavior step:

    var flags = update_control(state, id, rect, OPT_NONE)
    if (flags & CTRL_RELEASED) != 0:   # the click event
        ...
    if (flags & CTRL_HOVERED) != 0:    # paint hover frame
        ...

Out of scope: input polling (c15), layout (c13), command emission (c12),
widgets (c17+), Context container (c16).
"""

from mojoui.core.types import Vec2, Rect
from mojoui.core.id import ImmediateId, IMM_ID_NONE


# `comptime` (not `alias`) per current beta — see MOJO_NOTES.md.

# Result flags returned by `update_control` (bit-or'd).
comptime CTRL_HOVERED: Int32 = 1 << 0
"""Mouse cursor over this widget's rect AND widget claimed hover (topmost
under cursor by call order)."""

comptime CTRL_FOCUSED: Int32 = 1 << 1
"""Widget holds keyboard focus. Sticky across frames; granted on mouse-down
inside the widget; cleared on click-outside unless `OPT_HOLD_FOCUS`."""

comptime CTRL_ACTIVE: Int32 = 1 << 2
"""Mouse currently down on this widget. Persists if cursor leaves rect after
press (drag-from-here semantic); cleared on release in `end_frame`."""

comptime CTRL_PRESSED: Int32 = 1 << 3
"""One-frame rising edge: mouse went down this frame inside the rect."""

comptime CTRL_RELEASED: Int32 = 1 << 4
"""One-frame falling edge: mouse went up this frame inside this widget's rect
AND the widget was current `active`. Semantically the "click" event. A
release OUTSIDE the rect is a drag-cancel and does NOT set this flag."""

comptime CTRL_CHANGED: Int32 = 1 << 5
"""Widget value changed this frame (slider/text-edit/checkbox). NEVER set by
update_control — widget code OR's it into its own returned flags."""


# Behavior options passed INTO `update_control` (bit-or'd).
comptime OPT_NONE: Int32 = 0
"""Default — no special behavior."""

comptime OPT_HOLD_FOCUS: Int32 = 1 << 0
"""Don't drop focus on click-outside. For widgets opening auxiliary UI (e.g.
text input with completion popup). Default is microui-style: any press
outside a focused widget clears focus."""

comptime OPT_NO_INTERACT: Int32 = 1 << 1
"""Display-only widget (labels, separators). Short-circuit: never sets
hover/focus/active, always returns 0. = microui's `MU_OPT_NOINTERACT`."""

comptime OPT_AUTO_FOCUS: Int32 = 1 << 2
"""Grab focus on first sighting if focus is currently NONE. Rare — for
"open dialog with OK focused" patterns. Real first-sighting tracking would
need a seen-set in Context (c16); this approximates as "focus is empty"."""

comptime OPT_FOCUSABLE: Int32 = 1 << 3
"""Widget participates in Tab / Shift-Tab keyboard focus cycling (c52).
When set, `update_control` appends this widget's id to
`ControlState.focusable_this_frame` so `end_frame` can advance focus
through the registered widgets when the user presses Tab. Widgets that
should be reachable by keyboard (button, text_edit, slider, etc.) should
pass this in their `opts` mask. Display-only widgets (label, separator)
should NOT pass it."""


struct ControlState(Movable):
    """Per-frame interaction state slots. Owned by `Context` (c16).

    Three single-id slots (`hover`, `focus`, `active`) enforce mutual
    exclusion. `prev_*` shadows preserve last frame's values after
    `begin_frame` rolls state forward. Not `Copyable` — exactly ONE per
    Context, must not silently duplicate.
    """

    var hover: ImmediateId
    """Currently hovered id, or IMM_ID_NONE. Recomputed each frame: cleared
    in `begin_frame`, set by `update_control` calls (last claimant wins —
    deeper widgets typically run last)."""

    var focus: ImmediateId
    """Currently keyboard-focused id. Sticky. Press-inside grants; press-
    outside clears (unless `OPT_HOLD_FOCUS` was set on the focused widget)."""

    var active: ImmediateId
    """Currently mouse-down id. Set on press-inside; cleared in `end_frame`
    on release. Stays set if cursor leaves rect after press."""

    var prev_hover: ImmediateId
    var prev_focus: ImmediateId
    var prev_active: ImmediateId

    var hover_root: ImmediateId
    """Topmost container under cursor (for window/popup scoping). M1 keeps
    the slot but does not yet gate on it — wiring lands with Context (c16)."""

    var mouse_pos: Vec2
    """Cursor position remembered for hover testing. Threaded in by
    `begin_frame` from the `core/input.mojo` snapshot."""

    var mouse_pressed_this_frame: Bool
    """LMB rising edge — pre-computed by `core/input.mojo`."""

    var mouse_released_this_frame: Bool
    """LMB falling edge — pre-computed by `core/input.mojo`."""

    var tab_pressed_this_frame: Bool
    """Tab key rising edge (MOJOUI_KEY_TAB) — pre-computed by
    `core/input.mojo` and threaded in by `Context.begin_frame`. Drives the
    focus cycle in `end_frame` (c52)."""

    var shift_held: Bool
    """True iff EITHER left- or right-shift is currently down — pre-computed
    by `core/input.mojo`. Combined with `tab_pressed_this_frame` to choose
    forward (Tab) vs reverse (Shift-Tab) cycling direction (c52)."""

    var focusable_this_frame: List[ImmediateId]
    """Ordered widget-id list for this frame's Tab focus cycle (c52).
    Populated by each `update_control(..., OPT_FOCUSABLE)` call; consumed
    in `end_frame` to advance focus when Tab is pressed; cleared in
    `begin_frame` so each frame starts fresh (no cross-frame
    accumulation)."""

    @always_inline
    def __init__(out self):
        self.hover = IMM_ID_NONE
        self.focus = IMM_ID_NONE
        self.active = IMM_ID_NONE
        self.prev_hover = IMM_ID_NONE
        self.prev_focus = IMM_ID_NONE
        self.prev_active = IMM_ID_NONE
        self.hover_root = IMM_ID_NONE
        self.mouse_pos = Vec2.zero()
        self.mouse_pressed_this_frame = False
        self.mouse_released_this_frame = False
        self.tab_pressed_this_frame = False
        self.shift_held = False
        self.focusable_this_frame = List[ImmediateId]()

    def begin_frame(
        mut self,
        mouse_pos: Vec2,
        mouse_pressed: Bool,
        mouse_released: Bool,
        tab_pressed: Bool = False,
        shift_held: Bool = False,
    ):
        """Snapshot input + roll prev_* over. Called by `Context.begin_frame`.

        Hover is recomputed every frame, so it's cleared here. Focus +
        active persist; their previous values are saved into `prev_*`.

        `tab_pressed` / `shift_held` (c52): Tab rising-edge + shift level —
        consumed in `end_frame` to advance focus through the registered
        focusable widgets. Defaulted to False so the older
        `begin_frame(mouse_pos, pressed, released)` call shape continues
        working for callers that do not yet pass keyboard state.

        Also clears `focusable_this_frame` so this frame's
        `update_control(OPT_FOCUSABLE)` calls start from an empty list
        (no cross-frame accumulation).
        """
        self.prev_hover = self.hover
        self.prev_focus = self.focus
        self.prev_active = self.active
        self.hover = IMM_ID_NONE
        self.hover_root = IMM_ID_NONE
        # Vec2 is Copyable-not-ImplicitlyCopyable in current beta; need
        # explicit .copy() — see MOJO_NOTES.md "Vec2 is Copyable but NOT
        # ImplicitlyCopyable".
        self.mouse_pos = mouse_pos.copy()
        self.mouse_pressed_this_frame = mouse_pressed
        self.mouse_released_this_frame = mouse_released
        self.tab_pressed_this_frame = tab_pressed
        self.shift_held = shift_held
        # Reset the per-frame focusable registry — widgets re-register every
        # frame by calling `update_control(..., OPT_FOCUSABLE)`.
        self.focusable_this_frame = List[ImmediateId]()

    def end_frame(mut self):
        """Finalize state for next frame. Called by `Context.end_frame`.

        On mouse-release, clear `active` (per-widget calls already saw the
        release and emitted CTRL_RELEASED if applicable). Focus-clear-on-
        click-outside is handled per-widget in `update_control` (each
        focused widget sees `mouse_pressed && !mouse_over` and drops focus
        itself unless OPT_HOLD_FOCUS).

        Tab focus cycling (c52): if `tab_pressed_this_frame` AND any
        focusable widget registered, advance `focus` to the next (or
        previous, under shift) entry in `focusable_this_frame`, wrapping
        at the ends. If current focus is not in the list (e.g. nothing
        focused yet, or focused widget was not registered this frame),
        Tab jumps to the FIRST entry and Shift-Tab to the LAST.
        """
        if self.mouse_released_this_frame:
            self.active = IMM_ID_NONE

        # Focus tab-cycling — c52. Apply AFTER mouse-release clears active
        # so the next frame's update_control sees the new focus value.
        var n = len(self.focusable_this_frame)
        if self.tab_pressed_this_frame and n > 0:
            # Find the current focus position in the focusable list.
            # Returns n (== "not found") when focus is IMM_ID_NONE or
            # the focused widget didn't register this frame.
            var cur_idx = n
            for i in range(n):
                if UInt32(self.focusable_this_frame[i]) == UInt32(self.focus):
                    cur_idx = i
                    break
            var next_idx: Int
            if self.shift_held:
                # Shift-Tab: previous (wrap to last when not-found OR at 0).
                if cur_idx == n or cur_idx == 0:
                    next_idx = n - 1
                else:
                    next_idx = cur_idx - 1
            else:
                # Plain Tab: next (wrap to first when not-found OR at last).
                if cur_idx == n or cur_idx == n - 1:
                    next_idx = 0
                else:
                    next_idx = cur_idx + 1
            self.focus = self.focusable_this_frame[next_idx]

    @always_inline
    def set_focus(mut self, id: ImmediateId):
        """Explicit focus set. Pass `IMM_ID_NONE` to clear."""
        self.focus = id

    @always_inline
    def is_hovered(self, id: ImmediateId) -> Bool:
        return UInt32(self.hover) == UInt32(id)

    @always_inline
    def is_focused(self, id: ImmediateId) -> Bool:
        return UInt32(self.focus) == UInt32(id)

    @always_inline
    def is_active(self, id: ImmediateId) -> Bool:
        return UInt32(self.active) == UInt32(id)


def update_control(
    mut state: ControlState,
    id: ImmediateId,
    rect: Rect,
    opts: Int32,
) -> Int32:
    """The microui-style per-widget interaction tick (step 3 of the 6-step
    widget recipe). Returns bit-or of `CTRL_*` flags reporting this
    widget's state. Updates `state.hover` / `state.focus` / `state.active`
    per mouse position and pre-edge-detected press/release booleans.

    Args:
        state: The per-frame ControlState (owned by Context).
        id: The widget's ImmediateId (from `core/id.mojo`).
        rect: The widget's screen-space rect (from `core/layout.mojo`).
        opts: Bit-or of `OPT_*` flags. `OPT_NONE` for default.

    Returns:
        Bit-or of CTRL_HOVERED, CTRL_FOCUSED, CTRL_ACTIVE, CTRL_PRESSED,
        CTRL_RELEASED. OPT_NO_INTERACT always returns 0.
    """
    if (opts & OPT_NO_INTERACT) != 0:
        return 0

    var mouse_over = rect.contains(state.mouse_pos)
    var flags: Int32 = 0

    # OPT_FOCUSABLE (c52): register this widget in the per-frame tab-cycle
    # list. Done BEFORE any state mutation so even widgets that drop focus
    # this frame still appear in the list and remain reachable via Tab.
    if (opts & OPT_FOCUSABLE) != 0:
        state.focusable_this_frame.append(id)

    # OPT_AUTO_FOCUS: take focus on first sighting if focus is currently NONE.
    if (opts & OPT_AUTO_FOCUS) != 0:
        if UInt32(state.focus) == UInt32(IMM_ID_NONE):
            state.focus = id

    # Hover: cursor-over claims hover. Last-evaluated wins by call order —
    # deeper containers iterated AFTER parents overwrite outer claims. When
    # Context lands (c16) with hover_root scoping, this gains a parent-
    # window gate.
    if mouse_over:
        state.hover = id
        flags = flags | CTRL_HOVERED

    # Press inside: claim active + focus (one-frame edge).
    if mouse_over and state.mouse_pressed_this_frame:
        state.active = id
        state.focus = id
        flags = flags | CTRL_PRESSED

    # Press-outside-a-focused-widget clears focus (microui-style click-out
    # blur), unless OPT_HOLD_FOCUS is set. The focused widget sees
    # `mouse_pressed && !mouse_over` and drops focus voluntarily.
    if (
        state.mouse_pressed_this_frame
        and not mouse_over
        and UInt32(state.focus) == UInt32(id)
        and (opts & OPT_HOLD_FOCUS) == 0
    ):
        state.focus = IMM_ID_NONE

    if UInt32(state.focus) == UInt32(id):
        flags = flags | CTRL_FOCUSED
    if UInt32(state.active) == UInt32(id):
        flags = flags | CTRL_ACTIVE

    # Release inside while active: the click event. Release OUTSIDE the rect
    # is a drag-cancel — active slot is still cleared in end_frame but
    # CTRL_RELEASED is NOT emitted.
    if (
        UInt32(state.active) == UInt32(id)
        and state.mouse_released_this_frame
        and mouse_over
    ):
        flags = flags | CTRL_RELEASED

    return flags
