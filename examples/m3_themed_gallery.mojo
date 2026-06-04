"""MojoUI M3 capstone — themed gallery showcase.

Static three-frame walk-through of the new M3 visual stack: themes
(dark / light / high_contrast) cycled in one binary, tessellator (AA rounded
rects + drop shadows + circles), animation (ease_out_cubic lerp swatches +
spring_step trace), typography (Inter / fallback via load_default_ui_font).

Per-theme: 800x600 frame with bg_default fill, title (text_strong/24pt) +
subtitle (text_subdued/14pt), AA card with drop shadow (bg_panel + 12px
radius), accent-fill button card (accent_default + text_on_accent), status
circle (alert_success_fill via tess_circle), 4-frame easing swatch row
(accent_default -> bg_surface lerp via ease_out_cubic), and a spring_step
R-channel trace printed at frames 0/6/18/36/60.

Per-theme stats printed: name, command byte count, sample token RGB triples
(accent_default, text_strong, bg_panel).

Runtime visual gate (real window + theme-switcher button) DEFERRED — GPU
busy + module-level frame-callback state still unresolved per Mojo implementation notes.
Static gate exercises every M3 surface in one binary without opening a
window.

Run via: pixi run themed
"""

from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.theme.tokens import Theme
from mojoui.theme.themes import dark_theme, light_theme, high_contrast_theme
from mojoui.theme.typography import load_default_ui_font
from mojoui.animation.spring import (
    spring_step,
    lerp_f32,
    ease_out_cubic,
)
from mojoui.render.tessellator import (
    tess_rounded_rect,
    tess_drop_shadow,
    tess_circle,
)


# Per-theme single-frame emit. We thread the M3 Theme manually (ctx.theme is
# still the legacy DefaultTheme — c47 wires M3 Theme into Context separately).
# All color reads go through theme.colors.*; only ctx.theme.font_id is set
# via set_default_font.


def _demo_theme(mut ctx: Context, theme: Theme, font_id: UInt32) raises -> Int:
    """Emit one themed frame. Returns the resulting command byte count."""
    ctx.set_default_font(font_id)

    ctx.begin_frame_no_input(
        Vec2(800.0, 600.0), Vec2(0.0, 0.0), False, False,
    )

    # ----- Background fill (driven by token bg_default) ----------------------
    ctx.draw_rect(
        Rect(0.0, 0.0, 800.0, 600.0),
        theme.colors.bg_default.copy(),
    )

    # ----- Title + subtitle text -------------------------------------------
    if font_id != 0:
        ctx.draw_text(
            font_id, Int32(24),
            Vec2(40.0, 60.0),
            theme.colors.text_strong.copy(),
            String("MojoUI M3 -- ") + theme.name,
        )
        ctx.draw_text(
            font_id, Int32(14),
            Vec2(40.0, 90.0),
            theme.colors.text_subdued.copy(),
            String("themed gallery: tessellator + animation + design tokens"),
        )

    # ----- AA card with drop shadow ----------------------------------------
    # Shadow first (so the card paints on top), then the rounded panel.
    # tess_* now route through ctx.commands (M3 c46-fix Bug 2) — the demo
    # exits before the runtime walker fires, so the records sit unused, but
    # the call shape matches the post-fix signature.
    var card_rect = Rect(40.0, 140.0, 320.0, 180.0)
    tess_drop_shadow(
        ctx,
        card_rect.copy(), Float32(12.0), Float32(6.0),
        Float32(0.0), Float32(4.0),
        Color(0, 0, 0, 80),
    )
    tess_rounded_rect(
        ctx,
        card_rect.copy(), Float32(12.0),
        theme.colors.bg_panel.copy(), 8,
    )
    if font_id != 0:
        ctx.draw_text(
            font_id, Int32(16),
            Vec2(card_rect.x + 16.0, card_rect.y + 32.0),
            theme.colors.text_default.copy(),
            String("Surface with AA + shadow"),
        )
        ctx.draw_text(
            font_id, Int32(13),
            Vec2(card_rect.x + 16.0, card_rect.y + 60.0),
            theme.colors.text_subdued.copy(),
            String("rounded corners via tess_rounded_rect"),
        )

    # ----- Accent-fill button-like card ------------------------------------
    var btn_rect = Rect(400.0, 140.0, 240.0, 56.0)
    tess_drop_shadow(
        ctx,
        btn_rect.copy(), Float32(8.0), Float32(4.0),
        Float32(0.0), Float32(2.0),
        Color(0, 0, 0, 100),
    )
    tess_rounded_rect(
        ctx,
        btn_rect.copy(), Float32(8.0),
        theme.colors.accent_default.copy(), 6,
    )
    if font_id != 0:
        ctx.draw_text(
            font_id, Int32(14),
            Vec2(btn_rect.x + 16.0, btn_rect.y + 32.0),
            theme.colors.text_on_accent.copy(),
            String("Click me (accent)"),
        )

    # ----- Circle status indicator -----------------------------------------
    tess_circle(
        ctx,
        Vec2(700.0, 168.0), Float32(18.0),
        theme.colors.alert_success_fill.copy(), 24,
    )
    if font_id != 0:
        ctx.draw_text(
            font_id, Int32(11),
            Vec2(675.0, 210.0),
            theme.colors.text_subdued.copy(),
            String("status"),
        )

    # ----- Animation row: ease_out_cubic lerp accent -> bg_surface ---------
    # 4 swatches at t = {0, 1/3, 2/3, 1} through ease_out_cubic.
    var anim_y: Float32 = 380.0
    var a_def = theme.colors.accent_default.copy()
    var b_sur = theme.colors.bg_surface.copy()
    for step in range(4):
        var t_raw = Float32(step) / Float32(3.0)
        var t = ease_out_cubic(t_raw)
        var lerped = Color(
            UInt8(Int(lerp_f32(Float32(Int(a_def.r)), Float32(Int(b_sur.r)), t))),
            UInt8(Int(lerp_f32(Float32(Int(a_def.g)), Float32(Int(b_sur.g)), t))),
            UInt8(Int(lerp_f32(Float32(Int(a_def.b)), Float32(Int(b_sur.b)), t))),
            UInt8(255),
        )
        var swatch_rect = Rect(
            40.0 + Float32(step) * 70.0, anim_y, 60.0, 60.0,
        )
        tess_rounded_rect(ctx, swatch_rect.copy(), Float32(8.0), lerped, 6)

    if font_id != 0:
        ctx.draw_text(
            font_id, Int32(13),
            Vec2(40.0, anim_y + 78.0),
            theme.colors.text_subdued.copy(),
            String("animation: ease_out_cubic accent_default -> bg_surface (4 frames)"),
        )

    ctx.end_frame()
    return ctx.commands.byte_count()


# Spring trace helper — 5-sample print of spring_step on the R channel as the
# value settles from accent_default.r toward bg_surface.r. Demonstrates the
# animation kernel composes against the same tokens as the static swatches.


def _spring_trace(theme: Theme):
    """Print snapshots of a spring_step integration on the R channel."""
    var start_r = Float32(Int(theme.colors.accent_default.r))
    var target_r = Float32(Int(theme.colors.bg_surface.r))
    var cur = start_r
    var vel: Float32 = 0.0
    var dt: Float32 = Float32(1.0) / Float32(60.0)

    # Print snapshots at frames 0, 6, 18, 36, 60 to show the settling curve.
    var snap_frames = List[Int]()
    snap_frames.append(0)
    snap_frames.append(6)
    snap_frames.append(18)
    snap_frames.append(36)
    snap_frames.append(60)

    print("  spring_step R-channel trace (start=", start_r, "target=", target_r, "):")
    var snap_i = 0
    for f in range(61):
        if snap_i < len(snap_frames) and f == snap_frames[snap_i]:
            print("    frame", f, ": value=", cur, "velocity=", vel)
            snap_i = snap_i + 1
        var res = spring_step(cur, target_r, vel, dt)
        cur = res.value
        vel = res.velocity


# main: load the font once, cycle each theme, print stats + PASS.


def main() raises:
    """Build the M3 themed scene across three themes; print stats + PASS."""
    var ctx = Context()
    var font_id = load_default_ui_font()
    print("Loaded default UI font id =", font_id, "(0 = no font; text draws skipped)")

    # Build the theme set. Theme is Copyable-not-ImplicitlyCopyable so
    # downstream reads need `.copy()` (per Mojo implementation notes c15 wall).
    var themes = List[Theme]()
    themes.append(dark_theme())
    themes.append(light_theme())
    themes.append(high_contrast_theme())

    var theme_count = len(themes)
    var total_bytes = 0
    for ti in range(theme_count):
        var theme = themes[ti].copy()
        var n_bytes = _demo_theme(ctx, theme, font_id)
        total_bytes = total_bytes + n_bytes
        print("Theme:", theme.name, "-- emitted", n_bytes, "bytes of commands")
        print(
            "  accent_default RGB:",
            Int(theme.colors.accent_default.r),
            Int(theme.colors.accent_default.g),
            Int(theme.colors.accent_default.b),
        )
        print(
            "  text_strong RGB:   ",
            Int(theme.colors.text_strong.r),
            Int(theme.colors.text_strong.g),
            Int(theme.colors.text_strong.b),
        )
        print(
            "  bg_panel RGB:      ",
            Int(theme.colors.bg_panel.r),
            Int(theme.colors.bg_panel.g),
            Int(theme.colors.bg_panel.b),
        )
        _spring_trace(theme)

        # Gate: every theme MUST emit at least one rect (background fill).
        if n_bytes <= 0:
            print("FAIL: theme", theme.name, "emitted zero command bytes")
            raise Error("empty command buffer for theme")

    print("Total command bytes across", theme_count, "themes:", total_bytes)
    print("PASS: M3 capstone -- themed gallery composes across 3 themes")
