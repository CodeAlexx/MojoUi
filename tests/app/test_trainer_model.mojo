"""Tests for trainer UI state and config snapshots.

Run: pixi run test-trainer-model
"""

from mojoui.app.trainer_model import (
    TrainerState,
    TRAINER_VALIDATION_ERROR,
    bucket_for_image,
    assign_dataset_buckets,
    trainer_dataset_image_count,
    trainer_request_from_state,
    trainer_validation_issues,
    trainer_validation_error_count,
    trainer_validation_summary,
    trainer_preset_json_from_state,
    trainer_state_apply_preset_json,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_defaults_from_handoff() raises:
    var s = TrainerState()
    _expect(s.run_name == String("rstprsn-v3"), "default run name")
    _expect(s.model_type_label() == String("LoRA"), "default model type")
    _expect(s.architecture_label() == String("SDXL 1.0"), "default architecture")
    _expect(s.optimizer_label() == String("AdamW 8bit"), "default optimizer")
    _expect(s.theme_label() == String("Rust Trainer"), "default Rust Trainer theme")
    _expect(len(s.concepts) == 2, "two seed concepts")
    print("PASS: defaults from handoff")


def test_bucket_assignment() raises:
    var square = bucket_for_image(1024, 1024, 1024, 512, 1536, 64)
    _expect(square.width == 1024 and square.height == 1024, "square bucket")
    var portrait = bucket_for_image(832, 1216, 1024, 512, 1536, 64)
    _expect(portrait.height == 1024, "portrait long side")
    _expect(portrait.width == 704, "portrait rounded width")
    var landscape = bucket_for_image(1216, 832, 1024, 512, 1536, 64)
    _expect(landscape.width == 1024, "landscape long side")
    _expect(landscape.height == 704, "landscape rounded height")
    print("PASS: bucket assignment")


def test_assign_dataset_buckets_and_count() raises:
    var s = TrainerState()
    assign_dataset_buckets(s)
    _expect(s.dataset_images[0].bucket_width == 1024, "image 0 bucket width")
    _expect(s.dataset_images[4].bucket_width == 704, "image 4 portrait bucket")
    _expect(trainer_dataset_image_count(s) == 72, "concept repeats drive train image count")
    print("PASS: assign buckets and count")


def test_request_snapshot() raises:
    var s = TrainerState()
    var req = trainer_request_from_state(s, UInt64(42))
    _expect(req.id == UInt64(42), "request id")
    _expect(req.run_name == String("rstprsn-v3"), "request run name")
    _expect(req.model_type == String("LoRA"), "request model type")
    _expect(req.network_rank == 64, "network rank")
    _expect(req.target_resolution == 1024, "target resolution")
    _expect(req.dataset_image_count == 72, "dataset image count")
    _expect(req.sample_every_steps == 250, "sample cadence")
    _expect(req.save_every_steps == 500, "checkpoint cadence")
    _expect(len(req.metadata) == 3, "metadata captured")
    print("PASS: request snapshot")


def test_validation() raises:
    var s = TrainerState()
    var issues = trainer_validation_issues(s)
    _expect(trainer_validation_error_count(issues) == 0, "default trainer state is valid")
    _expect(trainer_validation_summary(issues) == String("Ready"), "default validation summary")
    s.base_model = String("")
    var bad = trainer_validation_issues(s)
    _expect(trainer_validation_error_count(bad) > 0, "missing base model is invalid")
    var saw_model_error = False
    for i in range(len(bad)):
        if bad[i].severity == TRAINER_VALIDATION_ERROR and bad[i].field == String("base_model"):
            saw_model_error = True
    _expect(saw_model_error, "base_model error is reported")
    print("PASS: validation")


def test_preset_roundtrip() raises:
    var s = TrainerState()
    s.run_name = String("roundtrip-run")
    s.project_dir = String("~/trainings/roundtrip-run")
    s.base_model = String("custom-base.safetensors")
    s.dataset_path = String("dataset/custom")
    s.network_rank = 96.0
    s.sample_prompts.append(String("roundtrip prompt"))
    var raw = trainer_preset_json_from_state(s)

    var loaded = TrainerState()
    loaded.run_name = String("before")
    trainer_state_apply_preset_json(loaded, raw)
    _expect(loaded.run_name == String("roundtrip-run"), "preset run name")
    _expect(loaded.project_dir == String("~/trainings/roundtrip-run"), "preset project dir")
    _expect(loaded.base_model == String("custom-base.safetensors"), "preset base model")
    _expect(loaded.dataset_path == String("dataset/custom"), "preset dataset path")
    _expect(loaded.network_rank == 96.0, "preset network rank")
    _expect(len(loaded.sample_prompts) == 4, "preset prompt list roundtrip")
    _expect(loaded.theme_label() == String("Rust Trainer"), "preset theme label")
    print("PASS: preset roundtrip")


def main() raises:
    test_defaults_from_handoff()
    test_bucket_assignment()
    test_assign_dataset_buckets_and_count()
    test_request_snapshot()
    test_validation()
    test_preset_roundtrip()
    print("PASS: trainer model tests (6 tests)")
