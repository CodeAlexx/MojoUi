"""Trainer-oriented warm theme helpers for dense app UIs."""

from mojoui.core.context import Context
from mojoui.core.types import Color
from mojoui.theme.apply import apply_theme
from mojoui.theme.serenity_palettes import rust_trainer_theme


struct TrainerColors(Copyable, Movable):
    var bg: Color
    var panel: Color
    var panel2: Color
    var line: Color
    var line2: Color
    var text: Color
    var dim: Color
    var mute: Color
    var accent: Color
    var accent_soft: Color
    var ok: Color
    var warn: Color
    var err: Color

    def __init__(out self):
        self.bg = Color(20, 17, 15, 255)
        self.panel = Color(27, 24, 21, 255)
        self.panel2 = Color(34, 30, 26, 255)
        self.line = Color(42, 37, 32, 255)
        self.line2 = Color(55, 48, 41, 255)
        self.text = Color(237, 230, 220, 255)
        self.dim = Color(179, 168, 155, 255)
        self.mute = Color(122, 111, 99, 255)
        self.accent = Color(230, 154, 92, 255)
        self.accent_soft = Color(67, 43, 27, 255)
        self.ok = Color(110, 195, 148, 255)
        self.warn = Color(215, 185, 94, 255)
        self.err = Color(217, 106, 84, 255)


def rust_trainer_colors() -> TrainerColors:
    return TrainerColors()


def apply_rust_trainer_theme(mut ctx: Context):
    """Apply the warm Rust-trainer palette to a Context's compact theme."""
    var t = rust_trainer_theme()
    apply_theme(ctx, t)
    ctx.theme.font_size_pt = 14
    ctx.theme.row_height = 30
    ctx.theme.spacing = 5
    ctx.theme.padding = 7


def apply_serenity_trainer_theme(mut ctx: Context):
    """Apply the neutral SerenityUI app palette to a dense trainer Context."""
    var old_font = ctx.theme.font_id
    ctx.theme.bg = Color(22, 22, 28, 255)
    ctx.theme.fg = Color(225, 225, 235, 255)
    ctx.theme.text = Color(225, 225, 235, 255)
    ctx.theme.primary = Color(235, 150, 60, 255)
    ctx.theme.control_bg = Color(44, 44, 54, 255)
    ctx.theme.hover_bg = Color(58, 58, 70, 255)
    ctx.theme.active_bg = Color(74, 74, 88, 255)
    ctx.theme.border = Color(72, 72, 84, 255)

    ctx.theme.bg_panel = Color(28, 28, 36, 255)
    ctx.theme.bg_surface = Color(34, 34, 44, 255)
    ctx.theme.bg_input = Color(36, 36, 46, 255)
    ctx.theme.floating_bg = Color(32, 32, 42, 255)
    ctx.theme.faint_bg = Color(24, 24, 31, 255)
    ctx.theme.extreme_bg = Color(12, 12, 16, 255)
    ctx.theme.text_subdued = Color(155, 155, 170, 255)
    ctx.theme.text_disabled = Color(92, 92, 104, 255)
    ctx.theme.text_on_accent = Color(24, 16, 10, 255)
    ctx.theme.text_strong = Color(246, 246, 252, 255)
    ctx.theme.primary_hover = Color(245, 170, 82, 255)
    ctx.theme.primary_active = Color(205, 125, 45, 255)
    ctx.theme.border_strong = Color(92, 92, 108, 255)
    ctx.theme.separator = Color(52, 52, 64, 255)
    ctx.theme.selection_bg = Color(82, 52, 30, 220)
    ctx.theme.selection_stroke = Color(235, 150, 60, 255)
    ctx.theme.focus_outline = Color(245, 170, 82, 255)
    ctx.theme.info_bg = Color(52, 74, 112, 255)
    ctx.theme.info_text = Color(210, 225, 245, 255)
    ctx.theme.warning_bg = Color(210, 150, 58, 255)
    ctx.theme.warning_text = Color(32, 22, 10, 255)
    ctx.theme.error_bg = Color(205, 72, 78, 255)
    ctx.theme.error_text = Color(255, 230, 230, 255)
    ctx.theme.success_bg = Color(54, 150, 98, 255)
    ctx.theme.success_text = Color(218, 248, 230, 255)
    ctx.theme.graph_canvas_bg = Color(15, 15, 18, 255)
    ctx.theme.graph_node_bg = Color(42, 43, 52, 238)
    ctx.theme.graph_node_selected_bg = Color(58, 60, 88, 246)
    ctx.theme.graph_node_title_bg = Color(36, 38, 48, 255)

    ctx.theme.font_id = old_font
    ctx.theme.font_size_pt = 14
    ctx.theme.row_height = 30
    ctx.theme.spacing = 5
    ctx.theme.padding = 7
