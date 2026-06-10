"""mojoui.audio.playback — play interleaved float32 audio via the ALSA C floor.

Thin Mojo wrapper over the `mojoui_audio_*` ABI (c_floor/mojoui_audio.c). Pairs
with MOJO-libs `audio.wav` (read a clip / generate samples → `List[Float32]`)
to play model-generated or reference audio.

`audio_write` is **blocking** (it returns once the samples are queued/played),
so the simple `play_samples` plays a whole buffer synchronously. For UI-thread
playback you'd chunk writes across frames; that's a later refinement.

Build/run note: like the rest of MojoUI, link the C floor and run the built
binary (the JIT can't dlopen libmojoui_floor.so):
  mojo build -I . -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm <f> -o /tmp/x
  LD_LIBRARY_PATH=. /tmp/x
"""

from std.ffi import external_call


def audio_init(rate: Int, channels: Int) -> Int:
    """Open the default playback device for float32 interleaved audio.
    Returns 0 on success, <0 on ALSA error (e.g. no device)."""
    return Int(external_call["mojoui_audio_init", Int32](Int32(rate), Int32(channels)))


def audio_is_open() -> Bool:
    return external_call["mojoui_audio_is_open", Int32]() != 0


def audio_write(mut samples: List[Float32], nframes: Int) -> Int:
    """Write `nframes` interleaved frames (blocking). Returns frames written or <0."""
    return Int(
        external_call["mojoui_audio_write", Int32](samples.unsafe_ptr(), Int32(nframes))
    )


def audio_drain():
    external_call["mojoui_audio_drain", NoneType]()


def audio_shutdown():
    external_call["mojoui_audio_shutdown", NoneType]()


def play_samples(mut samples: List[Float32], rate: Int, channels: Int) raises -> Int:
    """Play a whole interleaved-float32 buffer synchronously.
    Returns 0 on success, the negative ALSA error from init otherwise."""
    var ch = channels if channels > 0 else 1
    var rc = audio_init(rate, ch)
    if rc < 0:
        return rc
    var nframes = len(samples) // ch
    if nframes > 0:
        _ = audio_write(samples, nframes)
    audio_drain()
    audio_shutdown()
    return 0
