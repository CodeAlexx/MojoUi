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
