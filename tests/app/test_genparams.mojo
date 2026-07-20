"""Canonical generation-request round-trip tests."""

from mojoui.app.genparams import GenLora, GenParams, GenParamStore


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error(msg)


def main() raises:
    var p = GenParams()
    p.model = String("LTX2")
    p.prompt = String("runtime prompt")
    p.negative = String("runtime negative")
    p.width = 768
    p.height = 512
    p.frames = 97
    p.fps = 25.0
    p.include_audio = True
    p.steps = 20
    p.seed = 314159
    p.caps_positive = String("/runtime/positive.safetensors")
    p.caps_negative = String("/runtime/negative.safetensors")
    p.loras.append(GenLora(String("/runtime/a.safetensors"), 0.65))
    p.loras.append(GenLora(String("/runtime/b.safetensors"), -0.2))

    var decoded = GenParams.from_json(p.to_json())
    _expect(decoded.same_as(p), String("video request must round-trip exactly"))
    _expect(decoded.frames == 97, String("frames lost in JSON round-trip"))
    _expect(decoded.fps == 25.0, String("fps lost in JSON round-trip"))
    _expect(decoded.include_audio, String("audio flag lost in JSON round-trip"))
    _expect(len(decoded.loras) == 2, String("LoRA stack was truncated"))

    var store = GenParamStore()
    store.set(p.copy())
    var model_names = List[String]()
    model_names.append(String("LTX2"))
    var sampler_names = List[String]()
    sampler_names.append(String("euler"))
    var scheduler_names = List[String]()
    scheduler_names.append(String("simple"))
    var lora_names = List[String]()
    lora_names.append(String("/runtime/a.safetensors"))
    lora_names.append(String("/runtime/b.safetensors"))
    _ = store.refresh_mirrors(
        model_names, sampler_names, scheduler_names, lora_names
    )
    store.m_frames = 121.0
    store.d_frames = True
    store.m_fps = 24.0
    store.d_fps = True
    store.m_caps_positive = String("/runtime/changed-positive.safetensors")
    store.d_caps_positive = True
    _ = store.commit_mirrors(
        model_names, sampler_names, scheduler_names, lora_names
    )
    _expect(store.params.frames == 121, String("frame mirror did not commit"))
    _expect(store.params.fps == 24.0, String("fps mirror did not commit"))
    _expect(
        store.params.caps_positive
            == String("/runtime/changed-positive.safetensors"),
        String("conditioning mirror did not commit"),
    )
    _expect(len(store.params.loras) == 2, String("unmodified LoRA stack changed"))
    print("PASS: canonical video GenParams")
