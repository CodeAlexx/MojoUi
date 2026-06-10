"""Play audio through MojoUI's ALSA floor (audio_play_demo).

No arg: plays a short 440 Hz tone (self-contained smoke test).
With a path: reads a WAV via MOJO-libs `audio.wav` and plays it — the model
use case (play generated / reference audio).

Build (links the C floor; -I MOJO-libs for the WAV reader):
  pixi run mojo build -I . -I /home/alex/MOJO-libs \
    -Xlinker -L. -Xlinker -lmojoui_floor -Xlinker -lm \
    examples/audio_play_demo.mojo -o /tmp/audio_play
  LD_LIBRARY_PATH=. /tmp/audio_play            # short tone (audible)
  LD_LIBRARY_PATH=. /tmp/audio_play clip.wav   # play a WAV
"""

from std.sys import argv
from std.math import sin, pi
from mojoui.audio.playback import play_samples
from audio.wav import read_wav


def main() raises:
    var args = argv()
    if len(args) > 1:
        var buf = read_wav(String(args[1]))
        print("playing", String(args[1]), ":", buf.rate, "Hz", buf.channels, "ch", buf.duration_secs(), "s")
        var rc = play_samples(buf.samples, buf.rate, buf.channels)
        print("play rc:", rc, "(0 = ok, <0 = ALSA error)")
    else:
        var rate = 44100
        var secs = 0.3
        var n = Int(Float64(rate) * secs)
        var tone = List[Float32]()
        for i in range(n):
            tone.append(Float32(0.2 * sin(2.0 * pi * 440.0 * Float64(i) / Float64(rate))))
        print("playing 440Hz tone", secs, "s @", rate, "Hz mono")
        var rc = play_samples(tone, rate, 1)
        print("play rc:", rc, "(0 = ok, <0 = ALSA error)")
