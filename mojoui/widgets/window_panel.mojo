"""Draggable window panel container — M2 chunk 30.

A free-floating rectangular container with a draggable title bar plus a body
area below. Caller owns the window's `rect: Rect` (microui-style — no
retained widget state); dragging the title bar mutates `rect` in place so
the next frame redraws the window at the new position. The pair
`begin_window` / `end_window` MUST balance: every `begin_window` is
followed by exactly one `end_window` in the same frame.

Usage:

    var rect = Rect(40.0, 60.0, 280.0, 200.0)
    if begin_window(ctx, "settings", "Settings", rect):
        _ = label(ctx, String("hello"))
        _ = button(ctx, String("close"))
    end_window(ctx)

### JUMP semantics in M2 — IMPORTANT

The full microui z-ordering trick threads multiple windows into a linked
list of JUMPs that the renderer walks in z-order, regardless of emission
order. M2 has ONE active window scope and no inter-window chain — the
single-window simplification is that the begin JUMP is patched to point
RIGHT AFTER ITSELF (`new_dst = jump_off + CMD_JUMP_SIZE`). This makes the
JUMP a STRUCTURAL NO-OP: the renderer walker hits the JUMP, follows it
forward by exactly one command size, lands on the next command (the body
bg `CMD_RECT`), and draws every command inside the window normally.

The point of emitting the JUMP at all in M2 is forward compatibility —
M3 will wire a proper container z-order chain that threads JUMPs linearly
so the renderer walks roots in z-order. With the M2 no-op semantic in
place, the bytes are already in the right shape — M3 swaps the
`patch_jump` destination from the self-skip to "start of the next root's
draws" without any emit-side changes.

Caller invariant (M2 and M3): walkers MUST advance by the JUMP's
`dst_offset` (microui pattern), not blindly by `size_at` across CMD_JUMP
— following the dst is equivalent to walking past for the M2 self-skip
but the only correct strategy once M3's chain points past the window.

### What this chunk deliberately does NOT do (deferred to M3+)

  * NO inter-window z-order chain (single active window only).
  * NO close button (the `"!close"` sub-widget per microui).
  * NO collapsed / "rolled-up" state.
  * NO resize handle in the bottom-right corner.
  * NO docking / snapping.
  * NO click-to-raise window stack management.
  * NO scrollbars on the body (caller can wrap a `scroll_area` inside).
  * NO popup / modal helpers (will reuse the JUMP primitive when wired).

### `.copy()` discipline

`Rect`/`Color`/`Vec2`/`DefaultTheme` are `Copyable, Movable` but NOT
`ImplicitlyCopyable` (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable").
Every READ of a field-typed value to pass into another call needs an
explicit `.copy()`. `Float32`/`Int32`/`Bool` ARE `ImplicitlyCopyable` so
the `rect.x`/`rect.y` mutations and the `jump_off` Int32 need no `.copy()`.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import CMD_JUMP_SIZE
from mojoui.core.control import CTRL_ACTIVE, OPT_NONE


# `comptime` (not `alias`) per current beta — see Mojo implementation notes.

comptime _TITLE_BAR_H: Float32 = 24.0
"""Title bar height (px). Matches `layout.DEFAULT_ROW_PX` so a single-row
title block fits a body row."""

comptime _BORDER_PX: Float32 = 1.0
"""Window border thickness (px). Matches `basic._draw_border` thickness."""


# ============================================================================
# begin_window / end_window
# ============================================================================


def begin_window(
    mut ctx: Context, id_str: String, title: String, mut rect: Rect
) -> Bool:
    """Begin a draggable window of bounds `rect`. Returns True if open
    (always True in M2 — collapse/close come in M3).

    Caller emits content widgets between `begin_window` and `end_window`.
    Children automatically layout INSIDE the body rect (window rect minus
    title bar minus padding) because `begin_window` pushes an inner
    layout frame at the body rect.

    Drag-to-move: while the user holds the mouse on the title bar
    (CTRL_ACTIVE on the title's id), `rect.x`/`rect.y` are advanced by
    the frame's `mouse_delta.x`/`mouse_delta.y`. Because `rect` is a
    `mut` parameter, the caller's binding moves with it — the next frame
    redraws the window at the new position. NO clamping to window bounds.

    JUMP semantics (M2): emits a CMD_JUMP placeholder that `end_window`
    patches to the no-op self-skip — see module docstring.

    Caller contract: title text only renders when `ctx.theme.font_id != 0`
    (call `ctx.set_default_font(<id>)` before the frame — same convention
    as `basic.button` / `basic.label`; FRAGILE #5 rationale).
    """
    # 1. push id_str on the id_stack so child widgets inside this window
    #    derive IDs UNDER it (contextual hashing per microui).
    ctx.push_id_str(id_str)

    # 2. emit CMD_JUMP placeholder. A window has its OWN absolute rect
    #    so we do NOT call `layout_next`. The dst is patched at
    #    `end_window`; in M2 to the no-op self-skip. Record the offset in
    #    the reserved Context slot — M2 supports one active window scope.
    var jump_off = ctx.commands.emit_jump(-1)
    ctx._container_jump_offset = jump_off

    # 3. title bar — top `_TITLE_BAR_H` px of the rect. Used both as the
    #    drag handle (`update_control` on title id) and the visible bar.
    var title_bar = Rect(rect.x, rect.y, rect.w, _TITLE_BAR_H)

    # 4. update_control on the title bar — drives drag.
    var title_id = ctx.get_id(String("!title"))
    var flags = ctx.update_control(title_id, title_bar.copy(), OPT_NONE)

    # 5. drag — while title bar is CTRL_ACTIVE, advance the window rect by
    #    this frame's mouse_delta. Float32 is ImplicitlyCopyable so no
    #    `.copy()` needed on the deltas.
    if (flags & CTRL_ACTIVE) != 0:
        rect.x = rect.x + ctx.input.mouse_delta.x
        rect.y = rect.y + ctx.input.mouse_delta.y
        # Recompute title bar at new position so this frame's draws reflect
        # the motion immediately.
        title_bar = Rect(rect.x, rect.y, rect.w, _TITLE_BAR_H)

    # 6. draw: body bg (full window rect — title bar paints on top),
    #    title bar bg, border, title text.
    ctx.draw_rect(rect.copy(), ctx.theme.bg.copy())
    ctx.draw_rect(title_bar.copy(), ctx.theme.primary.copy())

    # Border — primary color when active (dragging), neutral otherwise.
    var border_color: Color
    if (flags & CTRL_ACTIVE) != 0:
        border_color = ctx.theme.primary.copy()
    else:
        border_color = ctx.theme.border.copy()
    _draw_border(ctx, rect.copy(), border_color^, _BORDER_PX)

    # Title text — same baseline / padding convention as button / label.
    # Skipped when no font is loaded (FRAGILE #5).
    if ctx.theme.font_id != 0:
        var title_pos = Vec2(
            title_bar.x + Float32(ctx.theme.padding),
            title_bar.y
            + (title_bar.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            title_pos^,
            ctx.theme.text.copy(),
            title,
        )

    # 7. push inner layout frame at the body rect (inset by padding on
    #    x/right and bottom; top is inset by title bar + padding). Child
    #    widgets between begin / end flow inside this frame.
    var pad = Float32(ctx.theme.padding)
    var body = Rect(
        rect.x + pad,
        rect.y + _TITLE_BAR_H + pad,
        rect.w - pad * 2.0,
        rect.h - _TITLE_BAR_H - pad * 2.0,
    )
    ctx.layout.push(body^)

    # 8. return — M2 always open; M3 returns False when collapsed/closed.
    return True


def end_window(mut ctx: Context):
    """End the matching `begin_window`: pop the inner layout frame, patch
    the begin-emitted CMD_JUMP, reset the reserved Context slot, pop the
    id_stack entry.

    JUMP patch (M2 single-window simplification): patched to point right
    after itself (`jump_off + CMD_JUMP_SIZE`) — a no-op self-skip that
    lets the renderer walker draw every command inside the window
    normally. M3 will swap this for proper inter-window z-order chaining
    without changing call sites.

    Caller invariant: every `begin_window` MUST be matched by exactly one
    `end_window`. Mismatched pairs leak a layout frame, which
    `Context.end_frame` reports via one-line warning + auto-pop.
    """
    # Pop the inner layout frame pushed by begin_window step 7.
    ctx.layout.pop()

    # Patch the JUMP. M2: no-op self-skip. `patch_jump` asserts the offset
    # is a CMD_JUMP (per commands.mojo FRAGILE #1 bug-guard).
    var jump_off = ctx._container_jump_offset
    if jump_off >= 0:
        ctx.commands.patch_jump(jump_off, jump_off + CMD_JUMP_SIZE)

    # Reset slot so a subsequent begin_window in the same frame gets a
    # fresh slot (M2 supports one active window scope at a time).
    ctx._container_jump_offset = -1

    # Pop the id pushed by begin_window step 1.
    ctx.pop_id()


# ============================================================================
# Internal helpers
# ============================================================================


def _draw_border(
    mut ctx: Context, rect: Rect, color: Color, thickness: Float32
):
    """Draw a rectangular outline as 4 thin filled rects. Same pattern as
    `basic._draw_border` — kept private to this module (Mojo has no
    module-private cross-file imports without exposing a public symbol).
    Real AA outline + miter joins land with the M3 tessellator.
    """
    # Top edge.
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    # Bottom edge.
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    # Left edge (avoid double-painting corners).
    ctx.draw_rect(
        Rect(
            rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness
        ),
        color.copy(),
    )
    # Right edge.
    ctx.draw_rect(
        Rect(
            rect.x + rect.w - thickness,
            rect.y + thickness,
            thickness,
            rect.h - 2.0 * thickness,
        ),
        color.copy(),
    )
