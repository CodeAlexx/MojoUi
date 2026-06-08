"""Pure-Mojo sampler runtime contracts for Comfy-style graph execution.

This module intentionally keeps the runtime value scalar-sized. The executor
uses it as a deterministic denoise contract and GPU launch planner; production
tensor backends can replace the scalar update while preserving sampler names,
schedules, seeds, and graph-facing value flow.
"""

comptime SamplerKind = Int32

comptime SAMPLER_EULER: SamplerKind = 0
comptime SAMPLER_EULER_ANCESTRAL: SamplerKind = 1
comptime SAMPLER_DDIM: SamplerKind = 2
comptime SAMPLER_DPMPP_2M: SamplerKind = 3

comptime SchedulerKind = Int32

comptime SCHED_NORMAL: SchedulerKind = 0
comptime SCHED_KARRAS: SchedulerKind = 1
comptime SCHED_EXPONENTIAL: SchedulerKind = 2
comptime SCHED_SIMPLE: SchedulerKind = 3


struct SamplerConfig(Copyable, Movable):
    var sampler: SamplerKind
    var scheduler: SchedulerKind
    var steps: Int32
    var cfg: Float64
    var denoise: Float64
    var seed: Int64
    var start_at_step: Int32
    var end_at_step: Int32
    var add_noise: Bool

    def __init__(out self):
        self.sampler = SAMPLER_EULER
        self.scheduler = SCHED_NORMAL
        self.steps = Int32(20)
        self.cfg = 7.0
        self.denoise = 1.0
        self.seed = Int64(0)
        self.start_at_step = Int32(0)
        self.end_at_step = Int32(10000)
        self.add_noise = True


struct SamplerRunResult(Copyable, Movable):
    var final_scalar: Float64
    var steps_run: Int32
    var sampler_name: String
    var scheduler_name: String
    var first_sigma: Float64
    var last_sigma: Float64
    var trace_hash: Float64
    var seed: Int64

    def __init__(out self):
        self.final_scalar = 0.0
        self.steps_run = Int32(0)
        self.sampler_name = String("")
        self.scheduler_name = String("")
        self.first_sigma = 0.0
        self.last_sigma = 0.0
        self.trace_hash = 0.0
        self.seed = Int64(0)


struct LanPaintConfig(Copyable, Movable):
    var num_steps: Int32
    var lambda_scale: Float64
    var step_size: Float64
    var beta: Float64
    var friction: Float64
    var prompt_mode: String
    var early_stop: Int32
    var inner_threshold: Float64
    var inner_patience: Int32
    var inpainting_mode: String

    def __init__(out self):
        self.num_steps = Int32(5)
        self.lambda_scale = 16.0
        self.step_size = 0.2
        self.beta = 1.0
        self.friction = 15.0
        self.prompt_mode = String("Image First")
        self.early_stop = Int32(1)
        self.inner_threshold = 0.0
        self.inner_patience = Int32(1)
        self.inpainting_mode = String("Image Inpainting")


struct LanPaintRunResult(Copyable, Movable):
    var final_scalar: Float64
    var denoised_scalar: Float64
    var steps_run: Int32
    var inner_iterations: Int32
    var early_stop_count: Int32
    var sampler_name: String
    var scheduler_name: String
    var first_sigma: Float64
    var last_sigma: Float64
    var trace_hash: Float64
    var seed: Int64

    def __init__(out self):
        self.final_scalar = 0.0
        self.denoised_scalar = 0.0
        self.steps_run = Int32(0)
        self.inner_iterations = Int32(0)
        self.early_stop_count = Int32(0)
        self.sampler_name = String("")
        self.scheduler_name = String("")
        self.first_sigma = 0.0
        self.last_sigma = 0.0
        self.trace_hash = 0.0
        self.seed = Int64(0)


def parse_sampler_kind(name: String) -> SamplerKind:
    var key = _normalized_key(name)
    if key == String("eulera") or key == String("eulerancestral"):
        return SAMPLER_EULER_ANCESTRAL
    if key == String("ddim"):
        return SAMPLER_DDIM
    if (
        key == String("dpmpp2m")
        or key == String("dpm2m")
        or key == String("dpmpp2msde")
        or key == String("dpmpp2malt")
    ):
        return SAMPLER_DPMPP_2M
    return SAMPLER_EULER


def sampler_kind_name(kind: SamplerKind) -> String:
    if kind == SAMPLER_EULER_ANCESTRAL:
        return String("euler_ancestral")
    if kind == SAMPLER_DDIM:
        return String("ddim")
    if kind == SAMPLER_DPMPP_2M:
        return String("dpmpp_2m")
    return String("euler")


def parse_scheduler_kind(name: String) -> SchedulerKind:
    var key = _normalized_key(name)
    if key == String("karras"):
        return SCHED_KARRAS
    if key == String("exponential") or key == String("exponentialkarras"):
        return SCHED_EXPONENTIAL
    if key == String("simple") or key == String("sgmuniform") or key == String("uniform"):
        return SCHED_SIMPLE
    return SCHED_NORMAL


def scheduler_kind_name(kind: SchedulerKind) -> String:
    if kind == SCHED_KARRAS:
        return String("karras")
    if kind == SCHED_EXPONENTIAL:
        return String("exponential")
    if kind == SCHED_SIMPLE:
        return String("simple")
    return String("normal")


def text_conditioning_scalar(text: String) -> Float64:
    """Stable small scalar used by tests and dry-run graph execution."""
    var h = UInt64(1469598103934665603)
    var ptr = text.unsafe_ptr()
    for i in range(text.byte_length()):
        h = h ^ UInt64(ptr[i])
        h = h * UInt64(1099511628211)
    var bucket = Int64(h & UInt64(0xFFFF))
    return Float64(bucket) / 65535.0


def build_sigmas(scheduler: SchedulerKind, steps: Int32, denoise: Float64) -> List[Float64]:
    var safe_steps = steps
    if safe_steps < Int32(1):
        safe_steps = Int32(1)
    var scale = _clamp01(denoise)
    var sigmas = List[Float64]()
    for i in range(Int(safe_steps) + 1):
        var t = Float64(i) / Float64(safe_steps)
        var q = 1.0 - t
        var sigma = scale * q
        if scheduler == SCHED_KARRAS:
            sigma = scale * q * q * (3.0 - 2.0 * q)
        elif scheduler == SCHED_EXPONENTIAL:
            sigma = scale * q * q * q
        elif scheduler == SCHED_SIMPLE:
            if i == Int(safe_steps):
                sigma = 0.0
            else:
                sigma = scale / (1.0 + Float64(i))
        if sigma < 0.0:
            sigma = 0.0
        sigmas.append(sigma)
    return sigmas^


def sampler_step_value(
    sampler: SamplerKind,
    latent: Float64,
    positive: Float64,
    negative: Float64,
    sigma: Float64,
    sigma_next: Float64,
    step_index: Int32,
    cfg: Float64,
    seed: Int64,
) -> Float64:
    var guided = negative + (positive - negative) * cfg
    var delta = sigma - sigma_next
    if delta < 0.0:
        delta = -delta
    var denom = 1.0 + sigma
    if denom <= 0.000001:
        denom = 0.000001
    var denoised = latent - guided * sigma / denom
    if sampler == SAMPLER_EULER_ANCESTRAL:
        var noise = _seed_noise(seed, step_index) * delta * 0.05
        return latent + (denoised - latent) * delta + noise
    if sampler == SAMPLER_DDIM:
        var amount = delta / denom
        if amount > 1.0:
            amount = 1.0
        return latent * (1.0 - amount) + denoised * amount
    if sampler == SAMPLER_DPMPP_2M:
        var midpoint = (sigma + sigma_next) * 0.5
        var mid_denom = 1.0 + midpoint
        if mid_denom <= 0.000001:
            mid_denom = 0.000001
        var corrected = latent - guided * midpoint / mid_denom
        return latent + (corrected - latent) * delta * 1.15
    return latent + (denoised - latent) * delta


def run_sampler(
    config: SamplerConfig,
    latent_scalar: Float64,
    positive_scalar: Float64,
    negative_scalar: Float64,
) -> SamplerRunResult:
    var sigmas = build_sigmas(config.scheduler, config.steps, config.denoise)
    var total_steps = Int32(len(sigmas) - 1)
    var start = config.start_at_step
    if start < Int32(0):
        start = Int32(0)
    if start > total_steps:
        start = total_steps
    var end = config.end_at_step
    if end <= Int32(0) or end > total_steps:
        end = total_steps
    if end < start:
        end = start

    var x = latent_scalar
    if config.add_noise:
        x = x + _seed_noise(config.seed, Int32(0)) * sigmas[Int(start)] * 0.1

    var trace = 0.0
    var ran = Int32(0)
    for i in range(Int(start), Int(end)):
        x = sampler_step_value(
            config.sampler,
            x,
            positive_scalar,
            negative_scalar,
            sigmas[i],
            sigmas[i + 1],
            Int32(i),
            config.cfg,
            config.seed,
        )
        trace = trace * 0.875 + x * 0.125 + Float64(i) * 0.0001
        ran = ran + Int32(1)

    var result = SamplerRunResult()
    result.final_scalar = x
    result.steps_run = ran
    result.sampler_name = sampler_kind_name(config.sampler)
    result.scheduler_name = scheduler_kind_name(config.scheduler)
    result.first_sigma = sigmas[Int(start)]
    result.last_sigma = sigmas[Int(end)]
    result.trace_hash = trace
    result.seed = config.seed
    return result^


def run_lanpaint_sampler(
    config: SamplerConfig,
    lanpaint: LanPaintConfig,
    latent_scalar: Float64,
    positive_scalar: Float64,
    negative_scalar: Float64,
) -> LanPaintRunResult:
    var sigmas = build_sigmas(config.scheduler, config.steps, config.denoise)
    var total_steps = Int32(len(sigmas) - 1)
    var start = config.start_at_step
    if start < Int32(0):
        start = Int32(0)
    if start > total_steps:
        start = total_steps
    var end = config.end_at_step
    if end <= Int32(0) or end > total_steps:
        end = total_steps
    if end < start:
        end = start

    var x = latent_scalar
    if config.add_noise:
        x = x + _seed_noise(config.seed, Int32(0)) * sigmas[Int(start)] * 0.1

    var prompt_guidance = config.cfg
    if _normalized_key(lanpaint.prompt_mode) == String("promptfirst"):
        prompt_guidance = -0.5
    var prompt_target = negative_scalar + (positive_scalar - negative_scalar) * prompt_guidance

    var trace = 0.0
    var ran = Int32(0)
    var inner_total = Int32(0)
    var early_total = Int32(0)
    var denoised = x
    for i in range(Int(start), Int(end)):
        var sigma = sigmas[i]
        var sigma_next = sigmas[i + 1]
        var remaining = total_steps - Int32(i)
        var inner_limit = lanpaint.num_steps
        if inner_limit < Int32(0):
            inner_limit = Int32(0)
        if lanpaint.early_stop > Int32(0) and remaining <= lanpaint.early_stop:
            inner_limit = Int32(0)

        if inner_limit > Int32(0):
            var x_t = x
            var velocity = 0.0
            var stable_count = Int32(0)
            var abt = _clamp01(1.0 - sigma)
            var step_amount = lanpaint.step_size * (1.0 - abt)
            if step_amount <= 0.000001:
                step_amount = 0.000001
            var known_weight = _clamp01(0.35 + sigma * 0.35)
            var unknown_weight = 1.0 - known_weight
            var friction_keep = 1.0 - _clamp01(lanpaint.friction * 0.02)
            var beta = lanpaint.beta
            if beta <= 0.000001:
                beta = 0.000001

            for j in range(Int(inner_limit)):
                var prev = x_t
                var base_denoised = sampler_step_value(
                    config.sampler,
                    x_t,
                    positive_scalar,
                    negative_scalar,
                    sigma,
                    sigma_next,
                    Int32(i),
                    config.cfg,
                    config.seed,
                )
                var score_prompt = -(x_t - prompt_target)
                var score_known = -(1.0 + lanpaint.lambda_scale) * (x_t - latent_scalar) + lanpaint.lambda_scale * (x_t - base_denoised)
                var score = score_prompt * unknown_weight * beta + score_known * known_weight
                velocity = velocity * friction_keep + score * step_amount
                x_t = x_t + velocity * step_amount
                inner_total = inner_total + Int32(1)
                if lanpaint.inner_threshold > 0.0:
                    var delta = _abs64(x_t - prev)
                    if delta <= lanpaint.inner_threshold:
                        stable_count = stable_count + Int32(1)
                    else:
                        stable_count = Int32(0)
                    if stable_count > lanpaint.inner_patience:
                        early_total = early_total + Int32(1)
                        break
                trace = trace * 0.9375 + x_t * 0.0625 + Float64(j) * 0.00001
            x = x_t

        denoised = sampler_step_value(
            config.sampler,
            x,
            positive_scalar,
            negative_scalar,
            sigma,
            sigma_next,
            Int32(i),
            config.cfg,
            config.seed,
        )
        x = denoised
        trace = trace * 0.875 + x * 0.125 + Float64(i) * 0.0001
        ran = ran + Int32(1)

    var result = LanPaintRunResult()
    result.final_scalar = x
    result.denoised_scalar = denoised
    result.steps_run = ran
    result.inner_iterations = inner_total
    result.early_stop_count = early_total
    result.sampler_name = sampler_kind_name(config.sampler)
    result.scheduler_name = scheduler_kind_name(config.scheduler)
    result.first_sigma = sigmas[Int(start)]
    result.last_sigma = sigmas[Int(end)]
    result.trace_hash = trace
    result.seed = config.seed
    return result^


def _seed_noise(seed: Int64, step_index: Int32) -> Float64:
    var x = seed + Int64(step_index) * Int64(6361) + Int64(17)
    if x < Int64(0):
        x = -x
    var bucket = x % Int64(9973)
    return Float64(bucket) / 9973.0 - 0.5


def _clamp01(v: Float64) -> Float64:
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def _abs64(v: Float64) -> Float64:
    if v < 0.0:
        return -v
    return v


def _normalized_key(s: String) -> String:
    var out = List[UInt8](capacity=s.byte_length())
    var ptr = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var b = ptr[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            b = b + UInt8(0x20)
        if (
            b == UInt8(0x20)
            or b == UInt8(0x5F)
            or b == UInt8(0x2D)
            or b == UInt8(0x2B)
            or b == UInt8(0x2E)
        ):
            continue
        out.append(b)
    return String(unsafe_from_utf8=out^)
