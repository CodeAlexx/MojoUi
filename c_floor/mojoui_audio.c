/* mojoui_audio.c — minimal ALSA PCM playback floor for MojoUI.
 *
 * Self-contained (no sokol_audio dependency): opens the ALSA "default" device
 * with the simple set_params API, accepts interleaved float32 samples in
 * [-1, 1], and plays via blocking snd_pcm_writei. Exposed to Mojo through the
 * mojoui_audio_* ABI in mojoui_shim.h. Used to play generated/model audio
 * (e.g. LTX2/NAVA output) and, paired with the video frame path, A/V preview.
 *
 * Verification note: this is verified to compile + link + run (init/write/
 * shutdown without crashing) on a box with an ALSA device. Audible output can
 * only be confirmed on the user's speakers.
 */
#include "mojoui_shim.h"

#include <alsa/asoundlib.h>

static snd_pcm_t* g_pcm = NULL;
static int g_channels = 0;
static int g_rate = 0;

int mojoui_audio_init(int rate, int channels) {
    if (g_pcm) {
        mojoui_audio_shutdown();
    }
    if (rate <= 0 || channels <= 0) {
        return -1;
    }
    int err = snd_pcm_open(&g_pcm, "default", SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        g_pcm = NULL;
        return err;
    }
    /* float32 interleaved, soft-resample on, ~100ms latency target */
    err = snd_pcm_set_params(
        g_pcm,
        SND_PCM_FORMAT_FLOAT_LE,
        SND_PCM_ACCESS_RW_INTERLEAVED,
        (unsigned int)channels,
        (unsigned int)rate,
        1,            /* allow ALSA soft resampling */
        100000        /* latency in microseconds */
    );
    if (err < 0) {
        snd_pcm_close(g_pcm);
        g_pcm = NULL;
        return err;
    }
    g_channels = channels;
    g_rate = rate;
    return 0;
}

int mojoui_audio_is_open(void) {
    return g_pcm != NULL ? 1 : 0;
}

/* Write nframes of interleaved float32 (nframes = sample_count / channels).
 * Blocking. Recovers from underrun (-EPIPE) once. Returns frames written or <0. */
int mojoui_audio_write(const float* samples, int nframes) {
    if (!g_pcm || !samples || nframes <= 0) {
        return -1;
    }
    int total = 0;
    const float* p = samples;
    int remaining = nframes;
    while (remaining > 0) {
        snd_pcm_sframes_t w = snd_pcm_writei(g_pcm, p, (snd_pcm_uframes_t)remaining);
        if (w < 0) {
            w = snd_pcm_recover(g_pcm, (int)w, 1);
            if (w < 0) {
                return (int)w;
            }
            continue;
        }
        total += (int)w;
        remaining -= (int)w;
        p += (size_t)w * (size_t)g_channels;
    }
    return total;
}

void mojoui_audio_drain(void) {
    if (g_pcm) {
        snd_pcm_drain(g_pcm);
    }
}

void mojoui_audio_shutdown(void) {
    if (g_pcm) {
        snd_pcm_drain(g_pcm);
        snd_pcm_close(g_pcm);
        g_pcm = NULL;
        g_channels = 0;
        g_rate = 0;
    }
}
