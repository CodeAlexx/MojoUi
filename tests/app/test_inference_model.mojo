"""Pure (FFI-free, `mojo run`-able) tests for the M4 mock-worker model in
mojoui/app/inference_model.mojo. Exercises the worker state machine:

  - Generate → job promoted to running, generating=True (Started).
  - N ticks → current_step advances (Progress×N).
  - final tick → Done: history item, generating=False, result_ready.
  - Queue advance: second Generate while running waits, then promotes on Done.
  - Cancel mid-run: running dropped, no history, next queued promoted.

Run: cd /home/alex/MojoUI && pixi run test-inference-model
"""

from mojoui.app.inference_model import (
    InferenceState,
    QueueJob,
    HistoryItem,
    action_generate,
    action_cancel,
    tick_worker,
    progress_fraction,
    FRAMES_PER_STEP,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _run_to_step(mut s: InferenceState, target_steps: Int):
    """Tick enough frames to advance `target_steps` inference steps."""
    for _ in range(target_steps * FRAMES_PER_STEP):
        tick_worker(s)


def test_idle_tick_is_noop() raises:
    var s = InferenceState()
    _expect(not s.generating, "fresh state should be idle")
    tick_worker(s)
    _expect(not s.generating, "tick on idle state stays idle")
    _expect(progress_fraction(s) == 0.0, "idle progress is 0")
    print("PASS: idle tick is no-op")


def test_generate_starts() raises:
    var s = InferenceState()
    s.steps = 10.0
    action_generate(s)
    _expect(s.generating, "Generate should set generating=True")
    _expect(s.has_running, "Generate should promote a running job")
    _expect(s.current_step == 0, "current_step starts at 0")
    _expect(s.total_steps == 10, "total_steps = steps snapshot")
    _expect(len(s.queued) == 0, "single Generate leaves queue empty")
    _expect(s.running.steps == 10, "running job carries the steps snapshot")
    print("PASS: Generate → started")


def test_progress_advances() raises:
    var s = InferenceState()
    s.steps = 8.0
    action_generate(s)
    # advance exactly 3 steps
    _run_to_step(s, 3)
    _expect(s.current_step == 3, "3 step-worth of ticks → current_step 3")
    _expect(s.generating, "still generating mid-run")
    _expect(s.running.current_step == 3, "running mirror tracks current_step")
    var pf = progress_fraction(s)
    _expect(pf > 0.36 and pf < 0.39, "progress ~3/8")
    print("PASS: N ticks → progress")


def test_completes_to_done() raises:
    var s = InferenceState()
    s.steps = 5.0
    action_generate(s)
    _run_to_step(s, 5)
    _expect(not s.generating, "completed → generating=False")
    _expect(not s.has_running, "completed → no running job")
    _expect(s.result_ready, "completed → result_ready=True")
    _expect(len(s.history) == 1, "completed → one history item")
    _expect(progress_fraction(s) == 1.0, "completed progress = 1.0")
    print("PASS: final tick → Done")


def test_queue_advances() raises:
    var s = InferenceState()
    s.steps = 4.0
    action_generate(s)  # job 1 runs
    s.prompt = String("second prompt")
    action_generate(s)  # job 2 queued
    _expect(s.has_running, "first job running")
    _expect(len(s.queued) == 1, "second job queued behind running")
    var first_id = s.running.id
    # finish job 1
    _run_to_step(s, 4)
    _expect(s.has_running, "second job promoted after first completes")
    _expect(s.running.id != first_id, "running is now the second job")
    _expect(len(s.queued) == 0, "queue drained after promotion")
    _expect(len(s.history) == 1, "one item in history after first done")
    # finish job 2
    _run_to_step(s, 4)
    _expect(not s.has_running, "all jobs done")
    _expect(len(s.history) == 2, "both jobs in history")
    print("PASS: queue advance")


def test_cancel_mid_run() raises:
    var s = InferenceState()
    s.steps = 10.0
    action_generate(s)
    _run_to_step(s, 3)
    _expect(s.current_step == 3, "mid-run at step 3")
    action_cancel(s)
    _expect(not s.generating, "cancel clears generating")
    _expect(not s.has_running, "cancel drops running job")
    _expect(len(s.history) == 0, "cancel produces NO history item")
    print("PASS: cancel mid-run")


def test_cancel_promotes_queued() raises:
    var s = InferenceState()
    s.steps = 10.0
    action_generate(s)        # job 1 running
    s.prompt = String("queued one")
    action_generate(s)        # job 2 queued
    action_cancel(s)          # drop job 1, promote job 2
    _expect(s.has_running, "cancel promotes the next queued job")
    _expect(s.generating, "promoted job is generating")
    _expect(len(s.queued) == 0, "queue drained by promotion on cancel")
    _expect(len(s.history) == 0, "cancel never writes history")
    print("PASS: cancel promotes queued job")


def test_color_seed_deterministic_and_distinct() raises:
    var s = InferenceState()
    s.steps = 2.0
    s.seed = 42.0
    action_generate(s)
    var c1 = s.running.color_seed
    _run_to_step(s, 2)  # done; record history color
    var h1 = s.history[0].color_seed
    _expect(c1 == h1, "running color_seed carried to history item")
    # different prompt → (almost certainly) different color seed
    s.prompt = String("a totally different prompt string")
    action_generate(s)
    var c2 = s.running.color_seed
    _expect(c1 != c2, "distinct prompt yields distinct color seed")
    print("PASS: color seed deterministic + distinct")


def test_steps_clamped_to_min_one() raises:
    """Skeptic HIGH-1 regression: a sub-1 Float32 steps (truncates to 0) must
    NOT arm a degenerate zero-step job. action_generate clamps to >= 1."""
    var s = InferenceState()
    s.steps = 0.0
    action_generate(s)
    _expect(s.total_steps == 1, "steps=0.0 should clamp to total_steps=1")
    _expect(s.running.steps == 1, "running job steps clamped to 1")
    _expect(s.generating, "clamped job still arms generating")
    # And it should NOT instantly complete on the first tick boundary.
    var s2 = InferenceState()
    s2.steps = 0.9  # truncates to 0 before the clamp
    action_generate(s2)
    _expect(s2.total_steps == 1, "steps=0.9 should clamp to 1")
    print("PASS: steps clamped to >= 1")


def main() raises:
    test_idle_tick_is_noop()
    test_generate_starts()
    test_steps_clamped_to_min_one()
    test_progress_advances()
    test_completes_to_done()
    test_queue_advances()
    test_cancel_mid_run()
    test_cancel_promotes_queued()
    test_color_seed_deterministic_and_distinct()
    print("PASS: all 9 inference-model tests")
