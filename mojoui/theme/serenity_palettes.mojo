"""Serenity/DearPyGui-inspired theme palette registry.

Source reference:
  `serenity/serenity/ui/theme.py`

Serenity's Python UI defines DearPyGui palettes in terms of ImGui/DPG tokens
such as `mvThemeCol_WindowBg`, `mvThemeCol_FrameBg`, and
`mvThemeCol_Button`. This module keeps those palettes available to MojoUI by
mapping the DPG token vocabulary into MojoUI's semantic `Theme` tokens.
"""

from mojoui.core.types import Color
from mojoui.theme.tokens import Theme, ColorTokens, RadiusTokens


comptime SERENITY_PALETTE_COUNT: Int = 8


def _rgba(r: Int, g: Int, b: Int, a: Int) -> Color:
    return Color(UInt8(r), UInt8(g), UInt8(b), UInt8(a))


def _f(r: Float32, g: Float32, b: Float32, a: Float32) -> Color:
    return _rgba(
        Int(r * 255.0 + 0.5),
        Int(g * 255.0 + 0.5),
        Int(b * 255.0 + 0.5),
        Int(a * 255.0 + 0.5),
    )


def _readable_text_on_fill(fill: Color) -> Color:
    var yiq = Int(fill.r) * 299 + Int(fill.g) * 587 + Int(fill.b) * 114
    if yiq >= 150000:
        return Color(20, 20, 24, 255)
    return Color(245, 245, 250, 255)


def _theme_from_dpg_palette(
    name: String,
    window_bg: Color,
    child_bg: Color,
    popup_bg: Color,
    border: Color,
    text: Color,
    text_disabled: Color,
    frame_bg: Color,
    frame_bg_hover: Color,
    frame_bg_active: Color,
    button: Color,
    button_hover: Color,
    button_active: Color,
    header: Color,
    header_hover: Color,
    header_active: Color,
    slider_grab: Color,
    slider_grab_active: Color,
    checkmark: Color,
    separator: Color,
    plot_bg: Color,
    plot_histogram: Color,
    title_bg: Color,
    menubar_bg: Color,
    modal_dim_bg: Color,
    rounding: Int32,
) -> Theme:
    var t = Theme()
    t.name = name.copy()

    var c = ColorTokens()
    c.bg_default = window_bg.copy()
    c.bg_panel = child_bg.copy()
    c.bg_surface = popup_bg.copy()
    c.bg_input = frame_bg.copy()
    c.floating_color = popup_bg.copy()
    c.faint_bg_color = child_bg.with_alpha(UInt8(210))
    c.extreme_bg_color = plot_bg.copy()

    c.text_default = text.copy()
    c.text_subdued = text_disabled.copy()
    c.text_disabled = text_disabled.with_alpha(UInt8(160))
    c.text_on_accent = _readable_text_on_fill(slider_grab.copy())
    c.text_strong = text.copy()

    c.widget_inactive_bg_fill = frame_bg.copy()
    c.widget_hovered_color = frame_bg_hover.copy()
    c.widget_active_bg_fill = frame_bg_active.copy()

    # DPG themes often put their strongest identity color on slider/checkmark,
    # while buttons may be neutral. Use slider/checkmark as MojoUI's accent.
    c.accent_default = slider_grab.copy()
    c.accent_hover = slider_grab_active.copy()
    c.accent_active = button_active.copy()

    c.border_default = border.copy()
    c.border_strong = separator.copy()
    c.separator = separator.copy()

    c.selection_bg_fill = checkmark.with_alpha(UInt8(120))
    c.selection_stroke_color = checkmark.copy()
    c.focus_outline_stroke = slider_grab_active.copy()

    c.alert_info_fill = header.copy()
    c.alert_info_text = _readable_text_on_fill(header.copy())
    c.alert_warning_fill = plot_histogram.copy()
    c.alert_warning_text = _readable_text_on_fill(plot_histogram.copy())
    c.alert_error_fill = Color(210, 55, 65, 255)
    c.alert_error_text = _readable_text_on_fill(c.alert_error_fill.copy())
    c.alert_success_fill = Color(30, 160, 95, 255)
    c.alert_success_text = _readable_text_on_fill(c.alert_success_fill.copy())

    c.graph_canvas_bg = plot_bg.copy()
    c.graph_node_bg = child_bg.with_alpha(UInt8(240))
    c.graph_node_bg_selected = header_hover.with_alpha(UInt8(240))
    c.graph_node_title_bg = header_active.copy()

    t.colors = c^
    var r = RadiusTokens()
    r.sm = Int32(2)
    r.md = rounding
    r.lg = rounding + Int32(4)
    t.radius = r^
    return t^


def serenity_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Serenity"),
        _rgba(26, 26, 46, 255),
        _rgba(22, 33, 62, 255),
        _rgba(30, 30, 52, 255),
        _rgba(42, 42, 74, 255),
        _rgba(232, 232, 232, 255),
        _rgba(102, 102, 102, 255),
        _rgba(22, 33, 62, 255),
        _rgba(30, 42, 78, 255),
        _rgba(38, 52, 94, 255),
        _rgba(67, 97, 238, 255),
        _rgba(90, 120, 240, 255),
        _rgba(52, 81, 222, 255),
        _rgba(15, 52, 96, 255),
        _rgba(20, 65, 120, 255),
        _rgba(25, 78, 140, 255),
        _rgba(67, 97, 238, 255),
        _rgba(90, 120, 240, 255),
        _rgba(67, 97, 238, 255),
        _rgba(42, 42, 74, 255),
        _rgba(18, 18, 36, 255),
        _rgba(67, 97, 238, 255),
        _rgba(15, 15, 30, 255),
        _rgba(20, 20, 38, 255),
        _rgba(0, 0, 0, 140),
        Int32(4),
    )


def rust_trainer_theme() -> Theme:
    """Warm trainer palette from the Rust Trainer handoff zip.

    Handoff tokens:
      bg #14110F, bg_2/panel #1B1815, bg_3 #221E1A,
      line #2A2520, line_2 #332D27, ink #EDE6DC,
      ink_dim #B3A89B, ink_mute #7A6F63, accent #E69A5C.
    """
    return _theme_from_dpg_palette(
        String("Rust Trainer"),
        _rgba(20, 17, 15, 255),
        _rgba(27, 24, 21, 255),
        _rgba(27, 24, 21, 255),
        _rgba(42, 37, 32, 255),
        _rgba(237, 230, 220, 255),
        _rgba(122, 111, 99, 255),
        _rgba(34, 30, 26, 255),
        _rgba(51, 45, 39, 255),
        _rgba(58, 50, 42, 255),
        _rgba(34, 30, 26, 255),
        _rgba(51, 45, 39, 255),
        _rgba(230, 154, 92, 255),
        _rgba(44, 35, 28, 255),
        _rgba(62, 48, 37, 255),
        _rgba(84, 58, 39, 255),
        _rgba(230, 154, 92, 255),
        _rgba(245, 180, 122, 255),
        _rgba(230, 154, 92, 255),
        _rgba(42, 37, 32, 255),
        _rgba(12, 10, 8, 255),
        _rgba(110, 195, 148, 255),
        _rgba(18, 14, 10, 255),
        _rgba(27, 24, 21, 255),
        _rgba(0, 0, 0, 150),
        Int32(6),
    )


def moonlight_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Moonlight"),
        _rgba(20, 22, 26, 255),
        _rgba(24, 26, 30, 255),
        _rgba(20, 22, 26, 255),
        _rgba(40, 43, 49, 255),
        _rgba(255, 255, 255, 255),
        _rgba(70, 81, 115, 255),
        _rgba(29, 32, 39, 255),
        _rgba(40, 43, 49, 255),
        _rgba(40, 43, 49, 255),
        _rgba(30, 34, 38, 255),
        _rgba(46, 48, 50, 255),
        _rgba(39, 39, 39, 255),
        _rgba(36, 42, 53, 255),
        _rgba(27, 27, 27, 255),
        _rgba(20, 22, 26, 255),
        _rgba(248, 255, 127, 255),
        _rgba(255, 203, 127, 255),
        _rgba(248, 255, 127, 255),
        _rgba(33, 38, 49, 255),
        _rgba(12, 14, 18, 255),
        _rgba(248, 255, 127, 255),
        _rgba(12, 14, 18, 255),
        _rgba(25, 27, 31, 255),
        _rgba(50, 45, 139, 128),
        Int32(6),
    )


def monochrome_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Monochrome"),
        _rgba(0, 0, 0, 255),
        _rgba(0, 0, 0, 0),
        _rgba(0, 33, 33, 230),
        _rgba(0, 255, 255, 166),
        _rgba(0, 255, 255, 255),
        _rgba(0, 102, 105, 255),
        _rgba(112, 204, 204, 46),
        _rgba(112, 204, 204, 69),
        _rgba(112, 207, 219, 168),
        _rgba(0, 166, 166, 117),
        _rgba(3, 255, 255, 110),
        _rgba(0, 255, 255, 158),
        _rgba(0, 255, 255, 84),
        _rgba(0, 255, 255, 107),
        _rgba(0, 255, 255, 138),
        _rgba(0, 255, 255, 92),
        _rgba(0, 255, 255, 194),
        _rgba(0, 255, 255, 173),
        _rgba(0, 128, 128, 84),
        _rgba(0, 0, 0, 255),
        _rgba(0, 255, 255, 255),
        _rgba(36, 46, 54, 186),
        _rgba(0, 0, 0, 51),
        _rgba(10, 26, 23, 130),
        Int32(3),
    )


def nord_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Nord"),
        _f(0.18, 0.20, 0.25, 1.00),
        _f(0.16, 0.17, 0.20, 1.00),
        _f(0.23, 0.26, 0.32, 1.00),
        _f(0.14, 0.16, 0.19, 1.00),
        _f(0.85, 0.87, 0.91, 0.88),
        _f(0.49, 0.50, 0.53, 1.00),
        _f(0.23, 0.26, 0.32, 1.00),
        _f(0.56, 0.74, 0.73, 1.00),
        _f(0.53, 0.75, 0.82, 1.00),
        _f(0.18, 0.20, 0.25, 1.00),
        _f(0.51, 0.63, 0.76, 1.00),
        _f(0.37, 0.51, 0.67, 1.00),
        _f(0.51, 0.63, 0.76, 1.00),
        _f(0.53, 0.75, 0.82, 1.00),
        _f(0.37, 0.51, 0.67, 1.00),
        _f(0.51, 0.63, 0.76, 1.00),
        _f(0.37, 0.51, 0.67, 1.00),
        _f(0.37, 0.51, 0.67, 1.00),
        _f(0.14, 0.16, 0.19, 1.00),
        _f(0.18, 0.20, 0.25, 1.00),
        _f(0.56, 0.74, 0.73, 1.00),
        _f(0.16, 0.16, 0.20, 1.00),
        _f(0.16, 0.16, 0.20, 1.00),
        _f(0.10, 0.10, 0.15, 0.60),
        Int32(4),
    )


def cinder_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Cinder"),
        _f(0.13, 0.14, 0.17, 1.00),
        _f(0.13, 0.14, 0.17, 1.00),
        _f(0.20, 0.22, 0.27, 0.90),
        _f(0.31, 0.31, 1.00, 0.00),
        _f(0.86, 0.93, 0.89, 0.78),
        _f(0.86, 0.93, 0.89, 0.28),
        _f(0.20, 0.22, 0.27, 1.00),
        _f(0.92, 0.18, 0.29, 0.78),
        _f(0.92, 0.18, 0.29, 1.00),
        _f(0.47, 0.77, 0.83, 0.14),
        _f(0.92, 0.18, 0.29, 0.86),
        _f(0.92, 0.18, 0.29, 1.00),
        _f(0.92, 0.18, 0.29, 0.76),
        _f(0.92, 0.18, 0.29, 0.86),
        _f(0.92, 0.18, 0.29, 1.00),
        _f(0.47, 0.77, 0.83, 0.14),
        _f(0.92, 0.18, 0.29, 1.00),
        _f(0.71, 0.22, 0.27, 1.00),
        _f(0.14, 0.16, 0.19, 1.00),
        _f(0.13, 0.14, 0.17, 1.00),
        _f(0.86, 0.93, 0.89, 0.63),
        _f(0.20, 0.22, 0.27, 1.00),
        _f(0.20, 0.22, 0.27, 0.47),
        _f(0.20, 0.22, 0.27, 0.73),
        Int32(4),
    )


def blender_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Blender"),
        _f(0.22, 0.22, 0.22, 1.00),
        _f(0.19, 0.19, 0.19, 1.00),
        _f(0.09, 0.09, 0.09, 1.00),
        _f(0.17, 0.17, 0.17, 1.00),
        _f(0.84, 0.84, 0.84, 1.00),
        _f(0.50, 0.50, 0.50, 1.00),
        _f(0.33, 0.33, 0.33, 1.00),
        _f(0.47, 0.47, 0.47, 1.00),
        _f(0.16, 0.16, 0.16, 1.00),
        _f(0.33, 0.33, 0.33, 1.00),
        _f(0.40, 0.40, 0.40, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.27, 0.27, 0.27, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.27, 0.27, 0.27, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.18, 0.18, 0.18, 1.00),
        _f(0.19, 0.19, 0.19, 1.00),
        _f(0.28, 0.45, 0.70, 1.00),
        _f(0.11, 0.11, 0.11, 1.00),
        _f(0.11, 0.11, 0.11, 1.00),
        _f(0.10, 0.10, 0.10, 0.60),
        Int32(3),
    )


def cyberpunk_theme() -> Theme:
    return _theme_from_dpg_palette(
        String("Cyberpunk"),
        _f(0.00, 0.04, 0.12, 1.00),
        _f(0.03, 0.04, 0.22, 1.00),
        _f(0.12, 0.06, 0.27, 1.00),
        _f(0.61, 0.00, 1.00, 1.00),
        _f(0.00, 0.82, 1.00, 1.00),
        _f(0.00, 0.36, 0.63, 1.00),
        _f(0.00, 0.75, 1.00, 0.20),
        _f(0.34, 0.00, 1.00, 1.00),
        _f(0.08, 0.00, 1.00, 1.00),
        _f(0.00, 0.98, 1.00, 0.52),
        _f(0.94, 0.00, 1.00, 0.80),
        _f(0.01, 0.00, 1.00, 1.00),
        _f(0.00, 0.95, 1.00, 0.40),
        _f(0.94, 0.00, 1.00, 0.80),
        _f(0.01, 0.00, 1.00, 1.00),
        _f(0.00, 1.00, 0.95, 1.00),
        _f(0.81, 0.00, 1.00, 1.00),
        _f(0.95, 0.19, 0.92, 1.00),
        _f(0.74, 0.00, 1.00, 0.50),
        _f(0.00, 0.04, 0.12, 1.00),
        _f(0.00, 1.00, 0.88, 1.00),
        _f(0.00, 0.81, 0.95, 1.00),
        _f(0.61, 0.00, 1.00, 1.00),
        _f(0.05, 0.00, 0.20, 0.60),
        Int32(3),
    )


def serenity_palette_name(index: Int) -> String:
    if index == 0:
        return String("Rust Trainer")
    if index == 1:
        return String("Serenity")
    if index == 2:
        return String("Moonlight")
    if index == 3:
        return String("Monochrome")
    if index == 4:
        return String("Nord")
    if index == 5:
        return String("Cinder")
    if index == 6:
        return String("Blender")
    if index == 7:
        return String("Cyberpunk")
    return String("Rust Trainer")


def serenity_palette_index(name: String) -> Int:
    for i in range(SERENITY_PALETTE_COUNT):
        if serenity_palette_name(i) == name:
            return i
    return 0


def serenity_theme_for_name(name: String) -> Theme:
    if name == String("Rust Trainer"):
        return rust_trainer_theme()
    if name == String("Serenity"):
        return serenity_theme()
    if name == String("Moonlight"):
        return moonlight_theme()
    if name == String("Monochrome"):
        return monochrome_theme()
    if name == String("Nord"):
        return nord_theme()
    if name == String("Cinder"):
        return cinder_theme()
    if name == String("Blender"):
        return blender_theme()
    if name == String("Cyberpunk"):
        return cyberpunk_theme()
    return rust_trainer_theme()


def serenity_theme_at(index: Int) -> Theme:
    return serenity_theme_for_name(serenity_palette_name(index))
