"""Pure (FFI-free, `mojo run`-able) tests for the real Z-Image worker state
machine in mojoui/app/zimage_worker.mojo. The serenitymojo backend is gated
off (stub) so these run in MojoUI's env with no GPU.

Mirrors the worker/zimage.rs protocol:
  - start → Started event, running, total_steps from job (honoring overrides).
  - N ticks → Progress×N, current_step advances.
  - final tick → Done: stub result attached, running=False, done=True.
  - cancel mid-run → Failed{"cancelled"}, no Done.
  - param honoring: steps/cfg fall back to Base defaults only when 0/≤0.

Run: pixi run test-zimage-worker
"""

from mojoui.app.zimage_worker import (
    ZImageWorker,
    ZImageJob,
    zimage_start,
    zimage_cancel,
    zimage_tick,
    zimage_progress_fraction,
    zimage_drain_event_kinds,
    ZW_STARTED,
    ZW_PROGRESS,
    ZW_DONE,
    ZW_FAILED,
    ZW_FRAMES_PER_STEP,
    ZW_DEFAULT_STEPS,
    ZW_DEFAULT_CFG,
)
from mojoui.app._zimage_backend import backend_is_real


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _job(steps: Int, cfg: Float32) -> ZImageJob:
    return ZImageJob(
        1, String("a cat"), String("blurry"), steps, cfg, 42, 1024, 1024, 12345
    )


def _run_to_step(mut w: ZImageWorker, target_steps: Int):
    for _ in range(target_steps * ZW_FRAMES_PER_STEP):
        zimage_tick(w)


def test_stub_is_default() raises:
    _expect(not backend_is_real(), "real backend must be OFF by default (stub)")
    print("PASS: stub backend is the default")


def test_start_emits_started() raises:
    var w = ZImageWorker()
    zimage_start(w, _job(10, 4.0))
    _expect(w.running, "start should set running")
    _expect(w.total_steps == 10, "total_steps from job")
    var kinds = zimage_drain_event_kinds(w)
    _expect(len(kinds) == 1 and kinds[0] == ZW_STARTED, "first event is Started")
    print("PASS: start → Started")


def test_progress_then_done() raises:
    var w = ZImageWorker()
    zimage_start(w, _job(5, 4.0))
    _run_to_step(w, 5)
    _expect(w.done, "should be done after all steps")
    _expect(not w.running, "not running after done")
    _expect(w.has_result, "stub result attached on done")
    _expect(w.result.ok, "stub result ok")
    _expect(w.result.width == 1024 and w.result.height == 1024, "result size")
    _expect(len(w.result.pixels) == 1024 * 1024 * 4, "RGBA8 buffer length")
    var kinds = zimage_drain_event_kinds(w)
    # Started + 5 Progress + Done == 7
    _expect(len(kinds) == 7, "Started + 5 Progress + Done")
    _expect(kinds[0] == ZW_STARTED, "first Started")
    _expect(kinds[len(kinds) - 1] == ZW_DONE, "last Done")
    var progress = 0
    for i in range(len(kinds)):
        if kinds[i] == ZW_PROGRESS:
            progress += 1
    _expect(progress == 5, "exactly 5 Progress events")
    print("PASS: Progress×5 → Done")


def test_cancel_mid_run() raises:
    var w = ZImageWorker()
    zimage_start(w, _job(20, 4.0))
    _run_to_step(w, 3)  # advance a few steps
    _expect(w.running, "still running before cancel")
    zimage_cancel(w)
    zimage_tick(w)  # next tick honors the cancel between steps
    _expect(not w.running, "cancelled stops running")
    _expect(w.failed, "cancel marks failed")
    _expect(not w.done, "cancel does not mark done")
    _expect(not w.has_result, "no result on cancel")
    var kinds = zimage_drain_event_kinds(w)
    _expect(kinds[len(kinds) - 1] == ZW_FAILED, "last event Failed on cancel")
    print("PASS: cancel mid-run → Failed")


def test_param_defaults_honored() raises:
    # steps=0/cfg=0 → Base defaults; explicit values win.
    var jd = _job(0, 0.0)
    _expect(jd.steps == ZW_DEFAULT_STEPS, "steps=0 falls back to default")
    _expect(jd.cfg == ZW_DEFAULT_CFG, "cfg=0 falls back to default")
    var je = _job(12, 3.5)
    _expect(je.steps == 12, "explicit steps honored")
    _expect(je.cfg == Float32(3.5), "explicit cfg honored")
    print("PASS: param defaults vs overrides")


def test_progress_fraction() raises:
    var w = ZImageWorker()
    _expect(zimage_progress_fraction(w) == 0.0, "idle fraction 0")
    zimage_start(w, _job(4, 4.0))
    _run_to_step(w, 2)
    _expect(zimage_progress_fraction(w) == 0.5, "halfway fraction 0.5")
    print("PASS: progress fraction")


def main() raises:
    test_stub_is_default()
    test_start_emits_started()
    test_progress_then_done()
    test_cancel_mid_run()
    test_param_defaults_honored()
    test_progress_fraction()
    print("ALL zimage_worker tests passed")
