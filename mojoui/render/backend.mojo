"""High-level Mojo rendering API — wraps mojoui.render.ffi with Vec2/Rect/Color types.

This is the layer all MojoUI application code (chunk 10 m0_hello demo, every
M1+ widget) calls. The FFI module is the thin `external_call` floor; this
module adds Mojo-native value types (`Vec2`, `Rect`, `Color`) and the only
real "Mojo rendering code" in M0 — the rectangle tessellation that turns a
`(Rect, Color)` pair into the 4-vertex / 6-index pattern the C-floor pipeline
expects.

Lifecycle:
    Backend.init(w, h, title)              # opens window + sg_setup
    Backend.run_blocking(frame_callback)   # blocks on sapp_run
        # Inside the callback (invoked per frame by sokol):
        Backend.frame_begin(clear_color)
        Backend.draw_rect(...) ; Backend.draw_text(...)
        Backend.frame_end()
    Backend.shutdown()                     # tears sg + window down

Vertex format (matches c_floor/mojoui_shim.h and public ABI notes §4):
    5 floats per vertex = (x, y, u, v, color_bits) — stride 20 bytes.
    The 5th "float" is a `0xAABBGGRR` UInt32 bit-reinterpreted (the ImDrawVert
    trick). The sokol pipeline reads attribute 2 at offset 16 as
    SG_VERTEXFORMAT_UBYTE4N. NEVER treat the 5th value as a real number.

texture_id=0 → built-in 1×1 white texture, the right binding for any
untextured colored geometry like `draw_rect`.
"""

from std.memory import UnsafePointer
from std.builtin.type_aliases import MutAnyOrigin

from mojoui.core.types import Vec2, Rect, Color
from mojoui.render.ffi import (
    init_window as _ffi_init_window,
    run_blocking as _ffi_run_blocking,
    request_close as _ffi_request_close,
    should_close as _ffi_should_close,
    get_window_width as _ffi_get_window_width,
    get_window_height as _ffi_get_window_height,
    get_mouse_x as _ffi_get_mouse_x,
    get_mouse_y as _ffi_get_mouse_y,
    get_mouse_button as _ffi_get_mouse_button,
    get_key as _ffi_get_key,
    get_input_text as _ffi_get_input_text,
    input_text_length as _ffi_input_text_length,
    clear_input_text as _ffi_clear_input_text,
    render_init as _ffi_render_init,
    render_shutdown as _ffi_render_shutdown,
    frame_begin as _ffi_frame_begin,
    frame_end as _ffi_frame_end,
    draw_batch as _ffi_draw_batch,
    make_texture as _ffi_make_texture,
    destroy_texture as _ffi_destroy_texture,
    load_font as _ffi_load_font,
    destroy_font as _ffi_destroy_font,
    text_width as _ffi_text_width,
    text_height as _ffi_text_height,
    draw_text as _ffi_draw_text,
)


# ============================================================
# Internal helpers (prefix _, not part of the public Backend API
# but unit-tested by tests/render/test_backend.mojo).
# ============================================================


def _pack_color_aabbggrr(c: Color) -> UInt32:
    """Pack Color into the 0xAABBGGRR UInt32 the vertex pipeline expects.

    Layout: A in the high byte (bits 24..31), B (16..23), G (8..15), R (0..7).
    This is the little-endian RGBA8 byte order GL/sokol expects when the
    attribute is declared SG_VERTEXFORMAT_UBYTE4N — bytes come off in
    R,G,B,A order in memory, so the UInt32 reads as 0xAABBGGRR.

    Example: Color(255, 0, 0, 255)  ->  0xFF0000FF
             A=0xFF B=0x00 G=0x00 R=0xFF.
    """
    var bits: UInt32 = UInt32(c.a)
    bits = (bits << 8) | UInt32(c.b)
    bits = (bits << 8) | UInt32(c.g)
    bits = (bits << 8) | UInt32(c.r)
    return bits


def _u32_to_f32_bits(u: UInt32) -> Float32:
    """Bit-reinterpret a UInt32 as a Float32 (the ImDrawVert color-as-float trick).

    Implemented via a stack-allocated Float32 + UnsafePointer(to=...).bitcast.
    No Mojo `bitcast` builtin for scalars exists yet in current beta; the
    pointer round-trip is the canonical workaround documented in
    Mojo implementation notes "Living additions".
    """
    var f: Float32 = 0.0
    var fp = UnsafePointer(to=f).bitcast[UInt32]()
    fp[] = u
    return f


def _tessellate_rect(
    r: Rect,
    c: Color,
    mut verts: InlineArray[Float32, 20],
    mut idx: InlineArray[UInt16, 6],
):
    """Tessellate a (Rect, Color) into 4 vertices + 6 indices (two CCW triangles).

    Vertex order (CCW in screen space — Y grows down):
        v0 (top-left, x, y)
        v1 (top-right, x+w, y)
        v2 (bottom-right, x+w, y+h)
        v3 (bottom-left, x, y+h)

    Indices:  0, 1, 2,   0, 2, 3   (two triangles sharing the v0-v2 diagonal).

    Each vertex is 5 floats: (x, y, u, v, color_bits). UV is (0, 0) for all
    four corners — the C floor binds the built-in 1×1 white texture (id=0)
    for untextured colored geometry, so the sampled color is white and the
    vertex-color multiply yields the requested color.
    """
    var color_bits = _pack_color_aabbggrr(c)
    var color_f = _u32_to_f32_bits(color_bits)

    var x0 = r.x
    var y0 = r.y
    var x1 = r.x + r.w
    var y1 = r.y + r.h

    # v0: top-left
    verts[0] = x0
    verts[1] = y0
    verts[2] = 0.0
    verts[3] = 0.0
    verts[4] = color_f
    # v1: top-right
    verts[5] = x1
    verts[6] = y0
    verts[7] = 0.0
    verts[8] = 0.0
    verts[9] = color_f
    # v2: bottom-right
    verts[10] = x1
    verts[11] = y1
    verts[12] = 0.0
    verts[13] = 0.0
    verts[14] = color_f
    # v3: bottom-left
    verts[15] = x0
    verts[16] = y1
    verts[17] = 0.0
    verts[18] = 0.0
    verts[19] = color_f

    idx[0] = 0
    idx[1] = 1
    idx[2] = 2
    idx[3] = 0
    idx[4] = 2
    idx[5] = 3


def _tessellate_image_rect(
    r: Rect,
    tint: Color,
    mut verts: InlineArray[Float32, 20],
    mut idx: InlineArray[UInt16, 6],
):
    """Tessellate a textured rect with full 0..1 UVs and caller tint."""
    var color_bits = _pack_color_aabbggrr(tint)
    var color_f = _u32_to_f32_bits(color_bits)

    var x0 = r.x
    var y0 = r.y
    var x1 = r.x + r.w
    var y1 = r.y + r.h

    # v0: top-left, uv=(0,0)
    verts[0] = x0
    verts[1] = y0
    verts[2] = 0.0
    verts[3] = 0.0
    verts[4] = color_f
    # v1: top-right, uv=(1,0)
    verts[5] = x1
    verts[6] = y0
    verts[7] = 1.0
    verts[8] = 0.0
    verts[9] = color_f
    # v2: bottom-right, uv=(1,1)
    verts[10] = x1
    verts[11] = y1
    verts[12] = 1.0
    verts[13] = 1.0
    verts[14] = color_f
    # v3: bottom-left, uv=(0,1)
    verts[15] = x0
    verts[16] = y1
    verts[17] = 0.0
    verts[18] = 1.0
    verts[19] = color_f

    idx[0] = 0
    idx[1] = 1
    idx[2] = 2
    idx[3] = 0
    idx[4] = 2
    idx[5] = 3


# ============================================================
# Public Backend API
# ============================================================


struct Backend:
    """High-level Mojo rendering facade.

    All methods are static — Backend holds no per-instance state, the C floor
    owns the window + GPU resources. Calling these methods is equivalent to
    "talk to libmojoui_floor.so", just with Mojo-native value types instead
    of raw integers / raw pointers / 0-255 channel ints.
    """

    # ----- Lifecycle ---------------------------------------------------

    @staticmethod
    def init(width: Int32, height: Int32, title: String) -> Int32:
        """Fill the sokol_app desc; returns 0 on success.

        Only `mojoui_init_window` is called here — `mojoui_render_init`
        (sg_setup + pipeline + 1×1 white texture) cannot run until sokol_app
        has created the GL context. The C floor wires `mojoui_render_init`
        into sokol_app's init callback (`platform_init_cb` in
        `c_floor/mojoui_platform.c`), so it executes automatically the moment
        the window is alive — i.e. immediately after `run_blocking` enters
        `sapp_run`, BEFORE the first frame callback fires. Mojo code must
        NOT call `_ffi_render_init` directly. See Mojo implementation notes
        ("render_init timing").
        """
        return _ffi_init_window(width, height, title)

    @staticmethod
    def shutdown():
        """Tear sokol_gfx down. The window itself goes away when sapp_run returns."""
        _ffi_render_shutdown()

    @staticmethod
    def run_blocking[CbType: AnyType, //](frame_fn: CbType):
        """Block on `sapp_run`; sokol invokes `frame_fn` once per frame.

        `frame_fn` must be a Mojo `def () -> None` (zero args, no return).
        The parametric type parameter is the workaround for the current-beta
        function-pointer FFI capturing-error-swap (see ffi.mojo run_blocking
        docstring + Mojo implementation notes "Living additions"). Pass-through to the
        underlying FFI wrapper — no extra logic here.
        """
        _ffi_run_blocking(frame_fn)

    @staticmethod
    def request_close():
        """Signal the window to close at the next frame boundary."""
        _ffi_request_close()

    @staticmethod
    def should_close() -> Bool:
        """True after user clicked X or `request_close` was called."""
        return _ffi_should_close() != 0

    @staticmethod
    def window_size() -> Vec2:
        """Current backbuffer dimensions as a `Vec2` (Float32 pixels)."""
        var w = _ffi_get_window_width()
        var h = _ffi_get_window_height()
        return Vec2(Float32(Int(w)), Float32(Int(h)))

    # ----- Frame lifecycle ---------------------------------------------

    @staticmethod
    def frame_begin(clear_color: Color):
        """Begin a frame: clear backbuffer to `clear_color`.

        Channels are passed to the C floor as 0-255 Int32 — matches the
        `mojoui_frame_begin(int r, int g, int b, int a)` signature.
        """
        _ffi_frame_begin(
            Int32(Int(clear_color.r)),
            Int32(Int(clear_color.g)),
            Int32(Int(clear_color.b)),
            Int32(Int(clear_color.a)),
        )

    @staticmethod
    def frame_end():
        """End frame: `sg_end_pass` + `sg_commit` (present)."""
        _ffi_frame_end()

    # ----- Input queries -----------------------------------------------

    @staticmethod
    def mouse_pos() -> Vec2:
        """Current mouse position (pixels, top-left origin)."""
        var x = _ffi_get_mouse_x()
        var y = _ffi_get_mouse_y()
        return Vec2(Float32(Int(x)), Float32(Int(y)))

    @staticmethod
    def mouse_button(button: Int32) -> Bool:
        """True if `button` is pressed. `button` is one of MOJOUI_BTN_LEFT/RIGHT/MIDDLE."""
        return _ffi_get_mouse_button(button) != 0

    @staticmethod
    def key_pressed(mojoui_key: Int32) -> Bool:
        """True if `mojoui_key` is currently held down. Uses the MOJOUI_KEY_* enum."""
        return _ffi_get_key(mojoui_key) != 0

    @staticmethod
    def input_text() raises -> String:
        """Drain newly-typed UTF-8 text since the last call.

        Reads the C-side text-input buffer (a const char* aliasing internal
        storage), copies it into a Mojo `String`, then calls
        `clear_input_text()` so the next frame starts empty. Returns "" when
        nothing was typed.

        The byte-by-byte copy goes through `List[UInt8]` because that's the
        only `String(unsafe_from_utf8=...)` overload current-beta Mojo accepts
        for foreign-owned NUL-terminated buffers (see Mojo implementation notes).
        """
        var n = _ffi_input_text_length()
        if n <= 0:
            # Still call clear() — defensive, harmless if the buffer is empty.
            _ffi_clear_input_text()
            return String("")
        var ptr_i8 = _ffi_get_input_text()
        var ptr_u8 = ptr_i8.bitcast[UInt8]()
        var n_int = Int(n)
        var bytes = List[UInt8](capacity=n_int)
        for i in range(n_int):
            bytes.append(ptr_u8[i])
        var s = String(unsafe_from_utf8=bytes)
        _ffi_clear_input_text()
        return s

    # ----- Drawing primitives ------------------------------------------

    @staticmethod
    def draw_rect(rect: Rect, color: Color):
        """Solid colored rectangle.

        Tessellates to 4 vertices + 6 indices (`_tessellate_rect`) on the
        Mojo stack (no heap allocation), then issues a single
        `mojoui_draw_batch` call against `texture_id=0` (the built-in 1×1
        white texture, so the vertex-color attribute drives the final color).

        For M0 every `draw_rect` is its own batch. Multi-rect batching is a
        future optimization (M3 tessellator chunk).
        """
        var verts = InlineArray[Float32, 20](fill=0.0)
        var idx = InlineArray[UInt16, 6](fill=0)
        _tessellate_rect(rect, color, verts, idx)
        _ffi_draw_batch(
            verts.unsafe_ptr(),
            Int32(4),
            idx.unsafe_ptr(),
            Int32(6),
            UInt32(0),
        )

    @staticmethod
    def make_texture_rgba(width: Int32, height: Int32, mut rgba_pixels: List[UInt8]) -> UInt32:
        """Upload a row-major RGBA8 image and return its opaque texture id.

        The C floor copies `rgba_pixels` into a sokol image during this call, so
        the caller keeps ownership of the list and may reuse or drop it after.
        Returns 0 on invalid size, empty input, or C-floor upload failure.
        """
        if width <= Int32(0) or height <= Int32(0):
            return UInt32(0)
        var expected = Int(width) * Int(height) * 4
        if len(rgba_pixels) < expected:
            return UInt32(0)
        return _ffi_make_texture(width, height, rgba_pixels.unsafe_ptr())

    @staticmethod
    def destroy_texture(texture_id: UInt32):
        """Destroy a texture created by `make_texture_rgba`.

        Texture id 0 is the built-in white texture and is ignored by the C floor.
        """
        _ffi_destroy_texture(texture_id)

    @staticmethod
    def draw_image_rect(rect: Rect, texture_id: UInt32, tint: Color):
        """Draw a textured rectangle using full 0..1 UVs.

        This is the live renderer counterpart to `CMD_IMAGE`. `texture_id=0`
        still draws through the built-in white texture, which is useful for
        tests and graceful fallback.
        """
        var verts = InlineArray[Float32, 20](fill=0.0)
        var idx = InlineArray[UInt16, 6](fill=0)
        _tessellate_image_rect(rect, tint, verts, idx)
        _ffi_draw_batch(
            verts.unsafe_ptr(),
            Int32(4),
            idx.unsafe_ptr(),
            Int32(6),
            texture_id,
        )

    @staticmethod
    def draw_batch_lists(
        var verts: List[Float32],
        var indices: List[UInt16],
        texture_id: UInt32,
    ):
        """Submit a variable-size vertex+index batch as a single GPU draw.

        Companion to `draw_rect` but for primitives whose vertex/index
        counts are not known at compile time (rounded rects, circles,
        tessellated curves). Takes ownership of `verts` and `indices`
        (the `var` parameters move the caller's lists), then forwards
        their `unsafe_ptr()` storage to `mojoui_draw_batch`.

        Vertex layout matches `_tessellate_rect` (5 floats per vertex:
        `x, y, u, v, color_bits`). The caller is responsible for packing
        the color via `_pack_color_aabbggrr` + `_u32_to_f32_bits`.

        Index count must be a multiple of 3 (triangles); vertex count
        must be `len(verts) // 5`. Both validated by the C floor at
        the `mojoui_draw_batch` boundary, NOT here.

        `texture_id=0` binds the built-in 1×1 white texture for solid
        colored geometry.

        Added in M3 chunk 46 (tessellator) — used by
        `mojoui/render/tessellator.mojo::tess_rounded_rect` /
        `tess_circle` / `tess_drop_shadow`. The list-typed API matches
        the variable-vertex-count shape; `draw_rect` keeps its
        InlineArray fast path for the fixed 4-vert / 6-idx case.
        """
        var n_verts = Int32(len(verts) // 5)
        var n_indices = Int32(len(indices))
        # Explicit empty-input guard: with n_verts == 0 or n_indices == 0
        # there is nothing to draw, and `verts.unsafe_ptr()` on an empty
        # List is implementation-defined across Mojo betas. Bail before
        # the FFI call to keep behavior portable.
        if n_verts == Int32(0) or n_indices == Int32(0):
            return
        _ffi_draw_batch(
            verts.unsafe_ptr(),
            n_verts,
            indices.unsafe_ptr(),
            n_indices,
            texture_id,
        )

    @staticmethod
    def draw_text(
        font_id: UInt32,
        size_pt: Int32,
        text: String,
        baseline_left: Vec2,
        color: Color,
    ) -> Int32:
        """Draw `text` at baseline-left position `baseline_left`.

        Returns 1 on success (matches the C floor convention). The pen
        starts at `baseline_left`; `\\n` characters advance pen.y and reset
        pen.x (the C floor handles this internally). ASCII-only for M0
        (bytes outside 32..126 are silently skipped — full UTF-8 + IME is
        deferred to the M2 TextEdit chunk).
        """
        return _ffi_draw_text(
            font_id,
            size_pt,
            text,
            Int32(Int(baseline_left.x)),
            Int32(Int(baseline_left.y)),
            Int32(Int(color.r)),
            Int32(Int(color.g)),
            Int32(Int(color.b)),
            Int32(Int(color.a)),
        )

    @staticmethod
    def text_width(font_id: UInt32, size_pt: Int32, text: String) -> Int32:
        """Pixel width of `text` at the given size (uses cached glyph metrics)."""
        return _ffi_text_width(font_id, size_pt, text)

    @staticmethod
    def text_height(font_id: UInt32, size_pt: Int32) -> Int32:
        """Line height at the given size (= scale * (ascent - descent + line_gap))."""
        return _ffi_text_height(font_id, size_pt)

    @staticmethod
    def load_font(path: String) -> UInt32:
        """Load a TTF font from `path`. Returns font_id ≥ 1 on success, 0 on error.

        Empty string ("") triggers the C-floor default search through
        Inter / JetBrainsMono / Roboto / SF Pro / DejaVu / Liberation paths.
        """
        return _ffi_load_font(path)

    @staticmethod
    def destroy_font(font_id: UInt32):
        """Free the font's TTF buffer + GPU atlas textures."""
        _ffi_destroy_font(font_id)
