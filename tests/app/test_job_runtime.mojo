"""Pure tests for the backend-neutral job runtime.

Run: pixi run test-job-runtime
"""

from mojoui.app.job_runtime import (
    JobRuntime,
    ArtifactRef,
    JOB_KIND_INFERENCE,
    JOB_KIND_TRAINER,
    JOB_KIND_NODE_GRAPH,
    JOB_PHASE_QUEUED,
    JOB_PHASE_RUNNING,
    JOB_PHASE_DONE,
    JOB_PHASE_FAILED,
    JOB_PHASE_CANCELLED,
    JOB_PHASE_PAUSED,
    JOB_EVENT_STARTED,
    JOB_EVENT_PROGRESS,
    JOB_EVENT_ARTIFACT,
    JOB_EVENT_LOG,
    JOB_EVENT_DONE,
    JOB_EVENT_FAILED,
    JOB_EVENT_CANCELLED,
    JOB_EVENT_PAUSED,
    JOB_EVENT_RESUMED,
    ARTIFACT_IMAGE,
    ARTIFACT_CHECKPOINT,
    JOB_LOG_INFO,
    JOB_LOG_WARN,
    submit_job,
    start_job,
    update_progress,
    add_artifact,
    add_log,
    complete_job,
    fail_job,
    cancel_job,
    pause_job,
    resume_job,
    job_progress,
    find_job_index,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_submit_and_start() raises:
    var rt = JobRuntime()
    var id = submit_job(rt, JOB_KIND_INFERENCE, String("txt2img"), 0, 0)
    _expect(id == UInt64(1), "first job id")
    _expect(len(rt.jobs) == 1, "one job stored")
    _expect(rt.jobs[0].phase == JOB_PHASE_QUEUED, "submitted job queued")
    _expect(start_job(rt, id, 30), "start returns true")
    _expect(rt.jobs[0].phase == JOB_PHASE_RUNNING, "started job running")
    _expect(rt.jobs[0].total_steps == 30, "total steps stored")
    _expect(len(rt.events) == 1, "started event emitted")
    _expect(rt.events[0].kind == JOB_EVENT_STARTED, "started event kind")
    print("PASS: submit and start")


def test_progress_and_done() raises:
    var rt = JobRuntime()
    var id = submit_job(rt, JOB_KIND_INFERENCE, String("zimage"), 0, 0)
    _ = start_job(rt, id, 10)
    _expect(update_progress(rt, id, 4, 10, String("denoise")), "progress returns true")
    _expect(rt.jobs[0].current_step == 4, "step stored")
    _expect(job_progress(rt, id) > 0.39 and job_progress(rt, id) < 0.41, "progress fraction")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_PROGRESS, "progress event")
    _expect(complete_job(rt, id, String("done")), "complete returns true")
    _expect(rt.jobs[0].phase == JOB_PHASE_DONE, "done phase")
    _expect(rt.jobs[0].progress == 1.0, "done progress 1")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_DONE, "done event")
    print("PASS: progress and done")


def test_artifacts_and_logs() raises:
    var rt = JobRuntime()
    var id = submit_job(rt, JOB_KIND_TRAINER, String("lora train"), 0, 0)
    _ = start_job(rt, id, 100)
    _ = update_progress(rt, id, 25, 100, String("step"))
    var image = ArtifactRef(ARTIFACT_IMAGE, String("/tmp/sample.png"), String("sample"), 25)
    _expect(add_artifact(rt, id, image), "image artifact added")
    var ckpt = ArtifactRef(ARTIFACT_CHECKPOINT, String("/tmp/lora.safetensors"), String("checkpoint"), 25)
    _expect(add_artifact(rt, id, ckpt), "checkpoint artifact added")
    _expect(add_log(rt, id, JOB_LOG_INFO, String("loss 0.5")), "log added")
    _expect(rt.events[len(rt.events) - 3].kind == JOB_EVENT_ARTIFACT, "artifact event image")
    _expect(rt.events[len(rt.events) - 2].artifact.kind == ARTIFACT_CHECKPOINT, "artifact checkpoint kind")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_LOG, "log event")
    print("PASS: artifacts and logs")


def test_fail_and_cancel() raises:
    var rt = JobRuntime()
    var fail_id = submit_job(rt, JOB_KIND_INFERENCE, String("bad run"), 0, 0)
    _ = start_job(rt, fail_id, 10)
    _expect(fail_job(rt, fail_id, String("oom")), "fail returns true")
    _expect(rt.jobs[0].phase == JOB_PHASE_FAILED, "failed phase")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_FAILED, "failed event")
    _expect(rt.jobs[0].error == "oom", "error stored")

    var cancel_id = submit_job(rt, JOB_KIND_TRAINER, String("stop train"), 0, 0)
    _ = start_job(rt, cancel_id, 100)
    _ = update_progress(rt, cancel_id, 5, 100, String("step"))
    _expect(cancel_job(rt, cancel_id, String("stopped")), "cancel returns true")
    var idx = find_job_index(rt, cancel_id)
    _expect(rt.jobs[idx].phase == JOB_PHASE_CANCELLED, "cancelled phase")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_CANCELLED, "cancelled event")
    print("PASS: fail and cancel")


def test_pause_and_resume() raises:
    var rt = JobRuntime()
    var id = submit_job(rt, JOB_KIND_TRAINER, String("pauseable train"), 0, 0)
    _ = start_job(rt, id, 100)
    _ = update_progress(rt, id, 10, 100, String("step"))
    _expect(pause_job(rt, id, String("paused")), "pause returns true")
    _expect(rt.jobs[0].phase == JOB_PHASE_PAUSED, "paused phase")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_PAUSED, "paused event")
    _expect(resume_job(rt, id, String("resumed")), "resume returns true")
    _expect(rt.jobs[0].phase == JOB_PHASE_RUNNING, "running after resume")
    _expect(rt.events[len(rt.events) - 1].kind == JOB_EVENT_RESUMED, "resumed event")
    print("PASS: pause and resume")


def test_graph_metadata_and_missing_job() raises:
    var rt = JobRuntime()
    var id = submit_job(
        rt,
        JOB_KIND_NODE_GRAPH,
        String("ksampler node"),
        UInt64(42),
        UInt64(9001),
    )
    _expect(rt.jobs[0].source_node_id == UInt64(42), "source node id stored")
    _expect(rt.jobs[0].graph_run_id == UInt64(9001), "graph run id stored")
    _expect(not start_job(rt, UInt64(999), 1), "missing start returns false")
    _expect(not update_progress(rt, UInt64(999), 1, 1, String("")), "missing progress false")
    _expect(not complete_job(rt, UInt64(999), String("")), "missing complete false")
    _expect(job_progress(rt, UInt64(999)) == 0.0, "missing progress 0")
    _expect(id == UInt64(1), "graph job id")
    print("PASS: graph metadata and missing job")


def main() raises:
    test_submit_and_start()
    test_progress_and_done()
    test_artifacts_and_logs()
    test_fail_and_cancel()
    test_pause_and_resume()
    test_graph_metadata_and_missing_job()
    print("PASS: job runtime tests (6 tests)")
