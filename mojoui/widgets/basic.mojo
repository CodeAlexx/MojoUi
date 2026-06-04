"""Basic widgets — button, label, separator.

Per M1 chunk 17 these were stub implementations using axis-aligned `draw_rect`
calls. **M3 chunk 51 upgrades `button()`** to consume the M3 visual stack:

  * Background fill via `tess_rounded_rect` (6 px corner radius — matches
    `RadiusTokens` per `mojoui/theme/tokens.mojo`).
  * Raised drop shadow via `tess_drop_shadow` (only when not pressed; gives
    the pressed-into-the-surface feel without computing an inset offset).
  * State-dependent colours via the `_resolve_button_bg` bridge helper that
    maps CTRL_* state flags to colours pulled from `ctx.theme` (currently
    `DefaultTheme` — see "Bridge note" below).

`label` and `separator` are unchanged from M1 — they emit pure axis-aligned
`draw_rect`/`draw_text` and are widget-isolation-private to the M1 visual
contract.

### Bridge note (M3 c51 → eventual c48 Theme migration)

`ctx.theme` is currently `DefaultTheme` (the M1 minimal placeholder struct
from `mojoui/core/context.mojo`). The full `Theme` token migration is the
deferred c48 chunk. For c51 we keep API back-compat by mapping
`DefaultTheme.primary` / `hover_bg` / `active_bg` / `border` to the semantic
names the new visuals would name (`accent_default` / `widget_hovered_color`
/ `widget_active_bg_fill` / `focus_outline_stroke`). The `_resolve_button_bg`
helper is the SINGLE POINT where this bridge lives; c48 will swap it for a
direct read of `ctx.theme.colors.widget_inactive_bg_fill` etc. once Context
holds a real `Theme`.

### M3 c46-fix Bug 2 (2026-05-28) — tessellator routes through ctx.commands

Before the fix, `tess_rounded_rect` / `tess_drop_shadow` called
`Backend.draw_batch_lists` directly, bypassing `ctx.commands` entirely. The
demo walker only iterated `ctx.commands`, so widget geometry was rendered
immediately to the GPU during widget evaluation, BEFORE
`Backend.frame_begin` cleared the backbuffer. Result: invisible buttons.

The fix adds `CMD_TRIANGLES` to `mojoui/core/commands.mojo`; tessellator
functions now emit `CMD_TRIANGLES` records via `ctx.commands.emit_triangles`
and the demo walker dispatches CMD_TRIANGLES -> `Backend.draw_batch_lists`.
Widgets never call Backend; only the renderer adapter does.

A side benefit: the c51 runtime-False JIT guard `var _never = Int(
MOJOUI_KEY_COUNT) - 96; if _never != 0:` is no longer needed in the widget
body — the tess_* calls reach no FFI symbol from inside the widget, so
`mojo run` cannot eagerly materialise `mojoui_draw_batch`. The guard was
removed in the M3 c46-fix.

Each widget follows the microui 6-step recipe (per
`internal audit notes` "Widget Pattern"):

    1. id     = ctx.get_id(label)
    2. rect   = ctx.layout_next()
    3. flags  = ctx.update_control(id, rect, OPT_*)
    4. behavior — any extra reactions to the flags (button has none, slider
                   would convert mouse-drag to value, etc.)
    5. draw   — emit rect + text/icon via ctx.draw_rect / draw_text (or via
                tessellator for AA primitives in the c51 button)
    6. return — surface the click event (Bool for button) or new value
                 (Float32 for slider) etc.

The `.copy()` discipline (per Mojo implementation notes "Copyable ≠ ImplicitlyCopyable"):
`Color`, `Rect`, `Vec2`, `DefaultTheme` are all `Copyable, Movable` but NOT
`ImplicitlyCopyable`. Every READ of a field-typed value to pass it to another
function call needs an explicit `.copy()` — passing the same `rect` to two
`ctx.draw_rect` calls in a row would fail "value cannot be implicitly copied".
The skeleton below threads `.copy()` everywhere required.
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.id import ImmediateId
from mojoui.core.context import Context
from mojoui.core.control import (
    CTRL_HOVERED,
    CTRL_FOCUSED,
    CTRL_ACTIVE,
    CTRL_PRESSED,
    CTRL_RELEASED,
    OPT_NONE,
    OPT_FOCUSABLE,
)
from mojoui.render.tessellator import tess_rounded_rect, tess_drop_shadow


# ============================================================================
# c51 — M3 visual constants (button)
# ============================================================================
#
# Per M3 `RadiusTokens` (mojoui/theme/tokens.mojo) the default widget
# corner radius is 6 px — same value rerun uses for its base button corner
# radius. Hardcoded here pending the c48 Context→Theme migration that lets
# `button()` read `ctx.theme.radius.md` directly.

comptime _BUTTON_RADIUS: Float32 = 6.0

# Drop-shadow geometry: 4-px blur (= 4 concentric layers under
# `tess_drop_shadow`'s blur-as-layer-count semantic), offset 2 px down for
# a CSS-style subtle below-element shadow, semi-transparent black tint.
comptime _BUTTON_SHADOW_BLUR: Float32 = 4.0
comptime _BUTTON_SHADOW_OFFSET_X: Float32 = 0.0
comptime _BUTTON_SHADOW_OFFSET_Y: Float32 = 2.0
comptime _BUTTON_SHADOW_ALPHA: UInt8 = 100  # ~0.39 alpha


def _resolve_button_bg(ctx: Context, state_flags: Int32) -> Color:
    """Map CTRL_* state flags to a button background `Color` via the active
    `ctx.theme` (currently `DefaultTheme`).

    Bridge per the module-level "Bridge note": `DefaultTheme.primary` plays
    the role of c43 `ColorTokens.widget_inactive_bg_fill` (idle), `hover_bg`
    plays `widget_hovered_color` (hover), `active_bg` plays
    `widget_active_bg_fill` (pressed). The deferred c48 chunk will swap the
    body of this helper to read `ctx.theme.colors.widget_*` directly once
    Context holds a full `Theme`.

    Precedence ACTIVE > HOVERED > idle matches the M1 stub button — once a
    press claims the active slot the button stays in the "active" paint
    until release, even if the cursor drags off the rect.
    """
    if (state_flags & CTRL_ACTIVE) != 0:
        return ctx.theme.active_bg.copy()
    elif (state_flags & CTRL_HOVERED) != 0:
        return ctx.theme.hover_bg.copy()
    return ctx.theme.primary.copy()


def _readable_text_on_fill(fill: Color) -> Color:
    var yiq = Int(fill.r) * 299 + Int(fill.g) * 587 + Int(fill.b) * 114
    if yiq >= 150000:
        return Color(20, 20, 24, 255)
    return Color(245, 245, 250, 255)


# ============================================================================
# button — the canonical 6-step widget
# ============================================================================


def button(mut ctx: Context, label: String) -> Bool:
    """M3-visual button widget. Returns True on the frame the user RELEASES
    the mouse over it (CTRL_RELEASED — release-while-active-and-still-over,
    the microui "click" semantic; press-and-drag-off does NOT click).

    API back-compat: signature `(mut ctx: Context, label: String) -> Bool`
    matches the c17 M1 stub exactly. Only the visuals changed in c51.

    Visual stack (c51):
      * Drop shadow (raised effect) — `tess_drop_shadow` with 4 px blur and
        a 2 px below offset, omitted when the button is pressed (matches
        the "pressed into the surface" CSS convention).
      * Background body — `tess_rounded_rect` with the 6 px (M3 token
        radius.md) corner radius, fill colour resolved by
        `_resolve_button_bg` from `ctx.theme` state.
      * Focus ring — DEFERRED to c52 (focus tab-cycling). c51 omits the
        ring entirely; the body's state colour already differentiates
        focused-via-active from idle. See "Bridge note" in the module
        docstring for the deferral rationale.
      * Label text — same `ctx.draw_text` path as the M1 stub; baseline-y
        rough vertical-center calc preserved; `font_id == 0` skip contract
        preserved (FRAGILE #5).

    JIT guard: every `tess_*` call sits inside a runtime-False guard so
    `pixi run test-basic` (JIT) does not need to resolve `mojoui_draw_batch`
    — see the module docstring's "JIT guard" section. The text draw uses
    `ctx.draw_text` which writes into `ctx.commands` (no FFI), so tests
    that assert `ctx.commands.byte_count()` grows after `button(...)`
    continue to pass.

    Caller contract: if you want the label to render, call
    `ctx.set_default_font(<id>)` BEFORE the frame begins. When
    `ctx.theme.font_id == 0` (no font loaded), the text draw is SKIPPED —
    the button background + shadow still render so the click area remains
    visible. See regression notes FRAGILE #5.
    """
    # 1. id — derive an ImmediateId from the label string (under current
    #    id_stack top, so the same label under different parent containers
    #    hashes to a different id — contextual hashing).
    var id = ctx.get_id(label)

    # 2. rect — get the next layout slot from the current frame's row /
    #    column flow. Advances the layout cursor.
    var rect = ctx.layout_next()

    # 3. update_control — run the interaction state machine for this widget.
    #    Returns bit-or of CTRL_* flags reporting hover/focus/active/press/
    #    release this frame. Pass rect by .copy() — we need rect again for
    #    drawing in step 5, and Rect is Copyable-not-ImplicitlyCopyable.
    #    c52: pass OPT_FOCUSABLE so this widget joins the per-frame Tab
    #    focus-cycle list (focus advances to the next/prev focusable on
    #    Tab/Shift-Tab key presses; see core/control.mojo end_frame).
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)

    # 4. behavior — a stub button has no extra reaction; the click event is
    #    surfaced by step 6's return.

    # 5. draw — M3 visual stack (drop shadow + rounded body) gated behind
    #    the JIT guard, plus label text via ctx.draw_text (always emits).
    var bg_color = _resolve_button_bg(ctx, flags)
    var is_pressed = (flags & CTRL_ACTIVE) != 0

    # After M3 c46-fix Bug 2, tess_* functions emit CMD_TRIANGLES records
    # into ctx.commands (no FFI in the call body). The walker dispatches
    # CMD_TRIANGLES to Backend.draw_batch_lists at frame end. The old
    # runtime-False JIT guard from c51 is no longer needed — there is no
    # external_call reachable from the widget body.
    # Drop shadow — only when not pressed (pressed buttons should look
    # flush with the surface, not raised). Shadow is a soft black tint
    # offset down by 2 px; the visual is added BEFORE the body so the
    # body draws over it.
    if not is_pressed:
        var shadow_color = Color(
            UInt8(0), UInt8(0), UInt8(0), _BUTTON_SHADOW_ALPHA
        )
        tess_drop_shadow(
            ctx,
            rect.copy(),
            _BUTTON_RADIUS,
            _BUTTON_SHADOW_BLUR,
            _BUTTON_SHADOW_OFFSET_X,
            _BUTTON_SHADOW_OFFSET_Y,
            shadow_color^,
        )

    # Rounded body — solid fill at the state-resolved colour.
    tess_rounded_rect(ctx, rect.copy(), _BUTTON_RADIUS, bg_color.copy(), 6)

    # Focus ring (c52). When the button holds keyboard focus, paint a thin
    # outline in `theme.primary` so the user can see which widget Tab/Shift-
    # Tab moved focus to. Uses the existing `_draw_border` 4-rect helper
    # (no tessellator → no JIT guard needed; the `draw_rect` path writes
    # into `ctx.commands` directly). A proper stroked-rounded-rect outline
    # via the tessellator will land alongside the c48 widget refactor; for
    # c52 the axis-aligned ring is sufficient to satisfy the M3 gate's
    # keyboard-nav criterion.
    if (flags & CTRL_FOCUSED) != 0:
        _draw_border(ctx, rect.copy(), ctx.theme.primary.copy(), 1.5)

    # Label text — same baseline-y rough vertical-center calc as the M1
    # stub. Goes through ctx.draw_text (writes into ctx.commands; no FFI),
    # so the c15 JIT guard does NOT apply. Skip when font_id == 0 per
    # FRAGILE #5: emitting CMD_TEXT with font_id=0 would corrupt the M3
    # renderer adapter's font-id lookup.
    if ctx.theme.font_id != 0:
        var label_pos = Vec2(
            rect.x + Float32(ctx.theme.padding),
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            label_pos^,
            _readable_text_on_fill(bg_color.copy()),
            label,
        )

    # 6. return — the click event. CTRL_RELEASED is set by update_control
    #    only on the single frame the user releases while still over the
    #    button rect (release-outside is a drag-cancel — no click).
    return (flags & CTRL_RELEASED) != 0


# ============================================================================
# label — display-only text (no interaction)
# ============================================================================


def label(mut ctx: Context, text: String):
    """Display-only text label. No interaction, no return value.

    Reserves a layout slot (so the next widget flows past it correctly) and
    emits a text draw command. Skips `update_control` entirely (semantically
    OPT_NO_INTERACT — but we don't even need to call the SM since we don't
    care about its flags), so a label NEVER claims hover/focus/active even
    when the cursor is over it.

    Caller contract: if you want the text to render, call
    `ctx.set_default_font(<id>)` BEFORE the frame begins. When
    `ctx.theme.font_id == 0` the text draw is SKIPPED (the slot is still
    reserved). See regression notes FRAGILE #5.
    """
    var rect = ctx.layout_next()
    # Skip the text draw when no font is loaded — same rationale as
    # `button` above.
    if ctx.theme.font_id != 0:
        # Same baseline-y calc as button; no padding-x on the left because
        # labels don't have a frame to inset from.
        var pos = Vec2(
            rect.x + Float32(ctx.theme.padding),
            rect.y + (rect.h + Float32(ctx.theme.font_size_pt) * 0.7) * 0.5,
        )
        ctx.draw_text(
            ctx.theme.font_id,
            ctx.theme.font_size_pt,
            pos^,
            ctx.theme.text.copy(),
            text,
        )


# ============================================================================
# separator — horizontal divider line
# ============================================================================


def separator(mut ctx: Context):
    """Horizontal separator line. Reserves a layout slot of normal height
    but paints only a thin horizontal bar at the slot's vertical centre."""
    var rect = ctx.layout_next()
    # 1px tall bar, centred vertically within the slot.
    var bar_h: Float32 = 1.0
    var bar = Rect(rect.x, rect.y + (rect.h - bar_h) * 0.5, rect.w, bar_h)
    ctx.draw_rect(bar^, ctx.theme.border.copy())


# ============================================================================
# Internal helpers
# ============================================================================


def _draw_border(mut ctx: Context, rect: Rect, color: Color, thickness: Float32):
    """Draw a rectangular outline as 4 thin filled rects (top, bottom, left,
    right). Stub — proper outline drawing with AA + miter joins comes with
    the M3 tessellator. The 4-rects-per-border cost is acceptable for M1
    since buttons are rare relative to widget count.

    Color is read 4× via `.copy()` (Color is Copyable-not-ImplicitlyCopyable).
    """
    # Top edge: full width, 1px tall (or `thickness` tall).
    ctx.draw_rect(Rect(rect.x, rect.y, rect.w, thickness), color.copy())
    # Bottom edge.
    ctx.draw_rect(
        Rect(rect.x, rect.y + rect.h - thickness, rect.w, thickness),
        color.copy(),
    )
    # Left edge (between top and bottom — avoid double-painting the corners).
    ctx.draw_rect(
        Rect(rect.x, rect.y + thickness, thickness, rect.h - 2.0 * thickness),
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
