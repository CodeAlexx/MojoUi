"""MojoUI m9 — native trainer UI shell.

Trainer-first screen based on `the trainer UI mockup archive`.
This is still a prototype, but it now uses the Rust Trainer warm palette,
proper column frames, and live-window scaling for high-DPI/4K displays.
"""

from std.memory import UnsafePointer
from mojoui.core.types import Vec2, Rect, Color
from mojoui.core.context import Context
from mojoui.core.commands import (
    CMD_JUMP, CMD_RECT, CMD_TEXT, CMD_TRIANGLES,
    CmdTriangles, read_cmd_rect, read_cmd_text, read_cmd_triangles,
)
from mojoui.render.backend import Backend
from mojoui.widgets.basic import button, label, separator
from mojoui.widgets.combobox import combobox
from mojoui.widgets.slider import slider
from mojoui.widgets.drag_value import drag_value
from mojoui.widgets.checkbox import checkbox
from mojoui.widgets.progress_bar import progress_bar
from mojoui.widgets.text_edit import text_edit
from mojoui.core.textedit import TextEditState
from mojoui.app.state import store_user_state, retrieve_user_state
from mojoui.app.trainer_model import (
    TrainerState,
    TRAINER_SECTION_MODEL,
    TRAINER_SECTION_DATASET,
    TRAINER_SECTION_CONCEPTS,
    TRAINER_SECTION_TRAINING,
    TRAINER_SECTION_SAMPLING,
    TRAINER_SECTION_BACKUP,
    TRAINER_SECTION_RUNS,
    TRAINER_SECTION_LOGS,
    assign_dataset_buckets,
    trainer_validation_issues,
    trainer_validation_summary,
    trainer_preset_json_from_state,
    trainer_state_apply_preset_json,
)
from mojoui.app.trainer_runtime_bridge import (
    TrainerUiRuntime,
    trainer_submit_current,
    trainer_tick_and_apply,
    trainer_pause,
    trainer_resume,
    trainer_cancel_all,
    trainer_sample_now,
    trainer_save_checkpoint_now,
    trainer_progress_fraction,
)
from mojoui.theme.serenity_palettes import serenity_theme_at


comptime _INIT_W: Float32 = 1800.0
comptime _INIT_H: Float32 = 1100.0


struct TrainerAppState(Movable):
    var ctx: Context
    var model: TrainerState
    var runtime: TrainerUiRuntime
    var run_name_edit: TextEditState
    var project_dir_edit: TextEditState
    var base_model_edit: TextEditState
    var vae_override_edit: TextEditState
    var dataset_path_edit: TextEditState
    var output_dir_edit: TextEditState
    var filename_pattern_edit: TextEditState
    var preset_json: String
    var preset_status: String
    var font_id: UInt32
    var win_w: Float32
    var win_h: Float32
    var scale: Float32

    def __init__(out self):
        self.ctx = Context()
        self.model = TrainerState()
        self.runtime = TrainerUiRuntime()
        self.run_name_edit = TextEditState(single_line=True)
        self.project_dir_edit = TextEditState(single_line=True)
        self.base_model_edit = TextEditState(single_line=True)
        self.vae_override_edit = TextEditState(single_line=True)
        self.dataset_path_edit = TextEditState(single_line=True)
        self.output_dir_edit = TextEditState(single_line=True)
        self.filename_pattern_edit = TextEditState(single_line=True)
        self.preset_json = String("")
        self.preset_status = String("No preset saved")
        self.font_id = 0
        self.win_w = _INIT_W
        self.win_h = _INIT_H
        self.scale = 1.0


def _row1(w: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(w)
    return r^


def _row2(a: Int32, b: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    return r^


def _row3(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    r.append(c)
    return r^


def _row4(a: Int32, b: Int32, c: Int32, d: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    r.append(c)
    r.append(d)
    return r^


def _row5(a: Int32, b: Int32, c: Int32, d: Int32, e: Int32) -> List[Int32]:
    var r = List[Int32]()
    r.append(a)
    r.append(b)
    r.append(c)
    r.append(d)
    r.append(e)
    return r^


def _clamp_scale(v: Float32) -> Float32:
    if v < 1.0:
        return 1.0
    if v > 1.8:
        return 1.8
    return v


def _scale_for(win_w: Float32, win_h: Float32) -> Float32:
    var sx = win_w / 1800.0
    var sy = win_h / 1100.0
    var s = sx
    if sy < s:
        s = sy
    return _clamp_scale(s)


def _px_scale(scale: Float32, value: Int32) -> Int32:
    return Int32(Float32(Int(value)) * scale + 0.5)


def _px(s: TrainerAppState, value: Int32) -> Int32:
    return _px_scale(s.scale, value)


def _nav_w(s: TrainerAppState) -> Int32:
    return _px(s, 250)


def _status_w(s: TrainerAppState) -> Int32:
    return _px(s, 360)


def _gap(s: TrainerAppState) -> Int32:
    return _px(s, 16)


def _pad(s: TrainerAppState) -> Int32:
    return _px(s, 18)


def _row_h(s: TrainerAppState) -> Int32:
    return _px(s, 32)


def _small_h(s: TrainerAppState) -> Int32:
    return _px(s, 22)


def _main_w(s: TrainerAppState) -> Int32:
    var w = Int32(s.win_w) - _nav_w(s) - _status_w(s) - _gap(s) * 2
    if w < _px(s, 620):
        return _px(s, 620)
    return w


def _apply_active_theme(mut s: TrainerAppState):
    var t = serenity_theme_at(Int(s.model.theme_index))
    s.ctx.theme.bg = t.colors.bg_default.copy()
    s.ctx.theme.fg = t.colors.text_default.copy()
    s.ctx.theme.primary = t.colors.accent_default.copy()
    s.ctx.theme.hover_bg = t.colors.widget_hovered_color.copy()
    s.ctx.theme.active_bg = t.colors.widget_active_bg_fill.copy()
    s.ctx.theme.border = t.colors.border_default.copy()
    s.ctx.theme.text = t.colors.text_default.copy()


def _apply_theme_to_context(mut ctx: Context, theme_index: Int32):
    var t = serenity_theme_at(Int(theme_index))
    ctx.theme.bg = t.colors.bg_default.copy()
    ctx.theme.fg = t.colors.text_default.copy()
    ctx.theme.primary = t.colors.accent_default.copy()
    ctx.theme.hover_bg = t.colors.widget_hovered_color.copy()
    ctx.theme.active_bg = t.colors.widget_active_bg_fill.copy()
    ctx.theme.border = t.colors.border_default.copy()
    ctx.theme.text = t.colors.text_default.copy()


def _sync_window_metrics(mut s: TrainerAppState):
    var win = Backend.window_size()
    if win.x <= 0.0 or win.y <= 0.0:
        win = Vec2(_INIT_W, _INIT_H)
    s.win_w = win.x
    s.win_h = win.y
    s.scale = _scale_for(win.x, win.y)

    if s.scale >= 1.45:
        s.ctx.theme.font_size_pt = Int32(24)
        s.ctx.theme.row_height = _px(s, 34)
        s.ctx.theme.padding = _px(s, 8)
        s.ctx.theme.spacing = _px(s, 7)
    elif s.scale >= 1.15:
        s.ctx.theme.font_size_pt = Int32(18)
        s.ctx.theme.row_height = _px(s, 30)
        s.ctx.theme.padding = _px(s, 7)
        s.ctx.theme.spacing = _px(s, 6)
    else:
        s.ctx.theme.font_size_pt = Int32(16)
        s.ctx.theme.row_height = Int32(28)
        s.ctx.theme.padding = Int32(6)
        s.ctx.theme.spacing = Int32(5)


def _draw_bg(mut s: TrainerAppState):
    var t = serenity_theme_at(Int(s.model.theme_index))
    var win_w = s.win_w
    var win_h = s.win_h
    var nw = Float32(Int(_nav_w(s)))
    var sw = Float32(Int(_status_w(s)))
    var top_h = Float32(Int(_px(s, 58)))
    ref ctx = s.ctx
    ctx.draw_rect(Rect(0.0, 0.0, win_w, win_h), t.colors.bg_default.copy())
    ctx.draw_rect(Rect(0.0, 0.0, nw, win_h), t.colors.bg_panel.copy())
    ctx.draw_rect(Rect(win_w - sw, 0.0, sw, win_h), t.colors.bg_panel.copy())
    ctx.draw_rect(Rect(nw, 0.0, win_w - nw - sw, top_h), t.colors.bg_panel.copy())


def _caption(mut ctx: Context, row_w: Int32, small_h: Int32, text: String):
    ctx.layout_row(_row1(row_w), small_h)
    label(ctx, text)


def _section_rule(mut ctx: Context, row_w: Int32, row_h: Int32, rule_h: Int32, title: String):
    ctx.layout_row(_row1(row_w), row_h)
    label(ctx, title)
    ctx.layout_row(_row1(row_w), rule_h)
    separator(ctx)


def _form_row(mut ctx: Context, label_w: Int32, value_w: Int32, row_h: Int32, name: String, value: String):
    ctx.layout_row(_row2(label_w, value_w), row_h)
    label(ctx, name)
    label(ctx, value)


def _form_edit_row(
    mut ctx: Context,
    label_w: Int32,
    value_w: Int32,
    row_h: Int32,
    name: String,
    id_str: String,
    mut value: String,
    mut edit_state: TextEditState,
) raises:
    ctx.layout_row(_row2(label_w, value_w), row_h)
    label(ctx, name)
    _ = text_edit(ctx, id_str, value, edit_state)


def _nav_button(mut s: TrainerAppState, section: Int32, text: String):
    if button(s.ctx, text):
        s.model.section_index = section


def _sidebar(mut s: TrainerAppState):
    var pad = _pad(s)
    var content_w = _nav_w(s) - pad * 2
    var row_h = _row_h(s)
    var small_h = _small_h(s)
    var h44 = _px(s, 44)
    var h18 = _px(s, 18)
    var h28 = _px(s, 28)
    ref ctx = s.ctx
    ctx.layout_row(_row3(pad, content_w, pad), h44)
    label(ctx, String(""))
    label(ctx, String("Mojo Trainer"))
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("v0.1 · pure Mojo"))
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), h18)
    label(ctx, String(""))
    separator(ctx)
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("CONFIGURE"))
    label(ctx, String(""))

    ctx.push_id_str(String("sidebar"))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Model")):
        s.model.section_index = TRAINER_SECTION_MODEL
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Dataset")):
        s.model.section_index = TRAINER_SECTION_DATASET
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Concepts")):
        s.model.section_index = TRAINER_SECTION_CONCEPTS
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Training")):
        s.model.section_index = TRAINER_SECTION_TRAINING
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Sampling")):
        s.model.section_index = TRAINER_SECTION_SAMPLING
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Backup")):
        s.model.section_index = TRAINER_SECTION_BACKUP
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Runs")):
        s.model.section_index = TRAINER_SECTION_RUNS
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if button(ctx, String("Logs")):
        s.model.section_index = TRAINER_SECTION_LOGS
    label(ctx, String(""))
    ctx.pop_id()

    ctx.layout_row(_row3(pad, content_w, pad), h28)
    label(ctx, String(""))
    separator(ctx)
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("PROJECT"))
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    label(ctx, s.model.project_dir.copy())
    label(ctx, String(""))


def _topbar(mut s: TrainerAppState) raises:
    var row_h = _row_h(s)
    var w = _main_w(s) - _pad(s) * 2
    var section_w = _px(s, 300)
    var theme_w = _px(s, 240)
    var button_w = _px(s, 165)
    var spacer = w - section_w - theme_w - button_w * 3 - _px(s, 24)
    if spacer < _px(s, 24):
        spacer = _px(s, 24)

    ref ctx = s.ctx
    ctx.layout_row(_row4(section_w, theme_w, spacer, button_w), row_h)
    label(ctx, String("SECTION · ") + s.model.section_label())
    if combobox(ctx, String("theme"), s.model.theme_options, s.model.theme_index, s.model.theme_open):
        _apply_theme_to_context(ctx, s.model.theme_index)
    label(ctx, String(""))
    if s.runtime.has_running:
        if s.runtime.paused:
            if button(ctx, String("Resume")):
                _ = trainer_resume(s.runtime)
        else:
            if button(ctx, String("Pause")):
                _ = trainer_pause(s.runtime)
    else:
        if button(ctx, String("Start training")):
            _ = trainer_submit_current(s.model, s.runtime)

    ctx.layout_row(_row4(section_w + theme_w + spacer, button_w, button_w, button_w), row_h)
    label(ctx, String("BASE · ") + s.model.base_model.copy())
    if button(ctx, String("Sample now")):
        _ = trainer_sample_now(s.runtime)
    if button(ctx, String("Save checkpoint")):
        _ = trainer_save_checkpoint_now(s.runtime)
    if s.runtime.has_running:
        if button(ctx, String("Stop")):
            trainer_cancel_all(s.runtime)
    else:
        label(ctx, String(""))

    var run_label_w = _px(s, 70)
    var run_edit_w = _px(s, 300)
    var preset_w = _px(s, 145)
    var status_w = w - run_label_w - run_edit_w - preset_w * 2 - _px(s, 24)
    if status_w < _px(s, 220):
        status_w = _px(s, 220)
    ctx.layout_row(_row5(run_label_w, run_edit_w, preset_w, preset_w, status_w), row_h)
    label(ctx, String("RUN"))
    _ = text_edit(ctx, String("run_name"), s.model.run_name, s.run_name_edit)
    if button(ctx, String("Save preset")):
        s.preset_json = trainer_preset_json_from_state(s.model)
        s.preset_status = String("Preset saved in memory")
        s.runtime.logs.append(String("preset saved"))
    if button(ctx, String("Load preset")):
        if s.preset_json.byte_length() == 0:
            s.preset_status = String("No preset to load")
        else:
            try:
                trainer_state_apply_preset_json(s.model, s.preset_json)
                _apply_theme_to_context(ctx, s.model.theme_index)
                s.preset_status = String("Preset loaded")
                s.runtime.logs.append(String("preset loaded"))
            except e:
                s.preset_status = String("Preset load failed: ") + String(e)
    label(ctx, s.preset_status.copy())


def _model_section(mut s: TrainerAppState) raises:
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    var w240 = _px(s, 240)
    var w300 = _px(s, 300)
    var w340 = _px(s, 340)
    var slider_w = _px(s, 470)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Base model"))
    ctx.layout_row(_row2(label_w, w300), row_h)
    label(ctx, String("Model type"))
    _ = combobox(ctx, String("model_type"), s.model.model_type_options, s.model.model_type_index, s.model.model_type_open)
    ctx.layout_row(_row2(label_w, w340), row_h)
    label(ctx, String("Architecture"))
    _ = combobox(ctx, String("architecture"), s.model.architecture_options, s.model.architecture_index, s.model.architecture_open)
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("Base checkpoint"), String("base_checkpoint"), s.model.base_model, s.base_model_edit)
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("VAE override"), String("vae_override"), s.model.vae_override, s.vae_override_edit)
    ctx.layout_row(_row2(label_w, w240), row_h)
    label(ctx, String("Precision"))
    _ = combobox(ctx, String("precision"), s.model.precision_options, s.model.precision_index, s.model.precision_open)
    ctx.layout_row(_row2(label_w, w300), row_h)
    label(ctx, String("Train text encoder"))
    _ = checkbox(ctx, String("Both TE1 and TE2"), s.model.train_text_encoder)

    _section_rule(ctx, rule_w, row_h, rule_h, String("LoRA parameters"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Network rank"))
    _ = slider(ctx, s.model.network_rank, 1.0, 256.0, String("rank"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Network alpha"))
    _ = slider(ctx, s.model.network_alpha, 1.0, 256.0, String("alpha"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Conv rank"))
    _ = slider(ctx, s.model.conv_rank, 0.0, 64.0, String("conv_rank"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Dropout"))
    _ = slider(ctx, s.model.dropout, 0.0, 0.5, String("dropout"))
    _form_row(ctx, label_w, form_value_w, row_h, String("Target modules"), String("attn · mlp · te1 · te2"))


def _dataset_section(mut s: TrainerAppState) raises:
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    var w240 = _px(s, 240)
    var w260 = _px(s, 260)
    var slider_w = _px(s, 470)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Dataset"))
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("Folder"), String("dataset_path"), s.model.dataset_path, s.dataset_path_edit)
    _form_row(ctx, label_w, form_value_w, row_h, String("Summary"), String(len(s.model.dataset_images)) + String(" images · ") + String(len(s.model.concepts)) + String(" concepts"))
    var max_rows = len(s.model.dataset_images)
    if max_rows > 6:
        max_rows = 6
    for i in range(max_rows):
        var img = s.model.dataset_images[i].copy()
        _form_row(
            ctx,
            label_w,
            form_value_w,
            row_h,
            img.name.copy(),
            String(img.width) + String("x") + String(img.height) + String(" · bucket ") + String(img.bucket_width) + String("x") + String(img.bucket_height),
        )
    _section_rule(ctx, rule_w, row_h, rule_h, String("Resolution & bucketing"))
    ctx.layout_row(_row2(label_w, w240), row_h)
    label(ctx, String("Target resolution"))
    if combobox(ctx, String("target_res"), s.model.target_resolution_options, s.model.target_resolution_index, s.model.target_resolution_open):
        assign_dataset_buckets(s.model)
    ctx.layout_row(_row2(label_w, w260), row_h)
    label(ctx, String("Bucket by aspect"))
    if checkbox(ctx, String("Enabled"), s.model.bucket_by_aspect):
        assign_dataset_buckets(s.model)
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Caption dropout"))
    _ = slider(ctx, s.model.caption_dropout, 0.0, 0.5, String("caption_dropout"))


def _concepts_section(mut s: TrainerAppState):
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Concepts"))
    for i in range(len(s.model.concepts)):
        var c = s.model.concepts[i].copy()
        _form_row(
            ctx,
            label_w,
            form_value_w,
            row_h,
            c.name.copy(),
            String(c.image_count) + String(" imgs · x") + String(c.repeats) + String(" repeats · ") + c.trigger_token.copy(),
        )


def _training_section(mut s: TrainerAppState):
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var w180 = _px(s, 180)
    var w280 = _px(s, 280)
    var w320 = _px(s, 320)
    var slider_w = _px(s, 470)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Schedule"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Epochs"))
    _ = slider(ctx, s.model.epochs, 1.0, 50.0, String("epochs"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Batch size"))
    _ = slider(ctx, s.model.batch_size, 1.0, 16.0, String("batch"))
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Grad accumulation"))
    _ = slider(ctx, s.model.grad_accum, 1.0, 16.0, String("grad_accum"))
    ctx.layout_row(_row2(label_w, w180), row_h)
    label(ctx, String("Max train steps"))
    _ = drag_value(ctx, s.model.max_train_steps, String("max_steps"), 10.0)

    _section_rule(ctx, rule_w, row_h, rule_h, String("Optimizer"))
    ctx.layout_row(_row2(label_w, w320), row_h)
    label(ctx, String("Optimizer"))
    _ = combobox(ctx, String("optimizer"), s.model.optimizer_options, s.model.optimizer_index, s.model.optimizer_open)
    ctx.layout_row(_row2(label_w, w320), row_h)
    label(ctx, String("Scheduler"))
    _ = combobox(ctx, String("scheduler"), s.model.scheduler_options, s.model.scheduler_index, s.model.scheduler_open)
    ctx.layout_row(_row2(label_w, w180), row_h)
    label(ctx, String("Learning rate"))
    _ = drag_value(ctx, s.model.learning_rate, String("lr"), 0.00001)

    _section_rule(ctx, rule_w, row_h, rule_h, String("Precision & memory"))
    ctx.layout_row(_row2(label_w, w280), row_h)
    label(ctx, String("Mixed precision"))
    _ = combobox(ctx, String("mixed_precision"), s.model.mixed_precision_options, s.model.mixed_precision_index, s.model.mixed_precision_open)
    ctx.layout_row(_row2(label_w, w320), row_h)
    label(ctx, String("Attention"))
    _ = combobox(ctx, String("attention"), s.model.attention_options, s.model.attention_index, s.model.attention_open)
    ctx.layout_row(_row2(label_w, w320), row_h)
    label(ctx, String("Gradient checkpointing"))
    _ = checkbox(ctx, String("On"), s.model.gradient_checkpointing)


def _sampling_section(mut s: TrainerAppState):
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    var w180 = _px(s, 180)
    var w330 = _px(s, 330)
    var slider_w = _px(s, 470)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Sampling settings"))
    ctx.layout_row(_row2(label_w, w180), row_h)
    label(ctx, String("Sample every"))
    _ = drag_value(ctx, s.model.sample_every_steps, String("sample_every"), 10.0)
    ctx.layout_row(_row2(label_w, w330), row_h)
    label(ctx, String("Sampler"))
    _ = combobox(ctx, String("sample_sampler"), s.model.sample_sampler_options, s.model.sample_sampler_index, s.model.sample_sampler_open)
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("CFG scale"))
    _ = slider(ctx, s.model.sample_cfg, 1.0, 15.0, String("sample_cfg"))
    _section_rule(ctx, rule_w, row_h, rule_h, String("Sample prompts"))
    for i in range(len(s.model.sample_prompts)):
        _form_row(ctx, label_w, form_value_w, row_h, String("Prompt ") + String(i + 1), s.model.sample_prompts[i].copy())


def _backup_section(mut s: TrainerAppState) raises:
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    var w180 = _px(s, 180)
    var slider_w = _px(s, 470)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Checkpoints"))
    ctx.layout_row(_row2(label_w, w180), row_h)
    label(ctx, String("Save every"))
    _ = drag_value(ctx, s.model.save_every_steps, String("save_every"), 10.0)
    ctx.layout_row(_row2(label_w, slider_w), row_h)
    label(ctx, String("Keep last N"))
    _ = slider(ctx, s.model.keep_last_n, 1.0, 50.0, String("keep_last"))
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("Project dir"), String("project_dir"), s.model.project_dir, s.project_dir_edit)
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("Output dir"), String("output_dir"), s.model.output_dir, s.output_dir_edit)
    _form_edit_row(ctx, label_w, form_value_w, row_h, String("Filename pattern"), String("filename_pattern"), s.model.filename_pattern, s.filename_pattern_edit)


def _runs_section(mut s: TrainerAppState):
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Runs"))
    if len(s.runtime.jobs.jobs) == 0:
        _form_row(ctx, label_w, form_value_w, row_h, String("idle"), String("No runs yet"))
    for i in range(len(s.runtime.jobs.jobs)):
        var job = s.runtime.jobs.jobs[i].copy()
        _form_row(
            ctx,
            label_w,
            form_value_w,
            row_h,
            String("#") + String(job.id),
            job.label.copy() + String(" · phase ") + String(job.phase) + String(" · step ") + String(job.current_step) + String("/") + String(job.total_steps),
        )


def _logs_section(mut s: TrainerAppState):
    var n = len(s.runtime.logs)
    var row_h = _row_h(s)
    var rule_w = _px(s, 260)
    var rule_h = _px(s, 4)
    var label_w = _px(s, 190)
    var form_value_w = _main_w(s) - _pad(s) * 2 - label_w - _px(s, 12)
    if form_value_w < _px(s, 260):
        form_value_w = _px(s, 260)
    ref ctx = s.ctx
    _section_rule(ctx, rule_w, row_h, rule_h, String("Logs"))
    if n == 0:
        _form_row(ctx, label_w, form_value_w, row_h, String("idle"), String("No trainer events yet"))
        return
    var start = 0
    if n > 14:
        start = n - 14
    for i in range(start, n):
        _form_row(ctx, label_w, form_value_w, row_h, String("log"), s.runtime.logs[i].copy())


def _main_section(mut s: TrainerAppState) raises:
    if s.model.section_index == TRAINER_SECTION_MODEL:
        _model_section(s)
    elif s.model.section_index == TRAINER_SECTION_DATASET:
        _dataset_section(s)
    elif s.model.section_index == TRAINER_SECTION_CONCEPTS:
        _concepts_section(s)
    elif s.model.section_index == TRAINER_SECTION_TRAINING:
        _training_section(s)
    elif s.model.section_index == TRAINER_SECTION_SAMPLING:
        _sampling_section(s)
    elif s.model.section_index == TRAINER_SECTION_BACKUP:
        _backup_section(s)
    elif s.model.section_index == TRAINER_SECTION_RUNS:
        _runs_section(s)
    else:
        _logs_section(s)


def _main_panel(mut s: TrainerAppState) raises:
    var pad = _pad(s)
    var content_w = _main_w(s) - pad * 2
    var h18 = _px(s, 18)
    var h76 = _px(s, 112)
    var h16 = _px(s, 16)
    var main_h = Int32(s.win_h) - _px(s, 166)
    s.ctx.layout_row(_row3(pad, content_w, pad), h18)
    label(s.ctx, String(""))
    label(s.ctx, String(""))
    label(s.ctx, String(""))

    s.ctx.layout_row(_row3(pad, content_w, pad), h76)
    label(s.ctx, String(""))
    s.ctx.begin_column()
    _topbar(s)
    s.ctx.end_column()
    label(s.ctx, String(""))

    s.ctx.layout_row(_row3(pad, content_w, pad), h16)
    label(s.ctx, String(""))
    separator(s.ctx)
    label(s.ctx, String(""))

    s.ctx.layout_row(_row3(pad, content_w, pad), main_h)
    label(s.ctx, String(""))
    s.ctx.begin_column()
    _main_section(s)
    s.ctx.end_column()
    label(s.ctx, String(""))


def _status_row(mut ctx: Context, label_w: Int32, value_w: Int32, row_h: Int32, name: String, value: String):
    ctx.layout_row(_row2(label_w, value_w), row_h)
    label(ctx, name)
    label(ctx, value)


def _status_rail(mut s: TrainerAppState):
    var pad = _pad(s)
    var row_h = _row_h(s)
    var small_h = _small_h(s)
    var content_w = _status_w(s) - pad * 2
    var status_label_w = _px(s, 130)
    var status_value_w = _status_w(s) - pad * 2 - status_label_w - _px(s, 10)
    var validation_text = trainer_validation_summary(trainer_validation_issues(s.model))
    var bridge_text = s.runtime.last_validation_summary.copy()
    var h24 = _px(s, 24)
    var h18 = _px(s, 18)
    var h12 = _px(s, 12)
    var h310 = _px(s, 310)
    var h120 = _px(s, 120)
    var h125 = _px(s, 125)
    ref ctx = s.ctx
    ctx.layout_row(_row3(pad, content_w, pad), h24)
    label(ctx, String(""))
    label(ctx, String(""))
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("LIVE STATUS"))
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), row_h)
    label(ctx, String(""))
    if s.runtime.has_running:
        if s.runtime.paused:
            label(ctx, String("Paused"))
        else:
            label(ctx, String("Running"))
    else:
        label(ctx, String("Idle"))
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), h18)
    label(ctx, String(""))
    progress_bar(ctx, trainer_progress_fraction(s.runtime))
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), h12)
    label(ctx, String(""))
    separator(ctx)
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), h310)
    label(ctx, String(""))
    ctx.begin_column()
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Step"), String(s.runtime.live.step) + String(" / ") + String(s.runtime.live.total_steps))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Epoch"), String(s.runtime.live.epoch) + String(" / ") + String(s.runtime.live.total_epochs))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Loss"), String(s.runtime.live.loss))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("LR"), String(s.runtime.live.learning_rate))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Speed"), String(s.runtime.live.speed_it_s) + String(" it/s"))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("ETA"), String(s.runtime.live.eta_secs) + String("s"))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Validation"), validation_text)
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Submit"), bridge_text)
    ctx.end_column()
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("ARTIFACTS"))
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), h120)
    label(ctx, String(""))
    ctx.begin_column()
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Samples"), String(len(s.runtime.samples)))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Checkpoints"), String(len(s.runtime.checkpoints)))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("Metrics"), String(len(s.runtime.metrics)))
    ctx.end_column()
    label(ctx, String(""))

    ctx.layout_row(_row3(pad, content_w, pad), small_h)
    label(ctx, String(""))
    label(ctx, String("HARDWARE"))
    label(ctx, String(""))
    ctx.layout_row(_row3(pad, content_w, pad), h125)
    label(ctx, String(""))
    ctx.begin_column()
    _status_row(ctx, status_label_w, status_value_w, row_h, String("GPU"), String(s.runtime.live.gpu_util) + String("% · ") + String(s.runtime.live.temp_c) + String("C"))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("VRAM"), String(s.runtime.live.vram_gb) + String(" / ") + String(s.runtime.live.vram_total_gb) + String(" GB"))
    _status_row(ctx, status_label_w, status_value_w, row_h, String("CPU"), String(s.runtime.live.cpu_util) + String("%"))
    ctx.end_column()
    label(ctx, String(""))


def _ui(mut s: TrainerAppState) raises:
    _draw_bg(s)
    var nav = _nav_w(s)
    var main = _main_w(s)
    var status = _status_w(s)
    var gap = _gap(s)
    var win_h = Int32(s.win_h)
    s.ctx.layout_row(_row5(nav, gap, main, gap, status), win_h)
    s.ctx.begin_column()
    _sidebar(s)
    s.ctx.end_column()
    label(s.ctx, String(""))
    s.ctx.begin_column()
    _main_panel(s)
    s.ctx.end_column()
    label(s.ctx, String(""))
    s.ctx.begin_column()
    _status_rail(s)
    s.ctx.end_column()


def _dispatch_triangles(mut cmd: CmdTriangles):
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def _render_command_buffer(mut ctx: Context) raises:
    var off: Int32 = 0
    var end_off = Int32(ctx.commands.byte_count())
    while off < end_off:
        var kind = ctx.commands.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = ctx.commands.read_jump_dst(off)
            if off <= prev_off:
                return
            continue
        var size = ctx.commands.size_at(off)
        if kind == CMD_RECT:
            var cmd = read_cmd_rect(ctx.commands, off)
            Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(ctx.commands, off)
            _ = Backend.draw_text(
                cmd.font_id, cmd.size_pt, cmd.text,
                cmd.pos.copy(), cmd.color.copy(),
            )
        elif kind == CMD_TRIANGLES:
            var cmd = read_cmd_triangles(ctx.commands, off)
            _dispatch_triangles(cmd)
        off = off + size


def _frame() -> None:
    var sp = retrieve_user_state[TrainerAppState]()
    if sp[].font_id == 0:
        sp[].font_id = Backend.load_font(String(""))
        sp[].ctx.theme.font_id = sp[].font_id
        _apply_active_theme(sp[])

    _sync_window_metrics(sp[])
    trainer_tick_and_apply(sp[].runtime)

    sp[].ctx.begin_frame(Vec2(sp[].win_w, sp[].win_h))
    Backend.frame_begin(sp[].ctx.theme.bg.copy())
    try:
        _ui(sp[])
    except e:
        print("MojoUI m9 trainer UI error:", String(e))
    sp[].ctx.end_frame()
    try:
        _render_command_buffer(sp[].ctx)
    except e:
        print("MojoUI m9 trainer walker error:", String(e))
    Backend.frame_end()


def main() raises:
    var state = TrainerAppState()
    var sp = UnsafePointer(to=state)
    store_user_state(sp)

    var rc = Backend.init(Int32(Int(_INIT_W)), Int32(Int(_INIT_H)), String("MojoUI m9 — Trainer"))
    if rc != 0:
        print("FAIL: Backend.init returned", rc)
        raise Error("init failed")

    print("Opening trainer UI. Backend is CPU stub; Start training drives normalized events.")
    Backend.run_blocking(_frame)
    print("PASS: m9 trainer UI exited. jobs=", len(state.runtime.jobs.jobs))
