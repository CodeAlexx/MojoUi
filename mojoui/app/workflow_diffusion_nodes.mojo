"""Comfy-style diffusion node executors."""

from mojoui.nodes.graph import Graph
from mojoui.nodes.node import Node
from mojoui.nodes.port import NVT_CLIP, NVT_CONDITIONING, NVT_MODEL, NVT_VAE
from mojoui.app.sampler_runtime import (
    LanPaintConfig,
    SamplerConfig,
    parse_sampler_kind,
    parse_scheduler_kind,
    run_lanpaint_sampler,
    run_sampler,
    text_conditioning_scalar,
)
from mojoui.app.workflow_types import (
    WorkflowExecutionResult,
    WorkflowLaunchAction,
    WorkflowValue,
    WV_CLIP,
    WV_CONDITIONING,
    WV_IMAGE,
    WV_LATENT,
    WV_MODEL,
    WV_NUMBER,
    WV_TEXT,
    WV_VAE,
    WLS_LAUNCHED,
    WLS_STAGED,
)
from mojoui.app.workflow_support import (
    add_handle_outputs,
    first_bool_field,
    first_i64_field,
    first_incoming_kind,
    first_int_field,
    first_number_field,
    first_output_name,
    first_string_field,
    incoming_value,
    lanpaint_sampler_gpu_command,
    node_matches,
    output_name_or,
    sampler_gpu_command,
    string_field,
)


def is_diffusion_node(node: Node) -> Bool:
    return (
        is_checkpoint_loader(node)
        or node_matches(node, String("unetloader"))
        or node_matches(node, String("cliploader"))
        or node_matches(node, String("dualcliploader"))
        or node_matches(node, String("triplecliploader"))
        or node_matches(node, String("vaeloader"))
        or is_lora_loader(node)
        or is_clip_text_encode(node)
        or node_matches(node, String("emptylatentimage"))
        or node_matches(node, String("latentfrombatch"))
        or node_matches(node, String("setlatentnoisemask"))
        or node_matches(node, String("vaeencode"))
        or node_matches(node, String("vaeencodeforinpaint"))
        or node_matches(node, String("controlnetloader"))
        or node_matches(node, String("controlnetapply"))
        or node_matches(node, String("controlnetapplyadvanced"))
        or is_sampler_node(node)
        or is_vae_decode(node)
        or node_matches(node, String("encode_prompt"))
    )


def execute_diffusion_node(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    if is_checkpoint_loader(node):
        return execute_checkpoint_loader(node, result)
    if node_matches(node, String("unetloader")):
        return execute_unet_loader(node, result)
    if node_matches(node, String("triplecliploader")):
        return execute_triple_clip_loader(node, result)
    if node_matches(node, String("dualcliploader")):
        return execute_dual_clip_loader(node, result)
    if node_matches(node, String("cliploader")):
        return execute_clip_loader(node, result)
    if node_matches(node, String("vaeloader")):
        return execute_vae_loader(node, result)
    if is_lora_loader(node):
        return execute_lora_loader(graph, node, result)
    if is_clip_text_encode(node) or node_matches(node, String("encode_prompt")):
        return execute_clip_text_encode(node, result)
    if node_matches(node, String("emptylatentimage")):
        return execute_empty_latent(node, result)
    if node_matches(node, String("latentfrombatch")) or node_matches(node, String("setlatentnoisemask")):
        return execute_latent_passthrough(graph, node, result)
    if node_matches(node, String("vaeencode")) or node_matches(node, String("vaeencodeforinpaint")):
        return execute_vae_encode(graph, node, result)
    if node_matches(node, String("controlnetloader")):
        return execute_controlnet_loader(node, result)
    if node_matches(node, String("controlnetapplyadvanced")):
        return execute_controlnet_apply_advanced(graph, node, result)
    if node_matches(node, String("controlnetapply")):
        return execute_controlnet_apply(graph, node, result)
    if is_sampler_node(node):
        return execute_sampler(graph, node, result)
    if is_vae_decode(node):
        return execute_vae_decode(graph, node, result)
    return False


def execute_checkpoint_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var ckpt = first_string_field(node, String("ckpt_name"), String("path"), String("widget_0"), String("model.safetensors"))
    add_handle_outputs(node, result, NVT_MODEL, WV_MODEL, String("model"), String("checkpoint:model:") + ckpt)
    add_handle_outputs(node, result, NVT_CLIP, WV_CLIP, String("clip"), String("checkpoint:clip:") + ckpt)
    add_handle_outputs(node, result, NVT_VAE, WV_VAE, String("vae"), String("checkpoint:vae:") + ckpt)
    result.add_log(String("checkpoint_loader ") + ckpt)
    return True


def execute_unet_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var name = first_string_field(node, String("unet_name"), String("path"), String("widget_0"), String("diffusion_model.safetensors"))
    var dtype = first_string_field(node, String("weight_dtype"), String("dtype"), String("widget_1"), String("default"))
    add_handle_outputs(node, result, NVT_MODEL, WV_MODEL, String("model"), String("unet:") + name + String(":") + dtype)
    result.add_log(String("unet_loader ") + name)
    return True


def execute_dual_clip_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var clip_a = first_string_field(node, String("clip_name1"), String("clip_l"), String("widget_0"), String("clip_l.safetensors"))
    var clip_b = first_string_field(node, String("clip_name2"), String("t5xxl"), String("widget_1"), String("t5xxl.safetensors"))
    var kind = first_string_field(node, String("type"), String("clip_type"), String("widget_2"), String("flux"))
    add_handle_outputs(node, result, NVT_CLIP, WV_CLIP, String("clip"), String("dual_clip:") + kind + String(":") + clip_a + String("+") + clip_b)
    result.add_log(String("dual_clip_loader ") + kind)
    return True


def execute_clip_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var clip = first_string_field(node, String("clip_name"), String("path"), String("widget_0"), String("clip.safetensors"))
    var kind = first_string_field(node, String("type"), String("clip_type"), String("widget_1"), String("stable_diffusion"))
    add_handle_outputs(node, result, NVT_CLIP, WV_CLIP, String("clip"), String("clip:") + kind + String(":") + clip)
    result.add_log(String("clip_loader ") + clip)
    return True


def execute_triple_clip_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var clip_a = first_string_field(node, String("clip_name1"), String("clip_l"), String("widget_0"), String("clip_l.safetensors"))
    var clip_b = first_string_field(node, String("clip_name2"), String("clip_g"), String("widget_1"), String("clip_g.safetensors"))
    var clip_c = first_string_field(node, String("clip_name3"), String("t5xxl"), String("widget_2"), String("t5xxl.safetensors"))
    add_handle_outputs(node, result, NVT_CLIP, WV_CLIP, String("clip"), String("triple_clip:") + clip_a + String("+") + clip_b + String("+") + clip_c)
    result.add_log(String("triple_clip_loader"))
    return True


def execute_vae_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var name = first_string_field(node, String("vae_name"), String("path"), String("widget_0"), String("vae.safetensors"))
    add_handle_outputs(node, result, NVT_VAE, WV_VAE, String("vae"), String("vae:") + name)
    result.add_log(String("vae_loader ") + name)
    return True


def execute_lora_loader(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var model = incoming_value(graph, result, node.id, String("model"))
    if model.kind != WV_MODEL:
        model = incoming_value(graph, result, node.id, String("MODEL"))
    var clip = incoming_value(graph, result, node.id, String("clip"))
    if clip.kind != WV_CLIP:
        clip = incoming_value(graph, result, node.id, String("CLIP"))
    var lora_name = first_string_field(node, String("lora_name"), String("lora_names"), String("widget_0"), String("lora.safetensors"))
    var strength = first_number_field(node, String("strength_model"), String("strength_01"), String("widget_1"), 1.0)
    var model_handle = model.text.copy()
    if model_handle.byte_length() == 0:
        model_handle = String("model:unbound")
    var clip_handle = clip.text.copy()
    if clip_handle.byte_length() == 0:
        clip_handle = String("clip:unbound")
    add_handle_outputs(
        node,
        result,
        NVT_MODEL,
        WV_MODEL,
        String("model"),
        model_handle + String("|lora:") + lora_name + String("@") + String(strength),
    )
    add_handle_outputs(
        node,
        result,
        NVT_CLIP,
        WV_CLIP,
        String("clip"),
        clip_handle + String("|lora:") + lora_name + String("@") + String(strength),
    )
    result.add_log(String("lora_loader ") + lora_name)
    return True


def execute_clip_text_encode(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var text = first_string_field(node, String("text"), String("prompt"), String("widget_0"), String(""))
    if text.byte_length() == 0:
        var text_g = string_field(node, String("text_g"), String(""))
        if text_g.byte_length() == 0:
            text_g = string_field(node, String("widget_6"), String(""))
        var text_l = string_field(node, String("text_l"), String(""))
        if text_l.byte_length() == 0:
            text_l = string_field(node, String("widget_7"), String(""))
        text = text_g.copy()
        if text.byte_length() > 0 and text_l.byte_length() > 0:
            text = text + String("\n")
        text = text + text_l
    var scalar = text_conditioning_scalar(text)
    result.add_value(WorkflowValue.conditioning_value(node.id, first_output_name(node, String("CONDITIONING")), text, scalar))
    result.add_log(String("clip_text_encode ") + String(text.byte_length()) + String(" bytes"))
    return True


def execute_empty_latent(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var width = first_int_field(node, String("width"), String("widget_0"), String(""), Int32(1024))
    var height = first_int_field(node, String("height"), String("widget_1"), String(""), Int32(1024))
    var batch = first_int_field(node, String("batch_size"), String("batch"), String("widget_2"), Int32(1))
    result.add_value(WorkflowValue.latent_value(node.id, first_output_name(node, String("LATENT")), width, height, batch, Int64(0), 0.0))
    result.add_log(String("empty_latent ") + String(width) + String("x") + String(height) + String(" batch=") + String(batch))
    return True


def execute_latent_passthrough(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var latent = incoming_value(graph, result, node.id, String("samples"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("latent"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("latent_image"))
    result.add_value(
        WorkflowValue.latent_value(
            node.id,
            first_output_name(node, String("LATENT")),
            latent.width,
            latent.height,
            latent.batch_size,
            latent.seed,
            latent.scalar,
        )
    )
    result.add_log(String("latent_passthrough ") + node.title)
    return True


def execute_vae_encode(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var image = incoming_value(graph, result, node.id, String("pixels"))
    if image.kind != WV_IMAGE:
        image = incoming_value(graph, result, node.id, String("image"))
    var width = image.width
    var height = image.height
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    var scalar = text_conditioning_scalar(image.path) * 0.5
    result.add_value(WorkflowValue.latent_value(node.id, first_output_name(node, String("LATENT")), width, height, 1, image.seed, scalar))
    result.add_log(String("vae_encode ") + String(width) + String("x") + String(height))
    return True


def execute_controlnet_loader(node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var name = first_string_field(node, String("control_net_name"), String("model_name"), String("widget_0"), String("controlnet.safetensors"))
    add_handle_outputs(node, result, NVT_MODEL, WV_MODEL, String("CONTROL_NET"), String("controlnet:") + name)
    result.add_log(String("controlnet_loader ") + name)
    return True


def execute_controlnet_apply(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var conditioning = incoming_value(graph, result, node.id, String("conditioning"))
    if conditioning.kind != WV_CONDITIONING:
        conditioning = incoming_value(graph, result, node.id, String("positive"))
    var strength = first_number_field(node, String("strength"), String("widget_0"), String(""), 1.0)
    var text = conditioning.text.copy()
    if text.byte_length() > 0:
        text = text + String("|controlnet@") + String(strength)
    result.add_value(
        WorkflowValue.conditioning_value(
            node.id,
            first_output_name(node, String("CONDITIONING")),
            text,
            conditioning.scalar + strength * 0.01,
        )
    )
    result.add_log(String("controlnet_apply strength=") + String(strength))
    return True


def execute_controlnet_apply_advanced(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var positive = incoming_value(graph, result, node.id, String("positive"))
    var negative = incoming_value(graph, result, node.id, String("negative"))
    var strength = first_number_field(node, String("strength"), String("widget_0"), String(""), 1.0)
    result.add_value(
        WorkflowValue.conditioning_value(
            node.id,
            String("positive"),
            positive.text + String("|controlnet@") + String(strength),
            positive.scalar + strength * 0.01,
        )
    )
    result.add_value(
        WorkflowValue.conditioning_value(
            node.id,
            String("negative"),
            negative.text + String("|controlnet@") + String(strength),
            negative.scalar + strength * 0.01,
        )
    )
    result.add_log(String("controlnet_apply_advanced strength=") + String(strength))
    return True


def execute_sampler(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var latent = incoming_value(graph, result, node.id, String("latent_image"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("latent"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("samples"))

    var positive = incoming_value(graph, result, node.id, String("positive"))
    if positive.kind != WV_CONDITIONING:
        positive = incoming_value(graph, result, node.id, String("cond"))
    var negative = incoming_value(graph, result, node.id, String("negative"))
    if negative.kind != WV_CONDITIONING:
        negative = incoming_value(graph, result, node.id, String("uncond"))

    var cfg = SamplerConfig()
    var is_lanpaint = node_matches(node, String("lanpaint"))
    var advanced = node_matches(node, String("ksampleradvanced")) or node_matches(node, String("swarmksampler"))
    if advanced:
        cfg.seed = first_i64_field(node, String("noise_seed"), String("seed"), String("widget_1"), Int64(0))
        if is_lanpaint:
            cfg.steps = first_int_field(node, String("steps"), String("widget_3"), String("widget_2"), Int32(20))
            cfg.cfg = first_number_field(node, String("cfg"), String("widget_4"), String("widget_3"), 7.0)
            cfg.sampler = parse_sampler_kind(first_string_field(node, String("sampler_name"), String("sampler"), String("widget_5"), String("euler")))
            cfg.scheduler = parse_scheduler_kind(first_string_field(node, String("scheduler"), String("widget_6"), String("widget_5"), String("normal")))
            cfg.start_at_step = first_int_field(node, String("start_at_step"), String("widget_7"), String("widget_6"), Int32(0))
            cfg.end_at_step = first_int_field(node, String("end_at_step"), String("widget_8"), String("widget_7"), Int32(10000))
        else:
            cfg.steps = first_int_field(node, String("steps"), String("widget_2"), String(""), Int32(20))
            cfg.cfg = first_number_field(node, String("cfg"), String("widget_3"), String(""), 7.0)
            cfg.sampler = parse_sampler_kind(first_string_field(node, String("sampler_name"), String("sampler"), String("widget_4"), String("euler")))
            cfg.scheduler = parse_scheduler_kind(first_string_field(node, String("scheduler"), String("widget_5"), String(""), String("normal")))
            cfg.start_at_step = first_int_field(node, String("start_at_step"), String("widget_6"), String(""), Int32(0))
            cfg.end_at_step = first_int_field(node, String("end_at_step"), String("widget_7"), String(""), Int32(10000))
        cfg.add_noise = first_bool_field(node, String("add_noise"), String("widget_0"), String(""), True)
    elif is_lanpaint and node_matches(node, String("samplercustomadvanced")):
        cfg.seed = first_i64_field(node, String("noise_seed"), String("seed"), String(""), Int64(0))
        cfg.steps = first_int_field(node, String("steps"), String("sampler_steps"), String(""), Int32(20))
        cfg.cfg = first_number_field(node, String("cfg"), String("guidance"), String(""), 1.0)
        cfg.sampler = parse_sampler_kind(first_string_field(node, String("sampler_name"), String("sampler_kind"), String(""), String("euler")))
        cfg.scheduler = parse_scheduler_kind(first_string_field(node, String("scheduler"), String("schedule"), String(""), String("normal")))
    elif is_lanpaint and node_matches(node, String("samplercustom")):
        cfg.seed = first_i64_field(node, String("noise_seed"), String("seed"), String("widget_1"), Int64(0))
        cfg.steps = first_int_field(node, String("steps"), String("sampler_steps"), String(""), Int32(20))
        cfg.cfg = first_number_field(node, String("cfg"), String("widget_3"), String(""), 8.0)
        cfg.sampler = parse_sampler_kind(first_string_field(node, String("sampler_name"), String("sampler_kind"), String(""), String("euler")))
        cfg.scheduler = parse_scheduler_kind(first_string_field(node, String("scheduler"), String("schedule"), String(""), String("normal")))
        cfg.add_noise = first_bool_field(node, String("add_noise"), String("widget_0"), String(""), True)
    else:
        cfg.seed = first_i64_field(node, String("seed"), String("noise_seed"), String("widget_0"), Int64(0))
        cfg.steps = first_int_field(node, String("steps"), String("widget_2"), String(""), Int32(20))
        cfg.cfg = first_number_field(node, String("cfg"), String("widget_3"), String(""), 7.0)
        cfg.sampler = parse_sampler_kind(first_string_field(node, String("sampler_name"), String("sampler"), String("widget_4"), String("euler")))
        cfg.scheduler = parse_scheduler_kind(first_string_field(node, String("scheduler"), String("widget_5"), String(""), String("normal")))
        cfg.denoise = first_number_field(node, String("denoise"), String("denoise_strength"), String("widget_6"), 1.0)

    var steps_in = incoming_value(graph, result, node.id, String("steps"))
    if steps_in.kind == WV_NUMBER:
        cfg.steps = _value_i32_or(steps_in, cfg.steps)
    var cfg_in = incoming_value(graph, result, node.id, String("cfg"))
    if cfg_in.kind == WV_NUMBER:
        cfg.cfg = _value_float_or(cfg_in, cfg.cfg)
    var sampler_in = incoming_value(graph, result, node.id, String("sampler_name"))
    if sampler_in.kind == WV_TEXT and sampler_in.text.byte_length() > 0:
        cfg.sampler = parse_sampler_kind(sampler_in.text)
    var scheduler_in = incoming_value(graph, result, node.id, String("scheduler"))
    if scheduler_in.kind == WV_TEXT and scheduler_in.text.byte_length() > 0:
        cfg.scheduler = parse_scheduler_kind(scheduler_in.text)

    var width = latent.width
    var height = latent.height
    var batch = latent.batch_size
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    if batch <= 0:
        batch = 1
    if is_lanpaint:
        var lanpaint = _lanpaint_config_from_node(node)
        var lanpaint_result = run_lanpaint_sampler(cfg, lanpaint, latent.scalar, positive.scalar, negative.scalar)
        var lanpaint_out_port = first_output_name(node, String("LATENT"))
        result.add_value(
            WorkflowValue.latent_value(
                node.id,
                lanpaint_out_port,
                width,
                height,
                batch,
                cfg.seed,
                lanpaint_result.final_scalar,
            )
        )
        if node_matches(node, String("samplercustom")):
            var denoised_port = output_name_or(node, String("denoised_output"), String("denoised_output"))
            if denoised_port != lanpaint_out_port:
                result.add_value(
                    WorkflowValue.latent_value(
                        node.id,
                        denoised_port,
                        width,
                        height,
                        batch,
                        cfg.seed,
                        lanpaint_result.denoised_scalar,
                    )
                )
        var lanpaint_status = WLS_STAGED
        if not result.device.dry_run:
            lanpaint_status = WLS_LAUNCHED
        var lanpaint_command = lanpaint_sampler_gpu_command(
            String("serenitymojo/samplers/lanpaint_sampler.mojo"),
            result.device,
            lanpaint_result.sampler_name,
            lanpaint_result.scheduler_name,
            cfg,
            lanpaint,
            width,
            height,
        )
        result.add_launch(
            WorkflowLaunchAction(
                node.id,
                String("lanpaint_sampler"),
                String("serenitymojo/samplers/lanpaint_sampler.mojo"),
                result.device.device_kind,
                result.device.device_index,
                lanpaint_command,
                String(""),
                lanpaint_status,
                result.device.dry_run,
            )
        )
        result.add_log(
            String("lanpaint_sampler ")
            + lanpaint_result.sampler_name
            + String("/")
            + lanpaint_result.scheduler_name
            + String(" steps=")
            + String(lanpaint_result.steps_run)
            + String(" inner=")
            + String(lanpaint_result.inner_iterations)
            + String(" mode=")
            + lanpaint.prompt_mode
        )
        return True

    var sampler_result = run_sampler(cfg, latent.scalar, positive.scalar, negative.scalar)
    var out_port = first_output_name(node, String("LATENT"))
    result.add_value(
        WorkflowValue.latent_value(
            node.id,
            out_port,
            width,
            height,
            batch,
            cfg.seed,
            sampler_result.final_scalar,
        )
    )
    var status = WLS_STAGED
    if not result.device.dry_run:
        status = WLS_LAUNCHED
    var command = sampler_gpu_command(String("serenitymojo/samplers/ksampler.mojo"), result.device, sampler_result.sampler_name, sampler_result.scheduler_name, cfg, width, height)
    result.add_launch(
        WorkflowLaunchAction(
            node.id,
            String("sampler"),
            String("serenitymojo/samplers/ksampler.mojo"),
            result.device.device_kind,
            result.device.device_index,
            command,
            String(""),
            status,
            result.device.dry_run,
        )
    )
    result.add_log(
        String("sampler ")
        + sampler_result.sampler_name
        + String("/")
        + sampler_result.scheduler_name
        + String(" steps=")
        + String(sampler_result.steps_run)
    )
    return True


def _lanpaint_config_from_node(node: Node) raises -> LanPaintConfig:
    var config = LanPaintConfig()
    if node_matches(node, String("ksampleradvanced")):
        config.num_steps = first_int_field(node, String("lanpaint_numsteps"), String("widget_10"), String("widget_7"), config.num_steps)
        config.lambda_scale = first_number_field(node, String("lanpaint_lambda"), String("widget_11"), String(""), config.lambda_scale)
        config.step_size = first_number_field(node, String("lanpaint_stepsize"), String("widget_12"), String(""), config.step_size)
        config.beta = first_number_field(node, String("lanpaint_beta"), String("widget_13"), String(""), config.beta)
        config.friction = first_number_field(node, String("lanpaint_friction"), String("widget_14"), String(""), config.friction)
        config.prompt_mode = first_string_field(node, String("lanpaint_promptmode"), String("widget_15"), String(""), config.prompt_mode)
        config.early_stop = first_int_field(node, String("lanpaint_earlystop"), String("widget_16"), String(""), config.early_stop)
        config.inpainting_mode = first_string_field(node, String("inpainting_mode"), String("widget_18"), String(""), config.inpainting_mode)
        config.inner_threshold = first_number_field(node, String("lanpaint_innerthreshold"), String("widget_19"), String(""), config.inner_threshold)
        config.inner_patience = first_int_field(node, String("lanpaint_innerpatience"), String("widget_20"), String(""), config.inner_patience)
    elif node_matches(node, String("samplercustomadvanced")):
        config.num_steps = first_int_field(node, String("lanpaint_numsteps"), String("widget_0"), String(""), config.num_steps)
        config.lambda_scale = first_number_field(node, String("lanpaint_lambda"), String("widget_1"), String(""), config.lambda_scale)
        config.step_size = first_number_field(node, String("lanpaint_stepsize"), String("widget_2"), String(""), config.step_size)
        config.beta = first_number_field(node, String("lanpaint_beta"), String("widget_3"), String(""), config.beta)
        config.friction = first_number_field(node, String("lanpaint_friction"), String("widget_4"), String(""), config.friction)
        config.prompt_mode = first_string_field(node, String("lanpaint_promptmode"), String("widget_5"), String(""), config.prompt_mode)
        config.early_stop = first_int_field(node, String("lanpaint_earlystop"), String("widget_6"), String(""), config.early_stop)
        config.inner_threshold = first_number_field(node, String("lanpaint_innerthreshold"), String("widget_8"), String(""), config.inner_threshold)
        config.inner_patience = first_int_field(node, String("lanpaint_innerpatience"), String("widget_9"), String(""), config.inner_patience)
    elif node_matches(node, String("samplercustom")):
        config.num_steps = first_int_field(node, String("lanpaint_numsteps"), String("widget_4"), String("widget_0"), config.num_steps)
        config.prompt_mode = first_string_field(node, String("lanpaint_promptmode"), String("widget_5"), String("widget_1"), config.prompt_mode)
    else:
        config.num_steps = first_int_field(node, String("lanpaint_numsteps"), String("widget_7"), String(""), config.num_steps)
        config.prompt_mode = first_string_field(node, String("lanpaint_promptmode"), String("widget_8"), String(""), config.prompt_mode)
        config.inpainting_mode = first_string_field(node, String("inpainting_mode"), String("widget_10"), String(""), config.inpainting_mode)
    if config.inner_patience < Int32(1):
        config.inner_patience = Int32(1)
    return config^


def execute_vae_decode(graph: Graph, node: Node, mut result: WorkflowExecutionResult) raises -> Bool:
    var latent = incoming_value(graph, result, node.id, String("samples"))
    if latent.kind != WV_LATENT:
        latent = incoming_value(graph, result, node.id, String("latent"))
    var width = latent.width
    var height = latent.height
    if width <= 0:
        width = result.request.width
    if height <= 0:
        height = result.request.height
    var path = first_string_field(node, String("output_path"), String("path"), String("filename_prefix"), String(""))
    if path.byte_length() == 0:
        path = String("/tmp/mojoui_vae_decode_") + String(node.id) + String(".png")
    result.add_value(WorkflowValue.image_path(node.id, first_output_name(node, String("IMAGE")), path, width, height, latent.seed))
    result.add_log(String("vae_decode ") + String(width) + String("x") + String(height))
    return True


def is_checkpoint_loader(node: Node) -> Bool:
    return (
        node_matches(node, String("load_checkpoint"))
        or node_matches(node, String("checkpointloadersimple"))
        or node_matches(node, String("checkpointloaderkj"))
        or node_matches(node, String("checkpoint loader"))
    )


def is_lora_loader(node: Node) -> Bool:
    return (
        node_matches(node, String("loraloader"))
        or node_matches(node, String("lora loader"))
        or node_matches(node, String("powerloraloader"))
        or node_matches(node, String("swarm_lora"))
    )


def is_clip_text_encode(node: Node) -> Bool:
    return (
        node_matches(node, String("cliptextencode"))
        or node_matches(node, String("clip text encode"))
    )


def is_sampler_node(node: Node) -> Bool:
    if node_matches(node, String("ksamplerconfig")):
        return False
    return (
        node_matches(node, String("k_sampler"))
        or node_matches(node, String("ksampler"))
        or node_matches(node, String("samplercustom"))
        or node_matches(node, String("swarmksampler"))
    )


def is_vae_decode(node: Node) -> Bool:
    return (
        node_matches(node, String("vae_decode"))
        or node_matches(node, String("vaedecode"))
        or node_matches(node, String("vae decode"))
    )


def _value_float_or(value: WorkflowValue, fallback: Float64) raises -> Float64:
    if value.text.byte_length() == 0:
        return fallback
    return Float64(value.text)


def _value_i32_or(value: WorkflowValue, fallback: Int32) raises -> Int32:
    if value.text.byte_length() == 0:
        return fallback
    return Int32(Float64(value.text))
