"""Apply token themes to the active immediate-mode Context.

`mojoui.theme.tokens.Theme` is the rich, app-level theme object. Existing
widgets still read `ctx.theme`, so this bridge maps the token palette into the
compact runtime theme and keeps all extended semantic colors available there.
"""

from mojoui.core.context import Context, DefaultTheme
from mojoui.core.types import Color
from mojoui.theme.tokens import Theme


comptime STATUS_INFO: Int32 = 0
comptime STATUS_SUCCESS: Int32 = 1
comptime STATUS_WARNING: Int32 = 2
comptime STATUS_ERROR: Int32 = 3
comptime STATUS_DISABLED: Int32 = 4


def _row_height_for_body(size_body: Int32, spacing_md: Int32) -> Int32:
    var h = size_body + spacing_md + 4
    if h < 24:
        h = 24
    return h


def theme_to_default_theme(theme: Theme) -> DefaultTheme:
    """Convert a rich token Theme into the runtime Context theme."""
    var runtime = DefaultTheme()
    var c = theme.colors.copy()

    runtime.bg = c.bg_default.copy()
    runtime.fg = c.text_default.copy()
    runtime.primary = c.accent_default.copy()
    runtime.control_bg = c.widget_inactive_bg_fill.copy()
    runtime.hover_bg = c.widget_hovered_color.copy()
    runtime.active_bg = c.widget_active_bg_fill.copy()
    runtime.border = c.border_default.copy()
    runtime.text = c.text_default.copy()

    runtime.bg_panel = c.bg_panel.copy()
    runtime.bg_surface = c.bg_surface.copy()
    runtime.bg_input = c.bg_input.copy()
    runtime.floating_bg = c.floating_color.copy()
    runtime.faint_bg = c.faint_bg_color.copy()
    runtime.extreme_bg = c.extreme_bg_color.copy()
    runtime.text_subdued = c.text_subdued.copy()
    runtime.text_disabled = c.text_disabled.copy()
    runtime.text_on_accent = c.text_on_accent.copy()
    runtime.text_strong = c.text_strong.copy()
    runtime.primary_hover = c.accent_hover.copy()
    runtime.primary_active = c.accent_active.copy()
    runtime.border_strong = c.border_strong.copy()
    runtime.separator = c.separator.copy()
    runtime.selection_bg = c.selection_bg_fill.copy()
    runtime.selection_stroke = c.selection_stroke_color.copy()
    runtime.focus_outline = c.focus_outline_stroke.copy()
    runtime.info_bg = c.alert_info_fill.copy()
    runtime.info_text = c.alert_info_text.copy()
    runtime.warning_bg = c.alert_warning_fill.copy()
    runtime.warning_text = c.alert_warning_text.copy()
    runtime.error_bg = c.alert_error_fill.copy()
    runtime.error_text = c.alert_error_text.copy()
    runtime.success_bg = c.alert_success_fill.copy()
    runtime.success_text = c.alert_success_text.copy()
    runtime.graph_canvas_bg = c.graph_canvas_bg.copy()
    runtime.graph_node_bg = c.graph_node_bg.copy()
    runtime.graph_node_selected_bg = c.graph_node_bg_selected.copy()
    runtime.graph_node_title_bg = c.graph_node_title_bg.copy()

    runtime.font_id = theme.font_id
    runtime.font_size_pt = theme.typography.size_body
    runtime.row_height = _row_height_for_body(
        theme.typography.size_body, theme.spacing.md
    )
    runtime.spacing = theme.spacing.sm
    runtime.padding = theme.spacing.md
    return runtime^


def apply_theme(mut ctx: Context, theme: Theme):
    """Apply a token Theme to a Context.

    If `theme.font_id` is 0, preserve the Context's current font. This lets
    apps load a font once and swap palettes without blanking text rendering.
    """
    var old_font = ctx.theme.font_id
    var runtime_theme = theme_to_default_theme(theme)
    if runtime_theme.font_id == UInt32(0):
        runtime_theme.font_id = old_font
    ctx.set_theme(runtime_theme)


def status_fill(theme: DefaultTheme, status: Int32) -> Color:
    if status == STATUS_SUCCESS:
        return theme.success_bg.copy()
    if status == STATUS_WARNING:
        return theme.warning_bg.copy()
    if status == STATUS_ERROR:
        return theme.error_bg.copy()
    if status == STATUS_DISABLED:
        return theme.text_disabled.copy()
    return theme.info_bg.copy()


def status_text(theme: DefaultTheme, status: Int32) -> Color:
    if status == STATUS_SUCCESS:
        return theme.success_text.copy()
    if status == STATUS_WARNING:
        return theme.warning_text.copy()
    if status == STATUS_ERROR:
        return theme.error_text.copy()
    if status == STATUS_DISABLED:
        return theme.text_subdued.copy()
    return theme.info_text.copy()
