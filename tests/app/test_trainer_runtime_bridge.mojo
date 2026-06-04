"""Tests for the CPU trainer runtime bridge.

Run: pixi run test-trainer-runtime
"""

from mojoui.app.job_runtime import (
    JOB_PHASE_QUEUED,
    JOB_PHASE_RUNNING,
    JOB_PHASE_PAUSED,
    JOB_PHASE_DONE,
    JOB_PHASE_CANCELLED,
    JOB_EVENT_ARTIFACT,
    ARTIFACT_IMAGE,
    ARTIFACT_CHECKPOINT,
)
from mojoui.app.trainer_model import TrainerState
from mojoui.app.model_backend import (
    TRAINER_BACKEND_CMD_SUBMIT,
    TRAINER_BACKEND_CMD_PAUSE,
    TRAINER_BACKEND_CMD_RESUME,
    TRAINER_BACKEND_CMD_CANCEL,
    TRAINER_BACKEND_CMD_SAMPLE_NOW,
    TRAINER_BACKEND_CMD_SAVE_CHECKPOINT,
)
from mojoui.app.trainer_runtime_bridge import (
    TrainerUiRuntime,
    TRAINER_FRAMES_PER_STEP,
    trainer_submit_current,
    trainer_tick_and_apply,
    trainer_pause,
    trainer_resume,
    trainer_cancel_all,
    trainer_sample_now,
    trainer_save_checkpoint_now,
    trainer_progress_fraction,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def _tick_steps(mut rt: TrainerUiRuntime, steps: Int):
    for _ in range(steps * Int(TRAINER_FRAMES_PER_STEP)):
        trainer_tick_and_apply(rt)


def test_submit_starts_job() raises:
    var s = TrainerState()
    s.max_train_steps = 6.0
    var rt = TrainerUiRuntime()
    var id = trainer_submit_current(s, rt)
    _expect(id == UInt64(1), "first job id")
    _expect(rt.has_running, "job running")
    _expect(rt.jobs.jobs[0].phase == JOB_PHASE_RUNNING, "phase running")
    _expect(rt.live.total_steps == 6, "total steps from request")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_SUBMIT, "submit command recorded")
    _expect(rt.last_validation_summary == String("Ready"), "submit validation ready")
    print("PASS: submit starts job")


def test_progress_artifacts_and_done() raises:
    var s = TrainerState()
    s.max_train_steps = 6.0
    s.sample_every_steps = 2.0
    s.save_every_steps = 3.0
    var rt = TrainerUiRuntime()
    _ = trainer_submit_current(s, rt)
    _tick_steps(rt, 2)
    _expect(trainer_progress_fraction(rt) > 0.32, "progress after two steps")
    _expect(len(rt.samples) == 1, "sample artifact emitted at step 2")
    _tick_steps(rt, 1)
    _expect(len(rt.checkpoints) == 1, "checkpoint artifact emitted at step 3")
    _expect(rt.samples[0].kind == ARTIFACT_IMAGE, "sample artifact kind")
    _expect(rt.checkpoints[0].kind == ARTIFACT_CHECKPOINT, "checkpoint artifact kind")
    _tick_steps(rt, 3)
    _expect(not rt.has_running, "runtime idle after done")
    _expect(rt.jobs.jobs[0].phase == JOB_PHASE_DONE, "job done")
    _expect(rt.jobs.events[len(rt.jobs.events) - 1].kind != JOB_EVENT_ARTIFACT, "done follows artifacts")
    print("PASS: progress artifacts and done")


def test_pause_resume() raises:
    var s = TrainerState()
    s.max_train_steps = 5.0
    var rt = TrainerUiRuntime()
    _ = trainer_submit_current(s, rt)
    _tick_steps(rt, 1)
    var before = rt.live.step
    _expect(trainer_pause(rt), "pause returns true")
    _expect(rt.jobs.jobs[0].phase == JOB_PHASE_PAUSED, "paused phase")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_PAUSE, "pause command recorded")
    _tick_steps(rt, 2)
    _expect(rt.live.step == before, "paused tick does not advance")
    _expect(trainer_resume(rt), "resume returns true")
    _expect(rt.jobs.jobs[0].phase == JOB_PHASE_RUNNING, "running after resume")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_RESUME, "resume command recorded")
    _tick_steps(rt, 1)
    _expect(rt.live.step == before + 1, "resume advances")
    print("PASS: pause resume")


def test_queue_and_cancel() raises:
    var s = TrainerState()
    s.max_train_steps = 8.0
    var rt = TrainerUiRuntime()
    var first = trainer_submit_current(s, rt)
    var second = trainer_submit_current(s, rt)
    _expect(first == UInt64(1) and second == UInt64(2), "two job ids")
    _expect(len(rt.queued_requests) == 1, "one queued request")
    _expect(rt.jobs.jobs[1].phase == JOB_PHASE_QUEUED, "queued job phase")
    trainer_cancel_all(rt)
    _expect(not rt.has_running, "cancel all idle")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_CANCEL, "cancel command recorded")
    _expect(len(rt.queued_requests) == 0, "queue dropped")
    _expect(rt.jobs.jobs[0].phase == JOB_PHASE_CANCELLED, "running cancelled")
    _expect(rt.jobs.jobs[1].phase == JOB_PHASE_CANCELLED, "queued cancelled")
    print("PASS: queue and cancel")


def test_manual_actions() raises:
    var s = TrainerState()
    s.max_train_steps = 10.0
    var rt = TrainerUiRuntime()
    _ = trainer_submit_current(s, rt)
    _tick_steps(rt, 1)
    _expect(trainer_sample_now(rt), "manual sample")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_SAMPLE_NOW, "sample command recorded")
    _expect(trainer_save_checkpoint_now(rt), "manual checkpoint")
    _expect(rt.last_backend_command.kind == TRAINER_BACKEND_CMD_SAVE_CHECKPOINT, "checkpoint command recorded")
    _expect(len(rt.samples) == 1, "manual sample stored")
    _expect(len(rt.checkpoints) == 1, "manual checkpoint stored")
    print("PASS: manual actions")


def test_validation_blocks_submit() raises:
    var s = TrainerState()
    s.base_model = String("")
    var rt = TrainerUiRuntime()
    var id = trainer_submit_current(s, rt)
    _expect(id == UInt64(0), "invalid submit returns zero")
    _expect(not rt.has_running, "invalid submit does not start")
    _expect(len(rt.jobs.jobs) == 0, "invalid submit does not create job")
    _expect(rt.last_validation_summary != String("Ready"), "validation summary captured")
    print("PASS: validation blocks submit")


def main() raises:
    test_submit_starts_job()
    test_progress_artifacts_and_done()
    test_pause_resume()
    test_queue_and_cancel()
    test_manual_actions()
    test_validation_blocks_submit()
    print("PASS: trainer runtime bridge tests (6 tests)")
