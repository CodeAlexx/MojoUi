"""Reusable fixed-shell helpers for dense trainer/inference apps."""

from mojoui.core.context import Context
from mojoui.core.control import CTRL_ACTIVE, CTRL_HOVERED, CTRL_RELEASED, OPT_FOCUSABLE
from mojoui.core.types import Vec2, Rect, Color
from mojoui.theme.trainer_theme import rust_trainer_colors


struct TrainerShellMetrics(Copyable, Movable):
    var nav_w: Int32
    var status_w: Int32
    var top_h: Int32
    var gap: Int32
    var pad: Int32
    var row_h: Int32
    var main_w: Int32
    var scale: Float32

    def __init__(out self):
        self.nav_w = 230
        self.status_w = 330
        self.top_h = 58
        self.gap = 16
        self.pad = 18
        self.row_h = 32
        self.main_w = 800
        self.scale = 1.0


def _clamp_scale(v: Float32) -> Float32:
    if v < 1.0:
        return 1.0
    if v > 2.05:
        return 2.05
    return v


def trainer_shell_metrics(win_w: Float32, win_h: Float32) -> TrainerShellMetrics:
    var sx = win_w / 1480.0
    var sy = win_h / 920.0
    var s = sx
    if sy < s:
        s = sy
    s = _clamp_scale(s)
    var m = TrainerShellMetrics()
    m.scale = s
    m.nav_w = Int32(230.0 * s + 0.5)
    m.status_w = Int32(330.0 * s + 0.5)
    m.gap = Int32(16.0 * s + 0.5)
    m.pad = Int32(18.0 * s + 0.5)
    m.row_h = Int32(40.0 * s + 0.5)
    m.top_h = m.row_h * 2 + Int32(12.0 * s + 0.5)
    m.main_w = Int32(win_w) - m.nav_w - m.status_w - m.gap * 2
    if m.main_w < Int32(640.0 * s):
        m.main_w = Int32(640.0 * s)
    return m^


def apply_shell_density(mut ctx: Context, m: TrainerShellMetrics):
    if m.scale >= 1.95:
        ctx.theme.font_size_pt = 42
    elif m.scale >= 1.7:
        ctx.theme.font_size_pt = 38
    elif m.scale >= 1.35:
        ctx.theme.font_size_pt = 34
    elif m.scale >= 1.15:
        ctx.theme.font_size_pt = 29
    else:
        ctx.theme.font_size_pt = 24
    ctx.theme.row_height = m.row_h
    ctx.theme.padding = Int32(10.0 * m.scale + 0.5)
    ctx.theme.spacing = Int32(6.0 * m.scale + 0.5)


def draw_shell_background(mut ctx: Context, m: TrainerShellMetrics, win_w: Float32, win_h: Float32):
    var c = rust_trainer_colors()
    ctx.draw_rect(Rect(0.0, 0.0, win_w, win_h), c.bg.copy())
    ctx.draw_rect(Rect(0.0, 0.0, Float32(m.nav_w), win_h), c.panel.copy())
    ctx.draw_rect(
        Rect(win_w - Float32(m.status_w), 0.0, Float32(m.status_w), win_h),
        c.panel.copy(),
    )
    ctx.draw_rect(
        Rect(Float32(m.nav_w), 0.0, win_w - Float32(m.nav_w + m.status_w), Float32(m.top_h)),
        c.panel.copy(),
    )
    ctx.draw_rect(Rect(Float32(m.nav_w) - 1.0, 0.0, 1.0, win_h), c.line.copy())
    ctx.draw_rect(Rect(win_w - Float32(m.status_w), 0.0, 1.0, win_h), c.line.copy())
    ctx.draw_rect(
        Rect(Float32(m.nav_w), Float32(m.top_h) - 1.0, win_w - Float32(m.nav_w + m.status_w), 1.0),
        c.line.copy(),
    )


def nav_row(mut ctx: Context, id_str: String, label_text: String, active: Bool) -> Bool:
    """A fixed-height active-aware nav row. Returns True on click."""
    var c = rust_trainer_colors()
    var rect = ctx.layout_next()
    var id = ctx.get_id(id_str)
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)
    if active:
        ctx.draw_rect(rect.copy(), c.accent_soft.copy())
        ctx.draw_rect(Rect(rect.x + rect.w - 5.0, rect.y + 7.0, 4.0, rect.h - 14.0), c.accent.copy())
    elif (flags & CTRL_HOVERED) != 0:
        ctx.draw_rect(rect.copy(), Color(30, 27, 24, 255))
    if ctx.theme.font_id != 0:
        var fg = c.dim.copy()
        if active:
            fg = c.accent.copy()
        var font_size = ctx.theme.font_size_pt
        if font_size < 14:
            font_size = 14
        ctx.draw_text(
            ctx.theme.font_id,
            font_size,
            Vec2(rect.x + Float32(ctx.theme.padding), rect.y + (rect.h + Float32(font_size) * 0.68) * 0.5),
            fg,
            label_text,
        )
    return (flags & CTRL_RELEASED) != 0


def action_button(mut ctx: Context, id_str: String, label_text: String, primary: Bool) -> Bool:
    """A compact shell action button using the next layout slot."""
    var c = rust_trainer_colors()
    var rect = ctx.layout_next()
    var id = ctx.get_id(id_str)
    var flags = ctx.update_control(id, rect.copy(), OPT_FOCUSABLE)
    var bg = ctx.theme.control_bg.copy()
    var fg = ctx.theme.text.copy()
    if primary:
        bg = c.accent.copy()
        fg = Color(22, 12, 3, 255)
    if (flags & CTRL_ACTIVE) != 0:
        bg = c.accent_soft.copy()
        fg = c.text.copy()
    elif (flags & CTRL_HOVERED) != 0 and not primary:
        bg = Color(45, 39, 34, 255)
    ctx.draw_rect(rect.copy(), bg)
    if ctx.theme.font_id != 0:
        var font_size = ctx.theme.font_size_pt - 1
        if font_size < 13:
            font_size = 13
        ctx.draw_text(
            ctx.theme.font_id,
            font_size,
            Vec2(rect.x + Float32(ctx.theme.padding), rect.y + (rect.h + Float32(font_size) * 0.62) * 0.5),
            fg,
            label_text,
        )
    return (flags & CTRL_RELEASED) != 0
