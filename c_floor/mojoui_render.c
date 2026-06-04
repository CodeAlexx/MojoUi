/*
 * mojoui_render.c — flat C shim over sokol_gfx for 2D batched rendering.
 *
 * MojoUI M0 chunk 4. Provides:
 *   - sokol_gfx setup/teardown bound to sokol_app's swapchain via sokol_glue
 *   - one 2D textured-vertex-color pipeline with inline GLSL 330 core shaders
 *   - dynamic streaming vertex/index buffers populated each frame via sg_append_buffer
 *   - one default 1x1 white texture (used when caller passes texture_id == 0)
 *   - texture create/destroy returning opaque uint32 ids
 *
 * Public ABI (declared by chunk 6's mojoui_shim.h, but stable here):
 *   int      mojoui_render_init(void);
 *   void     mojoui_render_shutdown(void);
 *   void     mojoui_frame_begin(int r, int g, int b, int a);
 *   void     mojoui_frame_end(void);
 *   void     mojoui_draw_batch(const float* verts, int n_verts,
 *                              const uint16_t* indices, int n_indices,
 *                              uint32_t texture_id);
 *   uint32_t mojoui_make_texture(int w, int h, const uint8_t* rgba);
 *   void     mojoui_destroy_texture(uint32_t texture_id);
 *
 * Vertex layout (20 bytes / vertex):
 *   offset  0: float2  a_pos    (pixel coordinates)
 *   offset  8: float2  a_uv     (texture coordinates, 0..1)
 *   offset 16: ubyte4n a_color  (RGBA, normalized to 0..1)
 *
 * The caller packs vertices as 5 floats per vertex: x, y, u, v, color_bits
 * where color_bits is a uint32 (0xAABBGGRR little-endian) reinterpreted
 * as a float for buffer layout purposes. The pipeline reads attribute 2
 * as SG_VERTEXFORMAT_UBYTE4N from the same 4 bytes.
 *
 * sokol_glue.h SOKOL_IMPL lives in this file. sokol_app.h is included
 * declaration-only here (its IMPL lives in mojoui_platform.c — chunk 3).
 */

#include <stdint.h>
#include <string.h>

/* sokol_app.h: declarations only — its SOKOL_IMPL is in mojoui_platform.c. */
#include "sokol_app.h"

/* sokol_gfx.h: implementation lives here. SOKOL_GLCORE is provided by the
 * Makefile via -DSOKOL_GLCORE for consistency with mojoui_platform.c. */
#define SOKOL_GFX_IMPL
#include "sokol_gfx.h"

/* sokol_glue.h: implementation lives here (single place across all .c files).
 * Requires both sokol_gfx.h and sokol_app.h declarations to be visible above. */
#define SOKOL_GLUE_IMPL
#include "sokol_glue.h"

/* sokol_log.h: implementation lives here too — used for the slog_func callback. */
#define SOKOL_LOG_IMPL
#include "sokol_log.h"

/* Consolidated public C ABI — chunk 6. Brings in every mojoui_* prototype
 * (window/input from chunk 3, render from this file, fonts from chunk 5)
 * so signatures stay in one canonical place. */
#include "mojoui_shim.h"

/* ---- buffer-size budgets (per-frame upload cap) ---- */
enum {
    MUI_MAX_VERTS    = 16384,
    MUI_MAX_INDICES  = 32768,
    MUI_VERT_STRIDE  = 20,                        /* bytes per vertex */
    MUI_VBUF_BYTES   = MUI_MAX_VERTS   * MUI_VERT_STRIDE,
    MUI_IBUF_BYTES   = MUI_MAX_INDICES * (int)sizeof(uint16_t),
};

/* ---- uniform block layout (must match GLSL vertex shader) ---- */
typedef struct mui_vs_uniforms {
    float u_screen_size[2];
    float _pad[2];   /* keep size a multiple of 16 for cross-backend safety */
} mui_vs_uniforms;

/* ---- module-local renderer state ---- */
static struct {
    bool         initialized;
    sg_pipeline  pip;
    sg_shader    shd;
    sg_buffer    vbuf;
    sg_buffer    ibuf;
    sg_sampler   smp;
    sg_image     white_img;
    sg_view      white_view;
    sg_pass_action pass_action;
} g_r;

/* ---- inline GLSL 330 core shaders (SOKOL_GLCORE backend) ----
 * Vertex shader converts pixel coordinates to NDC with Y flipped so
 * (0,0) maps to the top-left of the window (matches GUI convention).
 */
static const char* mui_vs_src =
    "#version 330\n"
    "layout(location=0) in vec2 a_pos;\n"
    "layout(location=1) in vec2 a_uv;\n"
    "layout(location=2) in vec4 a_color;\n"
    "uniform vec2 u_screen_size;\n"
    "out vec2 v_uv;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 ndc = vec2(\n"
    "        (a_pos.x / u_screen_size.x) * 2.0 - 1.0,\n"
    "        1.0 - (a_pos.y / u_screen_size.y) * 2.0\n"
    "    );\n"
    "    gl_Position = vec4(ndc, 0.0, 1.0);\n"
    "    v_uv = a_uv;\n"
    "    v_color = a_color;\n"
    "}\n";

static const char* mui_fs_src =
    "#version 330\n"
    "uniform sampler2D u_tex;\n"
    "in vec2 v_uv;\n"
    "in vec4 v_color;\n"
    "out vec4 frag;\n"
    "void main() {\n"
    "    frag = texture(u_tex, v_uv) * v_color;\n"
    "}\n";

/* ---- helpers ---- */

static sg_view mui_make_texture_view(sg_image img) {
    sg_view_desc vd;
    memset(&vd, 0, sizeof(vd));
    vd.texture.image = img;
    return sg_make_view(&vd);
}

/* ===========================================================
 * Public ABI
 * =========================================================== */

int mojoui_render_init(void) {
    if (g_r.initialized) {
        return 1;
    }

    /* 1. boot sokol_gfx, binding to sokol_app's GL context via sokol_glue. */
    sg_desc sgd;
    memset(&sgd, 0, sizeof(sgd));
    sgd.environment = sglue_environment();
    sgd.logger.func = slog_func;
    sg_setup(&sgd);
    if (!sg_isvalid()) {
        return 0;
    }

    /* 2. dynamic vertex buffer (stream usage — re-uploaded each frame). */
    sg_buffer_desc vbd;
    memset(&vbd, 0, sizeof(vbd));
    vbd.size = MUI_VBUF_BYTES;
    vbd.usage.vertex_buffer = true;
    vbd.usage.stream_update = true;
    vbd.label = "mojoui-vbuf";
    g_r.vbuf = sg_make_buffer(&vbd);

    /* 3. dynamic index buffer. */
    sg_buffer_desc ibd;
    memset(&ibd, 0, sizeof(ibd));
    ibd.size = MUI_IBUF_BYTES;
    ibd.usage.index_buffer = true;
    ibd.usage.stream_update = true;
    ibd.label = "mojoui-ibuf";
    g_r.ibuf = sg_make_buffer(&ibd);

    /* 4. shader (GLSL 330 core, vertex+fragment, one vec2 uniform,
     *           one combined texture+sampler pair for u_tex). */
    sg_shader_desc shd;
    memset(&shd, 0, sizeof(shd));
    shd.vertex_func.source   = mui_vs_src;
    shd.fragment_func.source = mui_fs_src;
    shd.label = "mojoui-shader";

    shd.attrs[0].glsl_name = "a_pos";
    shd.attrs[1].glsl_name = "a_uv";
    shd.attrs[2].glsl_name = "a_color";

    /* vertex-stage uniform block: vec2 u_screen_size (+ pad to 16 bytes). */
    shd.uniform_blocks[0].stage  = SG_SHADERSTAGE_VERTEX;
    shd.uniform_blocks[0].size   = sizeof(mui_vs_uniforms);
    shd.uniform_blocks[0].layout = SG_UNIFORMLAYOUT_STD140;
    shd.uniform_blocks[0].glsl_uniforms[0].type        = SG_UNIFORMTYPE_FLOAT2;
    shd.uniform_blocks[0].glsl_uniforms[0].array_count = 1;
    shd.uniform_blocks[0].glsl_uniforms[0].glsl_name   = "u_screen_size";

    /* fragment-stage texture view (slot 0). */
    shd.views[0].texture.stage        = SG_SHADERSTAGE_FRAGMENT;
    shd.views[0].texture.image_type   = SG_IMAGETYPE_2D;
    shd.views[0].texture.sample_type  = SG_IMAGESAMPLETYPE_FLOAT;
    shd.views[0].texture.multisampled = false;

    /* fragment-stage sampler (slot 0). */
    shd.samplers[0].stage        = SG_SHADERSTAGE_FRAGMENT;
    shd.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;

    /* GL needs the texture+sampler pair to bind to a GLSL uniform sampler2D. */
    shd.texture_sampler_pairs[0].stage       = SG_SHADERSTAGE_FRAGMENT;
    shd.texture_sampler_pairs[0].view_slot   = 0;
    shd.texture_sampler_pairs[0].sampler_slot= 0;
    shd.texture_sampler_pairs[0].glsl_name   = "u_tex";

    g_r.shd = sg_make_shader(&shd);

    /* 5. pipeline: triangle list, uint16 indices, alpha-blended, no depth. */
    sg_pipeline_desc pd;
    memset(&pd, 0, sizeof(pd));
    pd.shader         = g_r.shd;
    pd.index_type     = SG_INDEXTYPE_UINT16;
    pd.primitive_type = SG_PRIMITIVETYPE_TRIANGLES;
    pd.cull_mode      = SG_CULLMODE_NONE;
    pd.label          = "mojoui-pip";

    pd.layout.buffers[0].stride = MUI_VERT_STRIDE;
    pd.layout.attrs[0].format = SG_VERTEXFORMAT_FLOAT2;   /* a_pos    @ 0  */
    pd.layout.attrs[0].offset = 0;
    pd.layout.attrs[1].format = SG_VERTEXFORMAT_FLOAT2;   /* a_uv     @ 8  */
    pd.layout.attrs[1].offset = 8;
    pd.layout.attrs[2].format = SG_VERTEXFORMAT_UBYTE4N;  /* a_color  @ 16 */
    pd.layout.attrs[2].offset = 16;

    pd.colors[0].blend.enabled            = true;
    pd.colors[0].blend.src_factor_rgb     = SG_BLENDFACTOR_SRC_ALPHA;
    pd.colors[0].blend.dst_factor_rgb     = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    pd.colors[0].blend.op_rgb             = SG_BLENDOP_ADD;
    pd.colors[0].blend.src_factor_alpha   = SG_BLENDFACTOR_ONE;
    pd.colors[0].blend.dst_factor_alpha   = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    pd.colors[0].blend.op_alpha           = SG_BLENDOP_ADD;

    g_r.pip = sg_make_pipeline(&pd);

    /* 6. default linear sampler. */
    sg_sampler_desc smpd;
    memset(&smpd, 0, sizeof(smpd));
    smpd.min_filter = SG_FILTER_LINEAR;
    smpd.mag_filter = SG_FILTER_LINEAR;
    smpd.wrap_u     = SG_WRAP_CLAMP_TO_EDGE;
    smpd.wrap_v     = SG_WRAP_CLAMP_TO_EDGE;
    smpd.label      = "mojoui-sampler";
    g_r.smp = sg_make_sampler(&smpd);

    /* 7. 1x1 white texture (used when caller passes texture_id == 0). */
    static const uint8_t white_px[4] = { 255, 255, 255, 255 };
    sg_image_desc imd;
    memset(&imd, 0, sizeof(imd));
    imd.type           = SG_IMAGETYPE_2D;
    imd.width          = 1;
    imd.height         = 1;
    imd.num_mipmaps    = 1;
    imd.pixel_format   = SG_PIXELFORMAT_RGBA8;
    imd.data.mip_levels[0].ptr  = white_px;
    imd.data.mip_levels[0].size = sizeof(white_px);
    imd.label          = "mojoui-white-1x1";
    g_r.white_img  = sg_make_image(&imd);
    g_r.white_view = mui_make_texture_view(g_r.white_img);

    /* 8. default pass action — overwritten per-frame in mojoui_frame_begin. */
    memset(&g_r.pass_action, 0, sizeof(g_r.pass_action));
    g_r.pass_action.colors[0].load_action  = SG_LOADACTION_CLEAR;
    g_r.pass_action.colors[0].store_action = SG_STOREACTION_STORE;

    g_r.initialized = true;
    return 1;
}

void mojoui_render_shutdown(void) {
    if (!g_r.initialized) {
        return;
    }
    sg_destroy_view(g_r.white_view);
    sg_destroy_image(g_r.white_img);
    sg_destroy_sampler(g_r.smp);
    sg_destroy_pipeline(g_r.pip);
    sg_destroy_shader(g_r.shd);
    sg_destroy_buffer(g_r.ibuf);
    sg_destroy_buffer(g_r.vbuf);
    sg_shutdown();
    memset(&g_r, 0, sizeof(g_r));
}

void mojoui_frame_begin(int clear_r, int clear_g, int clear_b, int clear_a) {
    if (!g_r.initialized) {
        return;
    }
    g_r.pass_action.colors[0].load_action  = SG_LOADACTION_CLEAR;
    g_r.pass_action.colors[0].clear_value.r = (float)clear_r / 255.0f;
    g_r.pass_action.colors[0].clear_value.g = (float)clear_g / 255.0f;
    g_r.pass_action.colors[0].clear_value.b = (float)clear_b / 255.0f;
    g_r.pass_action.colors[0].clear_value.a = (float)clear_a / 255.0f;

    sg_pass pass;
    memset(&pass, 0, sizeof(pass));
    pass.action    = g_r.pass_action;
    pass.swapchain = sglue_swapchain();
    sg_begin_pass(&pass);

    sg_apply_pipeline(g_r.pip);

    /* push screen size — needed every frame because the pass may resize. */
    mui_vs_uniforms u;
    memset(&u, 0, sizeof(u));
    u.u_screen_size[0] = (float)sapp_width();
    u.u_screen_size[1] = (float)sapp_height();
    sg_range r = { &u, sizeof(u) };
    sg_apply_uniforms(0, &r);
}

void mojoui_frame_end(void) {
    if (!g_r.initialized) {
        return;
    }
    sg_end_pass();
    sg_commit();
}

void mojoui_draw_batch(
    const float*    verts,
    int             n_verts,
    const uint16_t* indices,
    int             n_indices,
    uint32_t        texture_id
) {
    if (!g_r.initialized) {
        return;
    }
    if (verts == NULL || indices == NULL || n_verts <= 0 || n_indices <= 0) {
        return;
    }

    /* append per-frame geometry into the streaming buffers. */
    sg_range vrange = { verts,   (size_t)n_verts   * (size_t)MUI_VERT_STRIDE };
    sg_range irange = { indices, (size_t)n_indices * sizeof(uint16_t) };
    int vbuf_offset = sg_append_buffer(g_r.vbuf, &vrange);
    int ibuf_offset = sg_append_buffer(g_r.ibuf, &irange);

    /* pick texture view: 0 → built-in 1x1 white; otherwise treat the id
     * as the raw sg_image handle and build an ad-hoc texture view.
     * (View is destroyed at frame_end via sokol's per-frame resource pool —
     * actually no, sg_view is a persistent resource. For texture_id != 0
     * the caller passes an sg_image id and we make+destroy a transient view
     * per draw. This is fine for M0 and keeps the ABI flat.) */
    sg_view tex_view;
    if (texture_id == 0) {
        tex_view = g_r.white_view;
    } else {
        sg_image img;
        img.id = texture_id;
        tex_view = mui_make_texture_view(img);
    }

    sg_bindings bind;
    memset(&bind, 0, sizeof(bind));
    bind.vertex_buffers[0]        = g_r.vbuf;
    bind.vertex_buffer_offsets[0] = vbuf_offset;
    bind.index_buffer             = g_r.ibuf;
    bind.index_buffer_offset      = ibuf_offset;
    bind.views[0]                 = tex_view;
    bind.samplers[0]              = g_r.smp;
    sg_apply_bindings(&bind);

    sg_draw(0, n_indices, 1);

    if (texture_id != 0) {
        sg_destroy_view(tex_view);
    }
}

uint32_t mojoui_make_texture(int width, int height, const uint8_t* rgba_pixels) {
    if (!g_r.initialized || width <= 0 || height <= 0 || rgba_pixels == NULL) {
        return 0;
    }
    sg_image_desc imd;
    memset(&imd, 0, sizeof(imd));
    imd.type           = SG_IMAGETYPE_2D;
    imd.width          = width;
    imd.height         = height;
    imd.num_mipmaps    = 1;
    imd.pixel_format   = SG_PIXELFORMAT_RGBA8;
    imd.data.mip_levels[0].ptr  = rgba_pixels;
    imd.data.mip_levels[0].size = (size_t)width * (size_t)height * 4u;
    imd.label          = "mojoui-user-tex";
    sg_image img = sg_make_image(&imd);
    return img.id;
}

void mojoui_destroy_texture(uint32_t texture_id) {
    if (!g_r.initialized || texture_id == 0) {
        return;
    }
    sg_image img;
    img.id = texture_id;
    sg_destroy_image(img);
}
