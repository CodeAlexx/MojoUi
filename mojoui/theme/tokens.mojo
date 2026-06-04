"""Design tokens for MojoUI themes (M3 chunk 43).

Mirrors rerun's `design_tokens.rs` pattern: tokens are SEMANTIC (named by
purpose, e.g. `text_subdued`, `alert_warning_fill`) rather than LITERAL
(named by color, e.g. `gray180`). Widgets reference the semantic field;
themes (c44 themes.mojo) supply the actual RGBA. This indirection lets a
single theme switch swap the entire palette without touching widget code.

Four token groups compose into a `Theme`:
  - `ColorTokens` — semantic palette (backgrounds, text, accent, borders,
    alert states, node-graph specifics).
  - `SpacingTokens` — 8px-grid spacing scale (xs/sm/md/lg/xl/xxl).
  - `RadiusTokens` — corner-radius scale (none/sm/md/lg/pill).
  - `TypographyTokens` — type size + weight scale.

Plus a `font_id: UInt32` (returned by `Backend.load_font`; 0 = no font loaded
so widgets skip text per the M1 bugfix font_id contract) and a `name: String`
for theme-switching debug.

Default construction yields a neutral dark palette so the chunk's smoke tests
exercise the token machinery in isolation; the canonical dark + light values
land with c44 themes.mojo and are wired into Context by c47.

NOT included in this chunk (per the c43 contract):
  - Light/dark theme presets — c44.
  - Font loading or typography-derived text-rendering helpers — c44.
  - Animation / spring tokens — c45.
  - Widget refactors to consume tokens (DefaultTheme stays in Context) — c47.

References:
  - rerun `crates/viewer/re_ui/src/design_tokens.rs` (semantic naming).
  - `/home/alex/mojoui-audit/AUDIT_egui_ecosystem.md` §"Aesthetic Patterns"
    (8px grid, 6px default radius, semantic state tokens, alert fill/text
    pairs, axis colors).
"""

from mojoui.core.types import Color


# ============================================================================
# ColorTokens — semantic palette
# ============================================================================


struct ColorTokens(Copyable, Movable):
    """Semantic color palette. Each field is a Color the widgets reference by
    NAME. Values come from the active theme (c44 themes.mojo); this struct
    declares the contract and seeds a neutral dark default so the chunk is
    self-contained.

    Naming follows rerun's `design_tokens.rs`:
      - `bg_*`     — surfaces, darkest (app) → lightest (raised).
      - `text_*`   — typography colors (default / subdued / disabled /
                     text-on-accent).
      - `accent_*` — brand / primary action (default / hover / active).
      - `border_*` — outlines + dividers.
      - `alert_*`  — semantic states (info / warning / error / success),
                     fill + text grouped per severity.
      - `graph_*`  — node-graph specific colors used by `mojoui.nodes.canvas`
                     (c39) — included here so c47 can swap node-canvas
                     colors via a theme without touching the widget. Per-
                     `NodeValueType` wire colors stay in `nodes/wires.mojo`
                     (`wire_color_for_type`) for now; a future refactor may
                     promote them to tokens too.
    """

    # Backgrounds (darkest → lightest)
    var bg_default: Color           # app background
    var bg_panel: Color             # window / panel background
    var bg_surface: Color           # raised surface (cards, hover targets)
    var bg_input: Color             # text input + select backgrounds
    # Extended surface ladder (rerun parity — F4 / 2026-05-28 bugfix)
    var floating_color: Color       # popovers, tooltips, dropdowns
    var faint_bg_color: Color       # subtle alternating-row bg
    var extreme_bg_color: Color     # max-contrast bg (e.g. inverse panel)

    # Text
    var text_default: Color         # primary body text
    var text_subdued: Color         # secondary / muted text
    var text_disabled: Color
    var text_on_accent: Color       # text rendered on accent_default fill
    var text_strong: Color          # high-emphasis text (headings, titles)

    # Widget state (rerun parity — F4 / 2026-05-28 bugfix)
    var widget_inactive_bg_fill: Color  # default widget bg (button at rest)
    var widget_hovered_color: Color     # widget bg on hover
    var widget_active_bg_fill: Color    # widget bg when pressed

    # Accent (brand / primary action)
    var accent_default: Color       # primary action bg, focus ring, links
    var accent_hover: Color
    var accent_active: Color

    # Borders + separators
    var border_default: Color
    var border_strong: Color
    var separator: Color            # divider line color

    # Selection + focus (rerun parity — F4 / 2026-05-28 bugfix)
    var selection_bg_fill: Color    # selected text/item bg
    var selection_stroke_color: Color  # selected text/item stroke
    var focus_outline_stroke: Color  # focus ring color

    # Semantic state (severity fill + matching text color)
    var alert_info_fill: Color
    var alert_info_text: Color
    var alert_warning_fill: Color
    var alert_warning_text: Color
    var alert_error_fill: Color
    var alert_error_text: Color
    var alert_success_fill: Color
    var alert_success_text: Color

    # Node graph (M2.5 canvas)
    var graph_canvas_bg: Color
    var graph_node_bg: Color
    var graph_node_bg_selected: Color
    var graph_node_title_bg: Color

    def __init__(out self):
        """Default-construct to a neutral dark palette. Themes (c44) override
        wholesale via `Theme.colors = ...`."""
        self.bg_default = Color(20, 22, 26, 255)
        self.bg_panel = Color(28, 30, 36, 255)
        self.bg_surface = Color(40, 44, 52, 255)
        self.bg_input = Color(24, 26, 30, 255)
        self.floating_color = Color(36, 38, 44, 255)
        self.faint_bg_color = Color(32, 34, 40, 255)
        self.extreme_bg_color = Color(8, 9, 12, 255)

        self.text_default = Color(225, 225, 235, 255)
        self.text_subdued = Color(150, 150, 165, 255)
        self.text_disabled = Color(80, 80, 90, 255)
        self.text_on_accent = Color(255, 255, 255, 255)
        self.text_strong = Color(250, 250, 255, 255)

        self.widget_inactive_bg_fill = Color(50, 54, 62, 255)
        self.widget_hovered_color = Color(70, 74, 84, 255)
        self.widget_active_bg_fill = Color(90, 94, 105, 255)

        self.accent_default = Color(110, 90, 200, 255)
        self.accent_hover = Color(130, 110, 220, 255)
        self.accent_active = Color(90, 70, 180, 255)

        self.border_default = Color(60, 64, 72, 255)
        self.border_strong = Color(90, 94, 102, 255)
        self.separator = Color(50, 54, 62, 255)

        self.selection_bg_fill = Color(70, 90, 160, 200)
        self.selection_stroke_color = Color(120, 140, 220, 255)
        self.focus_outline_stroke = Color(130, 110, 220, 255)

        self.alert_info_fill = Color(50, 90, 140, 255)
        self.alert_info_text = Color(200, 220, 240, 255)
        self.alert_warning_fill = Color(160, 110, 30, 255)
        self.alert_warning_text = Color(240, 220, 180, 255)
        self.alert_error_fill = Color(160, 50, 50, 255)
        self.alert_error_text = Color(240, 200, 200, 255)
        self.alert_success_fill = Color(50, 130, 60, 255)
        self.alert_success_text = Color(200, 240, 200, 255)

        self.graph_canvas_bg = Color(15, 15, 18, 255)
        self.graph_node_bg = Color(40, 40, 50, 240)
        self.graph_node_bg_selected = Color(60, 60, 90, 240)
        self.graph_node_title_bg = Color(60, 70, 110, 255)


# ============================================================================
# SpacingTokens — 8px grid scale (per rerun)
# ============================================================================


struct SpacingTokens(Copyable, Movable):
    """8px-grid spacing scale. Six rungs — every value is either a
    multiple of 4 (xs/sm) or a multiple of 8 (md/lg/xl/xxl). Widgets pick the
    rung that matches their visual density rather than hard-coding pixel
    literals.

    Reference: rerun's `item_spacing = 8` + `view_padding = 12` + `indent =
    14` all sit on the 4/8 grid; egui_demo defaults sit on the same grid.
    """

    var xs: Int32   # 2  — tightest gap
    var sm: Int32   # 4
    var md: Int32   # 8  — base unit
    var lg: Int32   # 16
    var xl: Int32   # 24
    var xxl: Int32  # 32

    def __init__(out self):
        self.xs = 2
        self.sm = 4
        self.md = 8
        self.lg = 16
        self.xl = 24
        self.xxl = 32


# ============================================================================
# RadiusTokens — corner radius scale
# ============================================================================


struct RadiusTokens(Copyable, Movable):
    """Corner-radius scale. `pill` is a 9999 sentinel meaning "fully rounded"
    — renderers clamp to half the smaller axis at draw time so a pill rect
    always reads as a stadium. Default radius for buttons / panels is `md`
    (6 px, matches rerun's `normal_corner_radius`); cards / popovers use
    `lg` (12 px).
    """

    var none: Int32   # 0 (square)
    var sm: Int32     # 2
    var md: Int32     # 6 (default for buttons / panels)
    var lg: Int32     # 12 (cards / popovers)
    var pill: Int32   # 9999 sentinel — fully rounded

    def __init__(out self):
        self.none = 0
        self.sm = 2
        self.md = 6
        self.lg = 12
        self.pill = 9999


# ============================================================================
# TypographyTokens — size + weight scale
# ============================================================================


struct TypographyTokens(Copyable, Movable):
    """Type scale — sizes in points, weights as numeric-coded `Int32` values
    matching the OpenType / CSS convention (400=normal, 500=medium, 700=bold).
    Widgets pick the size rung that matches their role (caption / body /
    heading_sm / heading_md / heading_lg / mono); c44 wires these into the
    font loader's per-size atlas pre-bake.
    """

    var size_caption: Int32     # 11
    var size_body: Int32        # 14
    var size_heading_sm: Int32  # 16
    var size_heading_md: Int32  # 20
    var size_heading_lg: Int32  # 28
    var size_mono: Int32        # 13

    var weight_normal: Int32    # 400
    var weight_medium: Int32    # 500
    var weight_bold: Int32      # 700

    def __init__(out self):
        self.size_caption = 11
        self.size_body = 14
        self.size_heading_sm = 16
        self.size_heading_md = 20
        self.size_heading_lg = 28
        self.size_mono = 13

        self.weight_normal = 400
        self.weight_medium = 500
        self.weight_bold = 700


# ============================================================================
# Theme — composed token bundle
# ============================================================================


struct Theme(Copyable, Movable):
    """Composed theme: `colors` + `spacing` + `radius` + `typography`, plus
    `font_id` (UInt32 returned by `Backend.load_font`; 0 = no font loaded, so
    widgets skip text per the M1 bugfix font_id contract — see
    `SKEPTIC_FINDINGS_M1` FRAGILE #5) and `name` for theme-switching debug.

    Default-constructs to a neutral dark palette so the chunk's smoke tests
    can exercise the token machinery without depending on c44. c44 supplies
    `dark_theme()` / `light_theme()` factories; c47 swaps Context's active
    theme via a single field assignment.
    """

    var name: String
    var colors: ColorTokens
    var spacing: SpacingTokens
    var radius: RadiusTokens
    var typography: TypographyTokens
    var font_id: UInt32

    def __init__(out self):
        self.name = String("default")
        self.colors = ColorTokens()
        self.spacing = SpacingTokens()
        self.radius = RadiusTokens()
        self.typography = TypographyTokens()
        self.font_id = 0
