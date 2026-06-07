"""Tests for trainer-style form helpers."""

from mojoui.core.context import Context
from mojoui.core.types import Vec2
from mojoui.theme.trainer_theme import apply_rust_trainer_theme
from mojoui.widgets.form import (
    begin_form_panel,
    console_line,
    end_form_panel,
    field_row,
    progress_row,
    toggle_row,
)


def _row1(a: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    return r^


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_form_panel_commands() raises:
    var ctx = Context()
    apply_rust_trainer_theme(ctx)
    ctx.begin_frame_no_input(Vec2(640.0, 420.0), Vec2(-10.0, -10.0), False, False)
    ctx.layout_row(_row1(360), 240)
    begin_form_panel(ctx, String("GENERAL"), String("Workspace and validation"))
    field_row(ctx, 140, 180, String("Workspace"), String("~/trainings/run"))
    var enabled = True
    _ = toggle_row(ctx, 140, 180, String("Tensorboard"), String("Enabled"), enabled)
    progress_row(ctx, 140, 180, String("Ready"), 0.5)
    console_line(ctx, 72, 54, 194, String("12:00"), String("INFO"), String("ready"))
    end_form_panel(ctx)
    ctx.end_frame()
    _expect(ctx.commands.byte_count() > 0, "form helpers should emit draw commands")
    print("PASS: form panel commands")


def main() raises:
    test_form_panel_commands()
    print("PASS: form helper tests")
