"""Pure tests for the Z-Image UI bridge.

The backend remains the default stub, so this test is CPU-only and does not
import serenitymojo or touch model weights.

Run: pixi run test-zimage-bridge
"""

from mojoui.app.inference_model import InferenceState
from mojoui.app.inference_zimage_bridge import (
    ZImageUiRuntime,
    zimage_submit_current,
    zimage_cancel_all,
    zimage_tick_and_apply,
    zimage_progress_fraction,
)
from mojoui.app.zimage_worker import ZW_FRAMES_PER_STEP
from mojoui.app._zimage_backend import backend_is_real


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _run_to_step(mut s: InferenceState, mut rt: ZImageUiRuntime, target_steps: Int):
    for _ in range(target_steps * ZW_FRAMES_PER_STEP):
        zimage_tick_and_apply(s, rt)


def test_stub_is_default() raises:
    _expect(not backend_is_real(), "bridge tests must run against stub backend")
    print("PASS: zimage bridge stub backend")


def test_submit_starts_worker() raises:
    var s = InferenceState()
    var rt = ZImageUiRuntime()
    s.steps = 6.0
    zimage_submit_current(s, rt)
    _expect(s.generating, "submit should mark state generating")
    _expect(s.has_running, "submit should mirror a running QueueJob")
    _expect(rt.worker.running, "worker should be running")
    _expect(s.total_steps == 6, "total_steps mirrors job steps")
    _expect(len(s.queued) == 0, "single submit leaves visible queue empty")
    _expect(len(rt.queued_jobs) == 0, "single submit leaves backend queue empty")
    print("PASS: submit starts worker")


def test_progress_and_done_copies_result() raises:
    var s = InferenceState()
    var rt = ZImageUiRuntime()
    s.steps = 3.0
    s.width = 64.0
    s.height = 32.0
    zimage_submit_current(s, rt)
    _run_to_step(s, rt, 2)
    _expect(s.current_step == 2, "two steps advanced")
    _expect(zimage_progress_fraction(s) > 0.65, "progress fraction advanced")
    _run_to_step(s, rt, 1)
    _expect(not s.generating, "done clears generating")
    _expect(not s.has_running, "done clears running")
    _expect(s.result_ready, "done marks result ready")
    _expect(len(s.history) == 1, "done adds one history item")
    _expect(rt.result_job_id == UInt64(1), "runtime records completed job id")
    _expect(rt.result_width == 64 and rt.result_height == 32, "runtime records result size")
    _expect(len(rt.result_pixels) == 64 * 32 * 4, "runtime copies RGBA result")
    print("PASS: progress then done copies result")


def test_queue_promotes_next_job() raises:
    var s = InferenceState()
    var rt = ZImageUiRuntime()
    s.steps = 2.0
    zimage_submit_current(s, rt)
    s.prompt = String("second job")
    zimage_submit_current(s, rt)
    _expect(s.has_running, "first job running")
    _expect(len(s.queued) == 1, "second job visible queued")
    _expect(len(rt.queued_jobs) == 1, "second job backend queued")
    var first_id = s.running.id
    _run_to_step(s, rt, 2)
    _expect(s.has_running, "second job promoted")
    _expect(s.running.id != first_id, "running id changed after promotion")
    _expect(len(s.queued) == 0, "visible queue drained")
    _expect(len(rt.queued_jobs) == 0, "backend queue drained")
    _run_to_step(s, rt, 2)
    _expect(len(s.history) == 2, "both jobs completed")
    print("PASS: queue promotes next job")


def test_cancel_drops_current_and_queue() raises:
    var s = InferenceState()
    var rt = ZImageUiRuntime()
    s.steps = 10.0
    zimage_submit_current(s, rt)
    s.prompt = String("queued")
    zimage_submit_current(s, rt)
    _expect(len(s.queued) == 1, "queued before cancel")
    zimage_cancel_all(s, rt)
    _expect(not s.generating, "cancel clears generating")
    _expect(not s.has_running, "cancel clears running")
    _expect(not rt.worker.running, "cancel stops worker")
    _expect(len(s.queued) == 0, "cancel drops visible queue")
    _expect(len(rt.queued_jobs) == 0, "cancel drops backend queue")
    _expect(len(s.history) == 0, "cancel writes no history")
    print("PASS: cancel drops current and queue")


def main() raises:
    test_stub_is_default()
    test_submit_starts_worker()
    test_progress_and_done_copies_result()
    test_queue_promotes_next_job()
    test_cancel_drops_current_and_queue()
    print("PASS: zimage UI bridge tests (5 tests)")
