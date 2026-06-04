"""Tests for model-agnostic backend contracts.

Run: cd /home/alex/MojoUI && pixi run test-model-backend
"""

from mojoui.app.job_runtime import (
    JOB_KIND_INFERENCE,
    JOB_KIND_TRAINER,
    JOB_KIND_CAPTION,
)
from mojoui.app.model_backend import (
    TrainerRequest,
    TASK_TRAIN_LORA,
    TASK_TRAIN_FULL,
    TRAINER_BACKEND_CMD_SUBMIT,
    PARAM_PATH,
    make_trainer_capability,
    make_inference_capability,
    request_param,
    trainer_task_id_from_model_type,
    TrainerBackendCommand,
    validate_trainer_request,
    backend_validation_error_count,
    trainer_total_steps,
    trainer_job_label,
)


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def test_capabilities() raises:
    var trainer = make_trainer_capability(String("stub.train"), String("Stub Trainer"))
    _expect(trainer.supports_job_kind(JOB_KIND_TRAINER), "trainer supports trainer jobs")
    _expect(not trainer.supports_job_kind(JOB_KIND_INFERENCE), "trainer does not imply inference")
    _expect(trainer.supports_lora, "trainer supports lora")

    var inference = make_inference_capability(String("stub.infer"), String("Stub Inference"), 2048, 2048)
    _expect(inference.supports_job_kind(JOB_KIND_INFERENCE), "inference supports inference jobs")
    _expect(not inference.supports_job_kind(JOB_KIND_CAPTION), "inference does not imply caption")
    _expect(inference.max_width == 2048, "max width stored")
    print("PASS: capabilities")


def test_request_param() raises:
    var p = request_param(String("dataset"), String("/tmp/data"), PARAM_PATH)
    _expect(p.key == String("dataset"), "param key")
    _expect(p.value == String("/tmp/data"), "param value")
    _expect(p.kind == PARAM_PATH, "param kind")
    print("PASS: request param")


def test_trainer_total_steps() raises:
    var req = TrainerRequest()
    req.run_name = String("run-a")
    req.model_type = String("LoRA")
    req.dataset_image_count = 48
    req.epochs = 10
    req.batch_size = 2
    req.grad_accum = 4
    _expect(trainer_total_steps(req) == 60, "derived steps ceil(images/effective_batch)*epochs")
    req.max_train_steps = 250
    _expect(trainer_total_steps(req) == 250, "max steps wins")
    _expect(trainer_job_label(req) == String("run-a · LoRA"), "job label")
    print("PASS: trainer total steps")


def test_trainer_request_validation_and_commands() raises:
    var cap = make_trainer_capability(String("stub.train"), String("Stub Trainer"))
    var req = TrainerRequest()
    req.task_id = TASK_TRAIN_LORA
    req.backend_id = String("stub.train")
    req.run_name = String("run-a")
    req.model_type = String("LoRA")
    req.base_model = String("base.safetensors")
    req.dataset_path = String("dataset/person")
    req.output_dir = String("output/run-a")
    req.dataset_image_count = 8
    req.network_rank = 16
    req.network_alpha = 16
    req.epochs = 2
    req.batch_size = 1
    req.grad_accum = 1
    req.learning_rate = 0.0001
    req.text_encoder_lr = 0.00005
    req.target_resolution = 1024
    req.min_bucket_resolution = 512
    req.max_bucket_resolution = 1536
    req.bucket_step = 64
    req.timestep_start = 0
    req.timestep_end = 1000
    req.keep_last_n = 3
    var issues = validate_trainer_request(req, cap)
    _expect(backend_validation_error_count(issues) == 0, "valid request has no errors")
    _expect(trainer_task_id_from_model_type(String("Full fine-tune")) == TASK_TRAIN_FULL, "full finetune task")
    var cmd = TrainerBackendCommand(TRAINER_BACKEND_CMD_SUBMIT, UInt64(9), req, String("submit"))
    _expect(cmd.kind == TRAINER_BACKEND_CMD_SUBMIT, "command kind")
    _expect(cmd.request.run_name == String("run-a"), "command carries request")

    req.base_model = String("")
    var bad = validate_trainer_request(req, cap)
    _expect(backend_validation_error_count(bad) > 0, "invalid request has errors")
    print("PASS: trainer request validation and commands")


def main() raises:
    test_capabilities()
    test_request_param()
    test_trainer_total_steps()
    test_trainer_request_validation_and_commands()
    print("PASS: model backend tests (4 tests)")
