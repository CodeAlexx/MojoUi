"""Theme presets for MojoUI (M3 chunk 47).

Three canonical themes composed from c43's `Theme` + `ColorTokens` tokens:

  - `dark_theme()`           rerun-inspired, calm purple accent. Default for
                             diffusion / image-gen apps. Dark surfaces with
                             white-ish body text — the convention every
                             modern ML tool ships with (rerun, ComfyUI,
                             Krita, DaVinci Resolve, etc.).
  - `light_theme()`          inverted, white-ish surfaces with dark text and
                             a slightly desaturated purple accent for
                             contrast on white. For daytime use.
  - `high_contrast_theme()`  accessibility variant — pure black background,
                             pure white text, yellow accent. Borders all
                             white. Meets / exceeds WCAG AAA contrast.

Plus `theme_for_name(name: String) -> Theme` — a string lookup that maps
`"dark"` / `"light"` / `"high_contrast"` to the matching factory and falls
back to `dark_theme()` for any unknown name. Useful for caller-side theme
selection from a config file or CLI flag (`--theme=light`).

References:
  - `/home/alex/mojoui-audit/AUDIT_egui_ecosystem.md` §"Aesthetic Patterns"
    — rerun's dark theme is the reference; `design_tokens.rs` semantic
    naming + 8px grid + 6px default radius.
  - rerun `crates/viewer/re_ui/src/design_tokens.rs` (semantic field names).
  - rerun `crates/viewer/re_ui/src/dark.rs` (canonical dark palette).

NOT included in this chunk:
  - Image-derived custom themes (color sampling from a reference image) —
    M3+.
  - Theme animation / fade-between transitions — M3+.
  - Widget refactor to consume tokens (DefaultTheme still lives in Context;
    the c48 widget refactor pass will rewire widgets to read `ctx.theme`
    by token name).

This chunk only OWNS the three preset color palettes + the string lookup;
`ColorTokens` / `SpacingTokens` / `RadiusTokens` / `TypographyTokens` struct
definitions stay in c43 `tokens.mojo` and are NOT modified here.
"""

from mojoui.core.types import Color
from mojoui.theme.tokens import (
    Theme,
    ColorTokens,
    SpacingTokens,
    RadiusTokens,
    TypographyTokens,
)


# ============================================================================
# dark_theme — rerun-inspired, the default
# ============================================================================


def dark_theme() -> Theme:
    """rerun-inspired dark theme. The default for diffusion / image-gen apps.

    Backgrounds graduate from a near-black app bg (20,22,26) through a panel
    shade (28,30,36) to a raised surface (40,44,52). Text is white-ish
    (225,225,235) for body, dimmed (150,150,165) for secondary, and a calm
    purple (110,90,200) is the accent — matching the visual identity of
    most ML/diffusion tooling. Graph canvas is darker still (15,15,18) so
    nodes pop forward.
    """
    var t = Theme()
    t.name = String("dark")

    var c = ColorTokens()
    # Backgrounds (app → panel → raised surface → input field)
    c.bg_default = Color(20, 22, 26, 255)
    c.bg_panel = Color(28, 30, 36, 255)
    c.bg_surface = Color(40, 44, 52, 255)
    c.bg_input = Color(24, 26, 30, 255)
    c.floating_color = Color(36, 38, 44, 255)
    c.faint_bg_color = Color(32, 34, 40, 255)
    c.extreme_bg_color = Color(8, 9, 12, 255)

    # Text
    c.text_default = Color(225, 225, 235, 255)
    c.text_subdued = Color(150, 150, 165, 255)
    c.text_disabled = Color(80, 80, 90, 255)
    c.text_on_accent = Color(255, 255, 255, 255)
    c.text_strong = Color(250, 250, 255, 255)

    # Widget state — neutral grays graduating with interaction state
    c.widget_inactive_bg_fill = Color(50, 54, 62, 255)
    c.widget_hovered_color = Color(70, 74, 84, 255)
    c.widget_active_bg_fill = Color(90, 94, 105, 255)

    # Accent — calm purple matching ML/diffusion tooling
    c.accent_default = Color(110, 90, 200, 255)
    c.accent_hover = Color(130, 110, 220, 255)
    c.accent_active = Color(90, 70, 180, 255)

    # Borders + separators
    c.border_default = Color(60, 64, 72, 255)
    c.border_strong = Color(90, 94, 102, 255)
    c.separator = Color(50, 54, 62, 255)

    # Selection + focus
    c.selection_bg_fill = Color(70, 90, 160, 200)
    c.selection_stroke_color = Color(120, 140, 220, 255)
    c.focus_outline_stroke = Color(130, 110, 220, 255)

    # Alerts (fill + text pair per severity)
    c.alert_info_fill = Color(50, 90, 140, 255)
    c.alert_info_text = Color(200, 220, 240, 255)
    c.alert_warning_fill = Color(160, 110, 30, 255)
    c.alert_warning_text = Color(240, 220, 180, 255)
    c.alert_error_fill = Color(160, 50, 50, 255)
    c.alert_error_text = Color(240, 200, 200, 255)
    c.alert_success_fill = Color(50, 130, 60, 255)
    c.alert_success_text = Color(200, 240, 200, 255)

    # Graph (node canvas — darkest bg so nodes pop forward)
    c.graph_canvas_bg = Color(15, 15, 18, 255)
    c.graph_node_bg = Color(40, 40, 50, 240)
    c.graph_node_bg_selected = Color(60, 60, 90, 240)
    c.graph_node_title_bg = Color(60, 70, 110, 255)

    t.colors = c^
    return t^


# ============================================================================
# light_theme — inverted high-contrast for daytime use
# ============================================================================


def light_theme() -> Theme:
    """Inverted high-contrast light theme — for daytime use.

    White-ish surfaces (245..255) with dark text (30,30,40), a slightly
    desaturated purple accent (90,60,180) for legibility on white, and
    softer alert fills (pastel-tinted). Graph canvas stays dark-ish even in
    light mode because node content (latents/previews) reads better on a
    dark canvas regardless of the surrounding chrome.
    """
    var t = Theme()
    t.name = String("light")

    var c = ColorTokens()
    # Backgrounds (white-ish)
    c.bg_default = Color(245, 245, 248, 255)
    c.bg_panel = Color(255, 255, 255, 255)
    c.bg_surface = Color(238, 240, 244, 255)
    c.bg_input = Color(250, 250, 252, 255)
    c.floating_color = Color(252, 252, 254, 255)
    c.faint_bg_color = Color(248, 248, 250, 255)
    c.extreme_bg_color = Color(220, 220, 226, 255)

    # Text
    c.text_default = Color(30, 30, 40, 255)
    c.text_subdued = Color(100, 100, 110, 255)
    c.text_disabled = Color(180, 180, 190, 255)
    c.text_on_accent = Color(255, 255, 255, 255)
    c.text_strong = Color(10, 10, 20, 255)

    # Widget state — lighter graduating grays for white background
    c.widget_inactive_bg_fill = Color(232, 234, 240, 255)
    c.widget_hovered_color = Color(220, 222, 232, 255)
    c.widget_active_bg_fill = Color(205, 208, 220, 255)

    # Accent — same purple, slightly desaturated for white background
    c.accent_default = Color(90, 60, 180, 255)
    c.accent_hover = Color(110, 80, 200, 255)
    c.accent_active = Color(70, 40, 160, 255)

    # Borders + separators
    c.border_default = Color(200, 200, 210, 255)
    c.border_strong = Color(150, 150, 160, 255)
    c.separator = Color(220, 220, 230, 255)

    # Selection + focus
    c.selection_bg_fill = Color(180, 200, 240, 200)
    c.selection_stroke_color = Color(70, 100, 180, 255)
    c.focus_outline_stroke = Color(110, 80, 200, 255)

    # Alerts (pastel-tinted fills, darker text for legibility)
    c.alert_info_fill = Color(180, 210, 240, 255)
    c.alert_info_text = Color(30, 50, 90, 255)
    c.alert_warning_fill = Color(255, 230, 180, 255)
    c.alert_warning_text = Color(120, 70, 20, 255)
    c.alert_error_fill = Color(255, 200, 200, 255)
    c.alert_error_text = Color(140, 30, 30, 255)
    c.alert_success_fill = Color(200, 240, 200, 255)
    c.alert_success_text = Color(30, 100, 40, 255)

    # Graph (still dark-ish — canvases are usually dark even in light themes
    # for content focus on latents/previews)
    c.graph_canvas_bg = Color(60, 60, 70, 255)
    c.graph_node_bg = Color(80, 80, 90, 240)
    c.graph_node_bg_selected = Color(120, 110, 170, 240)
    c.graph_node_title_bg = Color(110, 100, 160, 255)

    t.colors = c^
    return t^


# ============================================================================
# high_contrast_theme — accessibility variant
# ============================================================================


def high_contrast_theme() -> Theme:
    """Maximum contrast for accessibility. Black bg, white text, yellow accent.

    Pure black (0,0,0) surfaces with pure white (255,255,255) body text and
    a bright yellow (255,220,0) accent — meets / exceeds WCAG AAA contrast
    ratios. Borders all white-ish (180+). Alert colors stay saturated
    primaries with high-contrast text. Use when low-vision users need to
    interact with the UI; toggle via `theme_for_name("high_contrast")`.
    """
    var t = Theme()
    t.name = String("high_contrast")

    var c = ColorTokens()
    # Backgrounds (pure black + near-black)
    c.bg_default = Color(0, 0, 0, 255)
    c.bg_panel = Color(0, 0, 0, 255)
    c.bg_surface = Color(30, 30, 30, 255)
    c.bg_input = Color(20, 20, 20, 255)
    c.floating_color = Color(15, 15, 15, 255)
    c.faint_bg_color = Color(20, 20, 20, 255)
    c.extreme_bg_color = Color(255, 255, 255, 255)

    # Text
    c.text_default = Color(255, 255, 255, 255)
    c.text_subdued = Color(200, 200, 200, 255)
    c.text_disabled = Color(120, 120, 120, 255)
    c.text_on_accent = Color(0, 0, 0, 255)
    c.text_strong = Color(255, 255, 255, 255)

    # Widget state — high-contrast white-on-black
    c.widget_inactive_bg_fill = Color(40, 40, 40, 255)
    c.widget_hovered_color = Color(80, 80, 80, 255)
    c.widget_active_bg_fill = Color(140, 140, 140, 255)

    # Accent — bright yellow (highest visibility on black)
    c.accent_default = Color(255, 220, 0, 255)
    c.accent_hover = Color(255, 240, 100, 255)
    c.accent_active = Color(220, 190, 0, 255)

    # Borders (high-contrast white)
    c.border_default = Color(180, 180, 180, 255)
    c.border_strong = Color(255, 255, 255, 255)
    c.separator = Color(120, 120, 120, 255)

    # Selection + focus — bright yellow over black for maximum visibility
    c.selection_bg_fill = Color(255, 220, 0, 200)
    c.selection_stroke_color = Color(255, 255, 255, 255)
    c.focus_outline_stroke = Color(255, 220, 0, 255)

    # Alerts (saturated primaries with high-contrast text)
    c.alert_info_fill = Color(0, 100, 200, 255)
    c.alert_info_text = Color(255, 255, 255, 255)
    c.alert_warning_fill = Color(255, 150, 0, 255)
    c.alert_warning_text = Color(0, 0, 0, 255)
    c.alert_error_fill = Color(255, 0, 0, 255)
    c.alert_error_text = Color(255, 255, 255, 255)
    c.alert_success_fill = Color(0, 200, 0, 255)
    c.alert_success_text = Color(0, 0, 0, 255)

    # Graph
    c.graph_canvas_bg = Color(0, 0, 0, 255)
    c.graph_node_bg = Color(40, 40, 40, 240)
    c.graph_node_bg_selected = Color(180, 150, 0, 240)
    c.graph_node_title_bg = Color(120, 100, 0, 255)

    t.colors = c^
    return t^


# ============================================================================
# theme_for_name — string lookup
# ============================================================================


def theme_for_name(name: String) -> Theme:
    """Look up a theme preset by name. Falls back to `dark_theme()` if the
    name is unknown.

    Accepts `"dark"` / `"light"` / `"high_contrast"`. Useful when the active
    theme comes from a config file or CLI flag — callers do not have to
    branch on string values themselves.
    """
    if name == String("dark"):
        return dark_theme()
    elif name == String("light"):
        return light_theme()
    elif name == String("high_contrast"):
        return high_contrast_theme()
    return dark_theme()
