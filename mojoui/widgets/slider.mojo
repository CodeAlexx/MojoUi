"""Horizontal slider widget — drag the thumb to set a Float32 in [low, high].

The third real widget after `button`/`label`/`separator` (chunk 17). Follows
the microui 6-step recipe (`get_id → layout_next → update_control → behavior
→ draw → return`) — same shape as `button`, with the BEHAVIOR step doing
real work (mouse_x → value mapping while CTRL_ACTIVE is held).

Public API
----------
    `def slider(mut ctx: Context, mut value: Float32, low: Float32, high: Float32,
                id_str: String) -> Bool`

Returns `True` on every frame the value changes (microui's CHANGED semantic).
`value` is updated in-place via the `mut Float32` parameter — so a host can
read the new value after the call and persist it externally (immediate-mode:
the widget owns no state).

Why `id_str` is required (not derived from the value/range)
------------------------------------------------------------
The first sketch tried `id_str = "slider_" + String(low) + String(high)` so
the caller didn't have to think about IDs. That's a collision footgun: two
sliders with the same range (e.g. two `[0.0, 1.0]` sliders for `volume` and
`opacity`) would hash to the same `ImmediateId` and steal each other's
hover/focus/active slots. Microui solves this by hashing the WIDGET's source
location (a pointer to a static label) — Mojo has no portable equivalent yet.
The pragmatic fix: make the caller supply a unique string. M2.5+ may add an
ergonomic `push_id_str(...)` wrapper so containers scope sliders by parent.

Behavior (step 4 of the recipe)
-------------------------------
While the widget is `CTRL_ACTIVE` (i.e. the mouse went down inside the rect
and has not been released yet — drag-from-here semantics, even if the cursor
later leaves the rect), the value is recomputed every frame from the mouse
x position:

    var frac = (mouse_x - rect.x) / rect.w
    frac    = clamp(frac, 0.0, 1.0)        # cursor outside rect → value clamps
    value   = low + frac * (high - low)

So clicking at the leftmost pixel snaps to `low`, the rightmost snaps to
`high`, and dragging the cursor past the left or right edge holds the value
at the appropriate endpoint (this matches every native OS slider).

Visual (step 5 of the recipe)
-----------------------------
- Track: full width of the rect, 4 px tall, vertically centred, `theme.border`.
- Filled portion: from `rect.x` to thumb centre, 4 px tall, `theme.primary`.
- Thumb: 12 px wide, full rect height, centred on the value's x position.
  Colour follows state — ACTIVE > HOVERED > normal (same precedence as button).

The 4 px / 12 px constants live as module-level `comptime` for now; M3 will
move them into `DefaultTheme` once that grows past its current placeholder set.

`.copy()` discipline (MOJO_NOTES.md "Copyable ≠ ImplicitlyCopyable")
--------------------------------------------------------------------
`Rect`/`Color`/`Vec2`/`DefaultTheme` are `Copyable, Movable` but NOT
`ImplicitlyCopyable`. The slot rect is read at least 4× (update_control,
track draw, filled portion, thumb draw), so every read is `.copy()`'d. The
local `bg` colour binding is `^`-moved into the draw call (saves one copy).
"""

from std.math import min, max

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_ACTIVE,
    OPT_NONE,
)


# Track height (px) — thin horizontal bar that the thumb slides along.
comptime SLIDER_TRACK_H: Float32 = 4.0

# Thumb width (px) — narrow vertical handle, full rect height.
comptime SLIDER_THUMB_W: Float32 = 12.0

# Change-detection epsilon for the returned `changed` Bool. Mouse-driven
# value updates can produce tiny float jitter even at a stationary cursor
# (sub-pixel mouse coords on hi-dpi displays), so we treat |Δ| ≤ EPS as
# "no change" to keep the callback quiet.
comptime SLIDER_CHANGE_EPS: Float32 = 1.0e-6


# ============================================================================
# slider — the 6-step widget
# ============================================================================


def slider(
    mut ctx: Context,
    mut value: Float32,
    low: Float32,
    high: Float32,
    id_str: String,
) -> Bool:
    """Horizontal slider. Drag the thumb to change `value` within `[low, high]`.

    Returns `True` if `value` changed this frame (microui's CHANGED semantic).
    The caller persists `value` between frames — the widget is stateless.

    See module docstring for the behavior, visual, and id_str rationale.
    """
    # 1. id — derive an ImmediateId from the caller-supplied unique string
    #    under the current id_stack top (contextual hashing — same parent
    #    discipline as button). The caller MUST pass distinct id_str values
    #    for distinct sliders; see module docstring on why we can't derive
    #    a unique id from `low`/`high`/`value` alone.
    var id = ctx.get_id(id_str)

    # 2. rect — next layout slot. Same layout flow as button. We read rect
    #    multiple times below, so every consumer takes `.copy()` (or moves
    #    via `^` for the last consumer).
    var rect = ctx.layout_next()

    # 3. update_control — interaction tick. Returns bit-or of CTRL_* flags.
    var flags = ctx.update_control(id, rect.copy(), OPT_NONE)

    # 4. BEHAVIOR — the real work for a slider. While CTRL_ACTIVE is set
    #    (mouse went down inside the rect and has not yet been released —
    #    "drag from here" semantic), recompute `value` from the cursor's
    #    x position mapped to [low, high] over the rect's width.
    #
    #    Cursor outside the rect (left of rect.x or right of rect.right())
    #    clamps to the corresponding endpoint, matching native OS sliders.
    var changed: Bool = False
    if (flags & CTRL_ACTIVE) != 0 and rect.w > 0.0:
        # Use ctx.control.mouse_pos, NOT ctx.input.mouse_pos: the former is
        # threaded in by `begin_frame` / `begin_frame_no_input` and is the
        # same coordinate `update_control` used for hover-testing. The
        # `input.mouse_pos` field is the raw FFI snapshot which is (0, 0)
        # under `begin_frame_no_input` (test path bypasses FFI poll) — so
        # reading it would break headless tests AND silently desync the
        # behavior coordinate from the hit-test coordinate in production.
        var mouse_x = ctx.control.mouse_pos.x
        var frac = (mouse_x - rect.x) / rect.w
        # Clamp into [0, 1]. Cursor outside the rect snaps to the endpoint.
        frac = max(Float32(0.0), min(Float32(1.0), frac))
        var new_value = low + frac * (high - low)
        var delta = new_value - value
        if delta < 0.0:
            delta = -delta
        if delta > SLIDER_CHANGE_EPS:
            changed = True
        value = new_value

    # 5. DRAW — track + filled portion + thumb. State-coloured thumb.
    #
    # Track: thin horizontal bar across the whole rect at vertical centre.
    var track_y = rect.y + (rect.h - SLIDER_TRACK_H) * 0.5
    ctx.draw_rect(
        Rect(rect.x, track_y, rect.w, SLIDER_TRACK_H),
        ctx.theme.border.copy(),
    )

    # Thumb-centre x: where on the track the value lives. The thumb's CENTRE
    # is offset by thumb_w * 0.5 from the slot edges so the thumb's body
    # stays inside the rect at the endpoints (otherwise half the thumb
    # would render outside the slot when value == low or value == high).
    var span = high - low
    var frac_for_draw: Float32 = 0.0
    if span != 0.0:
        frac_for_draw = (value - low) / span
    # Clamp the draw frac too in case caller passes value already out of
    # range — we still want the thumb visible at the nearest endpoint.
    frac_for_draw = max(Float32(0.0), min(Float32(1.0), frac_for_draw))

    # Inset the thumb's travel by half its width so the thumb body stays
    # within the rect bounds. travel = rect.w - thumb_w; thumb_x_left =
    # rect.x + frac * travel; thumb centre = thumb_x_left + thumb_w * 0.5.
    var travel = rect.w - SLIDER_THUMB_W
    if travel < 0.0:
        travel = 0.0
    var thumb_x_left = rect.x + frac_for_draw * travel
    var thumb_centre_x = thumb_x_left + SLIDER_THUMB_W * 0.5

    # Filled portion of the track: from rect.x to thumb centre.
    var filled_w = thumb_centre_x - rect.x
    if filled_w < 0.0:
        filled_w = 0.0
    ctx.draw_rect(
        Rect(rect.x, track_y, filled_w, SLIDER_TRACK_H),
        ctx.theme.primary.copy(),
    )

    # Thumb — full slot height, state-coloured. Precedence: ACTIVE > HOVERED
    # > normal (matches button's bg precedence).
    var thumb_color: Color
    if (flags & CTRL_ACTIVE) != 0:
        thumb_color = ctx.theme.active_bg.copy()
    elif (flags & CTRL_HOVERED) != 0:
        thumb_color = ctx.theme.hover_bg.copy()
    else:
        thumb_color = ctx.theme.primary.copy()
    ctx.draw_rect(
        Rect(thumb_x_left, rect.y, SLIDER_THUMB_W, rect.h),
        thumb_color^,
    )

    # 6. return — surface the CHANGED event. (The slider does not surface
    #    PRESSED/RELEASED — callers that care about drag start/end can read
    #    `ctx.control.active` / `prev_active` directly. M3 may add a small
    #    SliderEvents helper if needed.)
    return changed
