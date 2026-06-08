"""Smoke tests for pure-Mojo sampler stepping."""

from mojoui.app.sampler_runtime import (
    SAMPLER_DDIM,
    SAMPLER_DPMPP_2M,
    SAMPLER_EULER,
    SAMPLER_EULER_ANCESTRAL,
    SCHED_EXPONENTIAL,
    SCHED_KARRAS,
    SCHED_NORMAL,
    LanPaintConfig,
    SamplerConfig,
    build_sigmas,
    parse_sampler_kind,
    parse_scheduler_kind,
    run_lanpaint_sampler,
    run_sampler,
    sampler_kind_name,
    scheduler_kind_name,
    text_conditioning_scalar,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _abs(x: Float64) -> Float64:
    if x < 0.0:
        return -x
    return x


def _near(a: Float64, b: Float64) -> Bool:
    return _abs(a - b) <= 1.0e-9


def test_sampler_aliases() raises:
    _expect(parse_sampler_kind(String("euler")) == SAMPLER_EULER, "euler alias")
    _expect(parse_sampler_kind(String("euler_ancestral")) == SAMPLER_EULER_ANCESTRAL, "euler ancestral alias")
    _expect(parse_sampler_kind(String("DPM++ 2M")) == SAMPLER_DPMPP_2M, "dpmpp alias")
    _expect(parse_sampler_kind(String("ddim")) == SAMPLER_DDIM, "ddim alias")
    _expect(sampler_kind_name(SAMPLER_DPMPP_2M) == String("dpmpp_2m"), "dpmpp canonical name")
    _expect(parse_scheduler_kind(String("karras")) == SCHED_KARRAS, "karras alias")
    _expect(parse_scheduler_kind(String("exponential")) == SCHED_EXPONENTIAL, "exponential alias")
    _expect(scheduler_kind_name(SCHED_NORMAL) == String("normal"), "normal canonical name")
    print("PASS: sampler aliases")


def test_sigmas_descend() raises:
    var sigmas = build_sigmas(SCHED_KARRAS, Int32(4), 1.0)
    _expect(len(sigmas) == 5, "4 steps should produce 5 sigmas")
    _expect(sigmas[0] == 1.0, "first sigma should be denoise scale")
    _expect(sigmas[4] == 0.0, "last sigma should be zero")
    for i in range(4):
        _expect(sigmas[i] >= sigmas[i + 1], "sigmas should descend")
    print("PASS: sigma schedule descends")


def test_sampler_runs_are_deterministic() raises:
    var cfg = SamplerConfig()
    cfg.sampler = SAMPLER_EULER
    cfg.scheduler = SCHED_NORMAL
    cfg.steps = Int32(8)
    cfg.cfg = 7.0
    cfg.seed = Int64(123)
    var pos = text_conditioning_scalar(String("polished cinematic robot"))
    var neg = text_conditioning_scalar(String("blur low detail"))
    var a = run_sampler(cfg, 0.0, pos, neg)
    var b = run_sampler(cfg, 0.0, pos, neg)
    _expect(_near(a.final_scalar, b.final_scalar), "same config should be deterministic")
    _expect(a.steps_run == Int32(8), "all steps should run")

    cfg.sampler = SAMPLER_DDIM
    var c = run_sampler(cfg, 0.0, pos, neg)
    _expect(not _near(a.final_scalar, c.final_scalar), "ddim should differ from euler")
    print("PASS: deterministic sampler runs")


def test_lanpaint_sampler_runs_inner_loop() raises:
    var cfg = SamplerConfig()
    cfg.steps = Int32(6)
    cfg.cfg = 4.0
    cfg.seed = Int64(99)
    var lanpaint = LanPaintConfig()
    lanpaint.num_steps = Int32(3)
    lanpaint.lambda_scale = 8.0
    lanpaint.step_size = 0.15
    lanpaint.prompt_mode = String("Prompt First")
    var pos = text_conditioning_scalar(String("clean inpaint detail"))
    var neg = text_conditioning_scalar(String("blur artifacts"))
    var result = run_lanpaint_sampler(cfg, lanpaint, 0.25, pos, neg)
    _expect(result.steps_run == Int32(6), "LanPaint should run outer sampler steps")
    _expect(result.inner_iterations > Int32(0), "LanPaint should run inner iterations")
    _expect(result.sampler_name == String("euler"), "LanPaint should preserve sampler name")
    _expect(result.scheduler_name == String("normal"), "LanPaint should preserve scheduler name")

    lanpaint.num_steps = Int32(0)
    var no_inner = run_lanpaint_sampler(cfg, lanpaint, 0.25, pos, neg)
    _expect(no_inner.inner_iterations == Int32(0), "LanPaint NumSteps=0 should skip inner loop")
    print("PASS: LanPaint sampler inner loop")


def main() raises:
    test_sampler_aliases()
    test_sigmas_descend()
    test_sampler_runs_are_deterministic()
    test_lanpaint_sampler_runs_inner_loop()
    print("PASS: all 4 sampler-runtime tests")
