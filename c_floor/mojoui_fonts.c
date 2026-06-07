/*
 * mojoui_fonts.c — TTF loading + pre-baked glyph atlas via stb_truetype.
 *
 * MojoUI M0 chunk 5. Provides:
 *   - mojoui_load_font  : load a TTF and pre-bake atlases for dense app text
 *   - mojoui_destroy_font: free TTF buffer + GPU atlas textures
 *   - mojoui_text_width / mojoui_text_height: integer metrics
 *   - mojoui_draw_text  : emit a single mojoui_draw_batch per string
 *
 * Design notes:
 *   - Atlases are baked ONCE per (font, size) at load time using
 *     stbtt_BakeFontBitmap into a 512x512 8-bit alpha bitmap. The audit
 *     (renderer audit notes "Font Atlas Implementation") singles out the
 *     legacy backend's per-glyph stbtt_GetCodepointBitmap path as the
 *     primary text-rendering perf bug. We do not repeat that mistake.
 *   - Single-channel alpha is expanded to RGBA (R=G=B=255, A=alpha) before
 *     handing off to mojoui_make_texture, which expects RGBA8.
 *   - ASCII range 32..126 (95 codepoints) only. Non-ASCII printable bytes
 *     are silently skipped during draw_text; control bytes also skipped
 *     except '\n' (advances baseline, resets x to start).
 *   - stb_truetype is a single-header library; STB_TRUETYPE_IMPLEMENTATION
 *     is defined by the Makefile *only* when compiling this translation
 *     unit. No other .c may define it.
 *
 * Public ABI (matches chunk 6's mojoui_shim.h):
 *   uint32_t mojoui_load_font(const char* path);
 *   void     mojoui_destroy_font(uint32_t font_id);
 *   int      mojoui_text_width(uint32_t font_id, int size_pt, const char* text);
 *   int      mojoui_text_height(uint32_t font_id, int size_pt);
 *   int      mojoui_draw_text(uint32_t font_id, int size_pt,
 *                             const char* text, int x, int y,
 *                             int r, int g, int b, int a);
 *
 * Dependencies on other chunks:
 *   - mojoui_make_texture, mojoui_destroy_texture (chunk 4, mojoui_render.c)
 *   - mojoui_draw_batch                          (chunk 4, mojoui_render.c)
 *   The render layer must be initialised (mojoui_render_init) before any
 *   font is loaded — atlas upload calls sg_make_image transitively.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

/* stb_truetype.h is single-header; the IMPL macro is defined by the Makefile
 * for this TU only. Other TUs that need declarations may include the header
 * without the macro (none currently do). */
#include "stb_truetype.h"

/* Consolidated public C ABI (chunk 6). Provides every mojoui_* prototype —
 * including the chunk 4 render exports we transitively call (make_texture,
 * destroy_texture, draw_batch). We deliberately do not pull in sokol_gfx.h
 * here; this file never touches the GPU directly. */
#include "mojoui_shim.h"

/* ---------------- configuration ---------------- */

enum {
    MUI_FONT_MAX        = 8,        /* concurrent font slots */
    MUI_ATLAS_W         = 512,
    MUI_ATLAS_H         = 512,
    MUI_FIRST_CHAR      = 32,
    MUI_NUM_CHARS       = 95,       /* 32..126 inclusive */
    MUI_SIZES_PER_FONT  = 35,
    MUI_DRAW_BUF_CHARS  = 1024,     /* per-call cap; chars beyond are dropped */
    MUI_VERT_FLOATS     = 5,        /* x,y,u,v,color_bits — must match render */
};

/* Pre-baked sizes. Keep ascending; size lookup is linear. Dense native apps
 * scale text continuously across laptop, 1440p, and 4K displays, so keeping
 * every point size in this range avoids "valid command, invisible text" gaps.
 */
static const int g_size_table[MUI_SIZES_PER_FONT] = {
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28,
    30, 32, 34, 36, 38, 40, 42, 44, 46, 48,
    50, 52, 54, 56, 60, 64
};

/* ---------------- data structures ---------------- */

typedef struct {
    int                size_pt;
    uint32_t           texture_id;   /* sg_image handle from mojoui_make_texture */
    stbtt_bakedchar    chars[MUI_NUM_CHARS];
    float              scale;        /* stbtt_ScaleForPixelHeight result */
    int                ascent;       /* unscaled font-unit ascent */
    int                descent;      /* unscaled font-unit descent (negative) */
    int                line_gap;     /* unscaled font-unit line gap */
} mui_atlas;

typedef struct {
    int           in_use;
    uint8_t*      ttf_buffer;        /* heap copy of the .ttf file contents */
    stbtt_fontinfo info;
    mui_atlas     atlases[MUI_SIZES_PER_FONT];
} mui_font;

static mui_font g_fonts[MUI_FONT_MAX];

/* ---------------- helpers ---------------- */

static const char* const g_default_paths[] = {
    "/usr/share/fonts/truetype/inter/Inter-Medium.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Medium.ttf",
    "/usr/share/fonts/truetype/roboto/Roboto-Medium.ttf",
    "/Library/Fonts/SF-Pro-Text-Medium.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    NULL,
};

static const char* mui_find_default_font(void) {
    for (int i = 0; g_default_paths[i] != NULL; i++) {
        if (access(g_default_paths[i], F_OK) == 0) {
            return g_default_paths[i];
        }
    }
    return NULL;
}

/* Read entire file into a heap buffer. *out_size is set on success.
 * Caller frees the returned pointer. NULL on any I/O error. */
static uint8_t* mui_slurp_file(const char* path, size_t* out_size) {
    FILE* f = fopen(path, "rb");
    if (f == NULL) {
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz <= 0) {
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }
    uint8_t* buf = (uint8_t*)malloc((size_t)sz);
    if (buf == NULL) {
        fclose(f);
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) {
        free(buf);
        return NULL;
    }
    *out_size = (size_t)sz;
    return buf;
}

/* Locate a font slot by 1-based id (font_id == 0 is reserved as "error"). */
static mui_font* mui_font_lookup(uint32_t font_id) {
    if (font_id == 0 || font_id > MUI_FONT_MAX) {
        return NULL;
    }
    mui_font* f = &g_fonts[font_id - 1];
    if (!f->in_use) {
        return NULL;
    }
    return f;
}

/* Find the atlas for a given pre-baked size_pt within a font. NULL if missing. */
static mui_atlas* mui_atlas_for_size(mui_font* f, int size_pt) {
    mui_atlas* best = NULL;
    int best_delta = 1 << 30;
    for (int i = 0; i < MUI_SIZES_PER_FONT; i++) {
        if (f->atlases[i].size_pt == size_pt && f->atlases[i].texture_id != 0) {
            return &f->atlases[i];
        }
        if (f->atlases[i].texture_id != 0) {
            int delta = f->atlases[i].size_pt - size_pt;
            if (delta < 0) {
                delta = -delta;
            }
            if (delta < best_delta) {
                best_delta = delta;
                best = &f->atlases[i];
            }
        }
    }
    return best;
}

/* Bake one atlas (size_pt) into a 512x512 alpha bitmap, expand to RGBA,
 * upload as a texture, and stash metrics. Returns 1 on success, 0 on
 * any failure (which leaves the atlas slot zeroed). */
static int mui_bake_one(mui_font* f, mui_atlas* a, int size_pt) {
    uint8_t* alpha = (uint8_t*)calloc((size_t)MUI_ATLAS_W * MUI_ATLAS_H, 1);
    if (alpha == NULL) {
        return 0;
    }
    int rc = stbtt_BakeFontBitmap(
        f->ttf_buffer, 0,
        (float)size_pt,
        alpha, MUI_ATLAS_W, MUI_ATLAS_H,
        MUI_FIRST_CHAR, MUI_NUM_CHARS,
        a->chars
    );
    /* rc < 0 means not all chars fit (negative is how many DID fit). For our
     * sizes (<=64pt) and 512x512 the full ASCII range usually fits for
     * all reasonable fonts; treat partial fits as still-usable. rc == 0
     * means nothing fit — that's a hard failure. */
    if (rc == 0) {
        free(alpha);
        return 0;
    }

    /* expand single-channel alpha to RGBA (white pre-multiplied by alpha is
     * NOT done — the render pipeline does standard src-alpha blending). */
    size_t npix = (size_t)MUI_ATLAS_W * (size_t)MUI_ATLAS_H;
    uint8_t* rgba = (uint8_t*)malloc(npix * 4u);
    if (rgba == NULL) {
        free(alpha);
        return 0;
    }
    for (size_t i = 0; i < npix; i++) {
        rgba[i * 4u + 0] = 255;
        rgba[i * 4u + 1] = 255;
        rgba[i * 4u + 2] = 255;
        rgba[i * 4u + 3] = alpha[i];
    }
    free(alpha);

    uint32_t tex = mojoui_make_texture(MUI_ATLAS_W, MUI_ATLAS_H, rgba);
    free(rgba);
    if (tex == 0) {
        return 0;
    }

    a->size_pt    = size_pt;
    a->texture_id = tex;
    a->scale      = stbtt_ScaleForPixelHeight(&f->info, (float)size_pt);
    stbtt_GetFontVMetrics(&f->info, &a->ascent, &a->descent, &a->line_gap);
    return 1;
}

/* Pack RGBA8 color into the 0xAABBGGRR layout the renderer's UBYTE4N vertex
 * attribute expects (see mojoui_render.c vertex-layout comment). Returned as
 * a float by reinterpreting bits so it fits in the 5-float vertex stride. */
static float mui_pack_color(int r, int g, int b, int a) {
    uint32_t cr = (r < 0) ? 0 : (r > 255 ? 255 : (uint32_t)r);
    uint32_t cg = (g < 0) ? 0 : (g > 255 ? 255 : (uint32_t)g);
    uint32_t cb = (b < 0) ? 0 : (b > 255 ? 255 : (uint32_t)b);
    uint32_t ca = (a < 0) ? 0 : (a > 255 ? 255 : (uint32_t)a);
    uint32_t bits = cr | (cg << 8) | (cb << 16) | (ca << 24);
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

/* ===========================================================
 * Public ABI
 * =========================================================== */

static uint32_t mui_load_font_cstr(const char* path) {
    /* find a free slot first so a missing-font error doesn't waste work */
    int slot = -1;
    for (int i = 0; i < MUI_FONT_MAX; i++) {
        if (!g_fonts[i].in_use) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        fprintf(stderr, "mojoui_load_font: no free font slot (max=%d)\n", MUI_FONT_MAX);
        return 0;
    }

    const char* effective_path = path;
    if (effective_path == NULL || effective_path[0] == '\0') {
        effective_path = mui_find_default_font();
        if (effective_path == NULL) {
            fprintf(stderr, "mojoui_load_font: no fallback font found\n");
            return 0;
        }
    }

    size_t ttf_size = 0;
    uint8_t* ttf = mui_slurp_file(effective_path, &ttf_size);
    if (ttf == NULL) {
        fprintf(stderr, "mojoui_load_font: failed to read '%s'\n", effective_path);
        return 0;
    }
    (void)ttf_size;  /* stbtt_InitFont infers length from internal tables */

    mui_font* f = &g_fonts[slot];
    memset(f, 0, sizeof(*f));
    f->ttf_buffer = ttf;

    int offset = stbtt_GetFontOffsetForIndex(ttf, 0);
    if (offset < 0 || !stbtt_InitFont(&f->info, ttf, offset)) {
        fprintf(stderr, "mojoui_load_font: stbtt_InitFont failed on '%s'\n", effective_path);
        free(ttf);
        memset(f, 0, sizeof(*f));
        return 0;
    }

    /* Bake all sizes. If any single size fails (e.g. atlas overflow on a
     * pathological font) keep going — the remaining sizes are still usable
     * and per-size lookup at draw time will gracefully return 0/no-op. */
    int baked_any = 0;
    for (int i = 0; i < MUI_SIZES_PER_FONT; i++) {
        if (mui_bake_one(f, &f->atlases[i], g_size_table[i])) {
            baked_any = 1;
        }
    }
    if (!baked_any) {
        fprintf(stderr, "mojoui_load_font: failed to bake any atlas for '%s'\n", effective_path);
        free(ttf);
        memset(f, 0, sizeof(*f));
        return 0;
    }

    f->in_use = 1;
    return (uint32_t)(slot + 1);   /* 1-based id; 0 reserved for error */
}

uint32_t mojoui_load_font(const char* path) {
    return mui_load_font_cstr(path);
}

uint32_t mojoui_load_font_len(const char* path, int path_len) {
    if (path == NULL || path_len <= 0) {
        return mui_load_font_cstr(NULL);
    }
    char* bounded_path = (char*)malloc((size_t)path_len + 1u);
    if (bounded_path == NULL) {
        fprintf(stderr, "mojoui_load_font_len: failed to allocate path copy\n");
        return 0;
    }
    memcpy(bounded_path, path, (size_t)path_len);
    bounded_path[path_len] = '\0';
    uint32_t font_id = mui_load_font_cstr(bounded_path);
    free(bounded_path);
    return font_id;
}

void mojoui_destroy_font(uint32_t font_id) {
    mui_font* f = mui_font_lookup(font_id);
    if (f == NULL) {
        return;
    }
    for (int i = 0; i < MUI_SIZES_PER_FONT; i++) {
        if (f->atlases[i].texture_id != 0) {
            mojoui_destroy_texture(f->atlases[i].texture_id);
        }
    }
    free(f->ttf_buffer);
    memset(f, 0, sizeof(*f));
}

void mojoui_destroy_all_fonts(void) {
    for (uint32_t i = 1; i <= MUI_FONT_MAX; i++) {
        mojoui_destroy_font(i);
    }
}

int mojoui_text_width(uint32_t font_id, int size_pt, const char* text, int text_len) {
    mui_font* f = mui_font_lookup(font_id);
    if (f == NULL || text == NULL) {
        return 0;
    }
    mui_atlas* a = mui_atlas_for_size(f, size_pt);
    if (a == NULL) {
        return 0;
    }
    float x = 0.0f;
    float y = 0.0f;
    float max_x = 0.0f;
    /* Bounded by text_len: Mojo's String is not reliably NUL-terminated at
     * unsafe_ptr(), so scanning until '\0' read stale trailing bytes (text
     * bleed). Length is authoritative. */
    for (int i = 0; i < text_len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == '\n') {
            if (x > max_x) {
                max_x = x;
            }
            x = 0.0f;
            continue;
        }
        if (c < MUI_FIRST_CHAR || c >= (unsigned char)(MUI_FIRST_CHAR + MUI_NUM_CHARS)) {
            continue;
        }
        stbtt_aligned_quad q;
        stbtt_GetBakedQuad(a->chars, MUI_ATLAS_W, MUI_ATLAS_H,
                           (int)c - MUI_FIRST_CHAR, &x, &y, &q, 1);
    }
    if (x > max_x) {
        max_x = x;
    }
    return (int)(max_x + 0.5f);
}

int mojoui_text_height(uint32_t font_id, int size_pt) {
    mui_font* f = mui_font_lookup(font_id);
    if (f == NULL) {
        return 0;
    }
    mui_atlas* a = mui_atlas_for_size(f, size_pt);
    if (a == NULL) {
        return 0;
    }
    float h = (float)(a->ascent - a->descent + a->line_gap) * a->scale;
    return (int)(h + 0.5f);
}

int mojoui_draw_text(uint32_t font_id, int size_pt, const char* text, int text_len,
                     int x, int y, int r, int g, int b, int a_in) {
    mui_font* f = mui_font_lookup(font_id);
    if (f == NULL || text == NULL) {
        return 0;
    }
    mui_atlas* atlas = mui_atlas_for_size(f, size_pt);
    if (atlas == NULL) {
        return 0;
    }

    /* Build vertex+index buffers on the stack — bounded by MUI_DRAW_BUF_CHARS
     * to keep the stack frame small (~80KB worst-case for 1024 chars). */
    static float    verts[MUI_DRAW_BUF_CHARS * 4 * MUI_VERT_FLOATS];
    static uint16_t idx  [MUI_DRAW_BUF_CHARS * 6];
    int n_chars   = 0;
    int n_verts   = 0;
    int n_indices = 0;

    const float line_advance =
        (float)(atlas->ascent - atlas->descent + atlas->line_gap) * atlas->scale;
    const float line_start_x = (float)x;
    float pen_x = (float)x;
    float pen_y = (float)y;

    float color_bits = mui_pack_color(r, g, b, a_in);

    /* Bounded by text_len, NOT a NUL scan: Mojo's String is not reliably
     * NUL-terminated at unsafe_ptr(), so scanning until '\0' rendered stale
     * trailing glyphs from a previous longer string (text bleed). */
    for (int i = 0; i < text_len; i++) {
        if (n_chars >= MUI_DRAW_BUF_CHARS) {
            break;
        }
        unsigned char c = (unsigned char)text[i];
        if (c == '\n') {
            pen_x = line_start_x;
            pen_y += line_advance;
            continue;
        }
        if (c < MUI_FIRST_CHAR || c >= (unsigned char)(MUI_FIRST_CHAR + MUI_NUM_CHARS)) {
            continue;
        }

        stbtt_aligned_quad q;
        stbtt_GetBakedQuad(atlas->chars, MUI_ATLAS_W, MUI_ATLAS_H,
                           (int)c - MUI_FIRST_CHAR, &pen_x, &pen_y, &q, 1);

        uint16_t base = (uint16_t)n_verts;
        float* v = &verts[n_verts * MUI_VERT_FLOATS];

        v[0]  = q.x0; v[1]  = q.y0; v[2]  = q.s0; v[3]  = q.t0; v[4]  = color_bits;
        v[5]  = q.x1; v[6]  = q.y0; v[7]  = q.s1; v[8]  = q.t0; v[9]  = color_bits;
        v[10] = q.x1; v[11] = q.y1; v[12] = q.s1; v[13] = q.t1; v[14] = color_bits;
        v[15] = q.x0; v[16] = q.y1; v[17] = q.s0; v[18] = q.t1; v[19] = color_bits;
        n_verts += 4;

        idx[n_indices + 0] = (uint16_t)(base + 0);
        idx[n_indices + 1] = (uint16_t)(base + 1);
        idx[n_indices + 2] = (uint16_t)(base + 2);
        idx[n_indices + 3] = (uint16_t)(base + 0);
        idx[n_indices + 4] = (uint16_t)(base + 2);
        idx[n_indices + 5] = (uint16_t)(base + 3);
        n_indices += 6;

        n_chars++;
    }

    if (n_indices > 0) {
        return mojoui_draw_batch_checked(verts, n_verts, idx, n_indices, atlas->texture_id);
    }
    return 1;
}
