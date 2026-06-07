"""Vertical scroll-area container — M2 chunk 28.

A fixed-height container that clips its children to a viewport rect and lets
the user drag inside the viewport to scroll the content vertically. The
caller owns the `scroll_y: Float32` state (microui-style — widgets do not
keep retained state; the caller stores it in their app state and threads it
through each frame).

Usage:

    var scroll_y: Float32 = 0.0
    ...
    if begin_scroll_area(ctx, "log_view", 240, scroll_y):
        # scroll_y changed this frame — e.g. invalidate a derived cache here.
        pass
    _ = label(ctx, String("line 1"))
    _ = label(ctx, String("line 2"))
    ...
    end_scroll_area(ctx)

The begin/end pair MUST balance. `begin_scroll_area` pushes one layout frame
and emits ONE `CMD_CLIP`; `end_scroll_area` pops that layout frame and emits
a second `CMD_CLIP` that restores the clip rect to `ctx.window_rect`.

For M2 the implementation is minimal but real:

  * Outer slot is taken from the current layout flow via `ctx.layout_next()`.
    Its height is clamped to `area_height` (the caller controls how tall the
    viewport is; the outer slot supplies x/y/width).
  * The viewport rect is registered with `update_control` so the standard
    interaction state machine (hover/active) drives drag-to-scroll.
  * On `CTRL_ACTIVE`, the frame's `mouse_delta.y` is subtracted from
    `scroll_y` so dragging DOWN (delta.y > 0) moves the CONTENT DOWN — which
    is `scroll_y` getting more negative — which by our convention means
    "show earlier content". We follow the simpler convention used by the
    chunk contract: subtract `mouse_delta.y` from `scroll_y`. The caller is
    responsible for clamping at the upper bound (we only clamp at 0 here);
    M2 deliberately does NOT auto-compute content height.
  * Inner layout frame has the same x/width as the viewport but its y is
    shifted by `-scroll_y` (so children flow at an offset) and its height is
    a generous `area_height * 4.0` — enough room for the caller to emit a
    reasonable amount of content. Real content-height awareness (and an
    accompanying scrollbar widget + mouse-wheel input) lands in a later
    chunk.
  * A `CMD_CLIP` is emitted with the viewport rect so the renderer adapter
    scissors children to it; `end_scroll_area` emits a matching `CMD_CLIP`
    restoring `ctx.window_rect` so subsequent widgets are not clipped.

`.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Rect`/`Vec2` reads to pass into another call need `.copy()`. `Float32` is
`ImplicitlyCopyable` so the bound `scroll_y` and `mouse_delta.y` reads do
NOT need `.copy()`.

What this chunk deliberately does NOT do:
  * Horizontal scrolling — separate widget once needed.
  * A visible scroll bar — separate widget; this is just the container.
  * Auto-clamping `scroll_y` against content height — the caller manages
    that. The only clamp here is the lower bound `scroll_y >= 0`.
  * Mouse-wheel events — these require a new FFI extension and are out of
    scope for M2 chunk 28.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.control import CTRL_ACTIVE, CTRL_HOVERED, OPT_NONE


# ============================================================================
# begin_scroll_area / end_scroll_area
# ============================================================================


def begin_scroll_area(
    mut ctx: Context,
    id_str: String,
    area_height: Int32,
    mut scroll_y: Float32,
) -> Bool:
    """Begin a vertical scroll container of fixed height `area_height` (px).

    Returns True if `scroll_y` was modified by drag this frame (caller can
    use this to invalidate derived caches, etc.).

    MUST be paired with `end_scroll_area(ctx)` later in the same frame.
    Between the two calls, widget calls flow inside the inner layout frame
    (offset by `-scroll_y` so dragging "scrolls" the content) and draw
    commands are clipped to the viewport rect.

    Behavior:
      * If CTRL_ACTIVE this frame, accumulate `-mouse_delta.y` into
        `scroll_y` (dragging down moves the visible viewport down).
      * Clamp `scroll_y` to >= 0 (caller manages the upper bound for M2).
      * Emit one CMD_CLIP with the viewport rect.
      * Push an inner layout frame at (x, y - scroll_y, w, area_height * 4).
    """
    # 1. id — derive from the caller-supplied label (a "Window Title"-style
    #    stable string). We do NOT derive from `scroll_y` since the value
    #    changes every frame; the id must be stable across frames.
    var id = ctx.get_id(id_str)

    # 2. outer slot — take from the current layout flow. The slot's x/y/w
    #    come from the parent's row mechanics; we override h to area_height
    #    so callers can place a 24-row-template scroll area without having
    #    to set up a custom row first. Constructing a fresh Rect avoids the
    #    "Copyable ≠ ImplicitlyCopyable" wall on Rect-field mutation.
    var outer = ctx.layout_next()
    var viewport = Rect(outer.x, outer.y, outer.w, Float32(area_height))

    # 3. update_control — the viewport rect is the drag handle. Pass by
    #    `.copy()` because we need `viewport` again for the clip emit and
    #    the inner layout push.
    var flags = ctx.update_control(id, viewport.copy(), OPT_NONE)

    # 4. behavior — accumulate vertical drag into `scroll_y` while ACTIVE.
    #    Float32 is ImplicitlyCopyable so no `.copy()` is needed on
    #    `mouse_delta.y` or `scroll_y`.
    var changed: Bool = False
    if (flags & CTRL_ACTIVE) != 0:
        var dy: Float32 = ctx.input.mouse_delta.y
        if dy != 0.0:
            scroll_y = scroll_y - dy
            changed = True
    if (flags & CTRL_HOVERED) != 0:
        var wheel_y: Float32 = ctx.input.scroll_delta.y
        if wheel_y != 0.0:
            scroll_y = scroll_y - wheel_y * 80.0
            changed = True

    # 5. clamp the lower bound. For M2 we do NOT know the content height,
    #    so we only enforce `scroll_y >= 0` (cannot scroll above the top of
    #    the content). The caller is responsible for the upper bound.
    if scroll_y < 0.0:
        scroll_y = 0.0

    # 6. emit a CMD_CLIP scoping subsequent draws to the viewport rect.
    #    Renderer adapter sets the GPU scissor to this rect.
    ctx.draw_clip(viewport.copy())

    # 7. push an inner layout frame. Children flow inside this frame,
    #    offset upward by `scroll_y` so dragging visually scrolls the
    #    content. Inner height is generous (area_height * 4.0) — M2
    #    callers manage their own content layout, this number just needs
    #    to be larger than what they emit to avoid premature row wrap.
    var inner_body = Rect(
        viewport.x,
        viewport.y - scroll_y,
        viewport.w,
        Float32(area_height) * 8.0,
    )
    ctx.layout.push(inner_body^)

    # 8. push an id_stack scope so child widgets emitted inside this scroll
    #    area do NOT collide with widgets outside (e.g. two `label("row")`s
    #    inside vs outside, or two scroll areas containing the same child
    #    labels). Paired with `ctx.pop_id()` in `end_scroll_area`. See
    #    regression notes FRAGILE #3.
    ctx.push_id_str(id_str)

    return changed


def end_scroll_area(mut ctx: Context):
    """End the matching `begin_scroll_area`: pop the inner layout frame and
    emit a CMD_CLIP restoring the clip rect to the full window.

    Caller invariant: every `begin_scroll_area` MUST be matched by exactly
    one `end_scroll_area`. Mismatched pairs leak a layout frame, which
    `Context.end_frame` will report (one-line warning + auto-pop).
    """
    # Pop the id_stack scope pushed by begin_scroll_area (see FRAGILE #3).
    ctx.pop_id()

    # Pop the inner layout frame pushed by begin_scroll_area.
    ctx.layout.pop()

    # Restore the clip rect to the full window so subsequent widgets are
    # not clipped to the now-popped viewport. Renderer adapter sets the
    # GPU scissor back to the window bounds.
    ctx.draw_clip(ctx.window_rect.copy())
