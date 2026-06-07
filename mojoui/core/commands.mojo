"""Draw command list with JUMP-based z-ordering for MojoUI.

`CommandBuffer` is a flat byte stream of tagged draw commands the renderer
walks at frame end. Every command begins with a `CmdHeader { kind, size }`
(microui invariant per `internal audit notes` "Command
List"), so the consumer advances by `size` bytes regardless of variant.

JUMP commands enable z-order without re-sorting draws: each container emits
its draws in call order then ends with a JUMP placeholder; at end_frame the
root list is sorted by z-index and the JUMPs are patched via `patch_jump`.

Encoding is field-by-field into `List[UInt8]` (UInt8/Int32/UInt32/Float32)
rather than struct-as-bytes memcpy, since `sizeof[T]()` is not exposed in
current-beta Mojo. `CmdText` is the only variable-length variant: UTF-8
bytes follow the fixed prefix, length given by `text_byte_len`.

This module emits + walks commands; the renderer adapter (M3) dispatches to
`Backend.draw_rect` / `draw_text` etc.
"""

from std.memory import UnsafePointer

from mojoui.core.types import Color, Rect, Vec2

# --- Command kind tags (`comptime` not `alias` — Mojo implementation notes) ---
comptime DrawCmdKind = Int32
comptime CMD_NONE: DrawCmdKind = 0    # sentinel — never in well-formed buffer
comptime CMD_JUMP: DrawCmdKind = 1    # skip reader to absolute offset (z-order)
comptime CMD_CLIP: DrawCmdKind = 2    # set current clip rect (renderer scissor)
comptime CMD_RECT: DrawCmdKind = 3    # filled axis-aligned rect
comptime CMD_TEXT: DrawCmdKind = 4    # UTF-8 text at position (var-length)
comptime CMD_ICON: DrawCmdKind = 5    # icon glyph by small-int id
comptime CMD_IMAGE: DrawCmdKind = 6   # textured rect (texture_id from make_texture)
comptime CMD_CUSTOM: DrawCmdKind = 7  # user-extension hook (reserved)
comptime CMD_TRIANGLES: DrawCmdKind = 8  # variable-length tessellated geometry (M3 c46-fix Bug 2)

# --- Fixed-size command sizes (bytes) ---
# Int32/UInt32/Float32 = 4, UInt8 = 1. CmdHeader = 8 (kind+size).
# Rect = 16 (4×F32). Color = 4 (4×U8). Vec2 = 8 (2×F32).
comptime HEADER_SIZE: Int32 = 8
comptime _RECT_BYTES: Int32 = 16
comptime _COLOR_BYTES: Int32 = 4
comptime _VEC2_BYTES: Int32 = 8

# JUMP=12, CLIP=24, RECT=28, ICON=32, IMAGE=32, TEXT=36+len(bytes).
comptime CMD_JUMP_SIZE: Int32 = HEADER_SIZE + 4
comptime CMD_CLIP_SIZE: Int32 = HEADER_SIZE + _RECT_BYTES
comptime CMD_RECT_SIZE: Int32 = HEADER_SIZE + _RECT_BYTES + _COLOR_BYTES
comptime CMD_TEXT_FIXED_SIZE: Int32 = (
    HEADER_SIZE + 4 + 4 + _VEC2_BYTES + _COLOR_BYTES + 4
)
comptime CMD_ICON_SIZE: Int32 = HEADER_SIZE + _RECT_BYTES + 4 + _COLOR_BYTES
comptime CMD_IMAGE_SIZE: Int32 = HEADER_SIZE + _RECT_BYTES + 4 + _COLOR_BYTES

# --- Byte encoders / decoders (host-endian; not portable across hosts) ---
# Pattern (per Mojo implementation notes "UnsafePointer(to=var)"): bitcast a primitive's
# stack pointer to UInt8 and walk index 0..N-1. Same trick as backend.mojo's
# ImDrawVert bit-reinterpret.

@always_inline
def _write_u8(mut buf: List[UInt8], v: UInt8):
    buf.append(v)

@always_inline
def _read_u8(buf: List[UInt8], off: Int) -> UInt8:
    return buf[off]

def _write_i32(mut buf: List[UInt8], v: Int32):
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): buf.append(p[i])

def _read_i32(buf: List[UInt8], off: Int) -> Int32:
    var v: Int32 = 0
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): p[i] = buf[off + i]
    return v

def _write_u32(mut buf: List[UInt8], v: UInt32):
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): buf.append(p[i])

def _read_u32(buf: List[UInt8], off: Int) -> UInt32:
    var v: UInt32 = 0
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): p[i] = buf[off + i]
    return v

def _write_f32(mut buf: List[UInt8], v: Float32):
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): buf.append(p[i])

def _read_f32(buf: List[UInt8], off: Int) -> Float32:
    var v: Float32 = 0.0
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(4): p[i] = buf[off + i]
    return v

def _write_u16(mut buf: List[UInt8], v: UInt16):
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(2): buf.append(p[i])

def _read_u16(buf: List[UInt8], off: Int) -> UInt16:
    var v: UInt16 = 0
    var p = UnsafePointer(to=v).bitcast[UInt8]()
    for i in range(2): p[i] = buf[off + i]
    return v

def _write_rect(mut buf: List[UInt8], r: Rect):
    _write_f32(buf, r.x)
    _write_f32(buf, r.y)
    _write_f32(buf, r.w)
    _write_f32(buf, r.h)

def _read_rect(buf: List[UInt8], off: Int) -> Rect:
    return Rect(
        _read_f32(buf, off),
        _read_f32(buf, off + 4),
        _read_f32(buf, off + 8),
        _read_f32(buf, off + 12),
    )

def _write_color(mut buf: List[UInt8], c: Color):
    _write_u8(buf, c.r)
    _write_u8(buf, c.g)
    _write_u8(buf, c.b)
    _write_u8(buf, c.a)

def _read_color(buf: List[UInt8], off: Int) -> Color:
    return Color(
        _read_u8(buf, off),
        _read_u8(buf, off + 1),
        _read_u8(buf, off + 2),
        _read_u8(buf, off + 3),
    )

def _write_vec2(mut buf: List[UInt8], p: Vec2):
    _write_f32(buf, p.x)
    _write_f32(buf, p.y)

def _read_vec2(buf: List[UInt8], off: Int) -> Vec2:
    return Vec2(_read_f32(buf, off), _read_f32(buf, off + 4))

def _write_header(mut buf: List[UInt8], kind: DrawCmdKind, size: Int32):
    _write_i32(buf, kind)
    _write_i32(buf, size)

# --- Per-variant value structs (read-back convenience holders) ---
# Decoded-command field holders. The buffer never stores instances of these
# — only the field bytes. Used by the typed `read_cmd_*` helpers.

struct CmdHeader(Copyable, Movable):
    """Two-Int32 header (kind, size) beginning every command."""
    var kind: DrawCmdKind
    var size: Int32

    @always_inline
    def __init__(out self, kind: DrawCmdKind, size: Int32):
        self.kind = kind
        self.size = size

struct CmdJump(Copyable, Movable):
    """JUMP: skip the reader to `dst_offset` (absolute byte offset)."""
    var header: CmdHeader
    var dst_offset: Int32

    @always_inline
    def __init__(out self, dst_offset: Int32):
        self.header = CmdHeader(CMD_JUMP, CMD_JUMP_SIZE)
        self.dst_offset = dst_offset

struct CmdClip(Copyable, Movable):
    """CLIP: set the current clip rect."""
    var header: CmdHeader
    var rect: Rect

    @always_inline
    def __init__(out self, rect: Rect):
        self.header = CmdHeader(CMD_CLIP, CMD_CLIP_SIZE)
        self.rect = rect.copy()

struct CmdRect(Copyable, Movable):
    """RECT: filled axis-aligned rectangle."""
    var header: CmdHeader
    var rect: Rect
    var color: Color

    @always_inline
    def __init__(out self, rect: Rect, color: Color):
        self.header = CmdHeader(CMD_RECT, CMD_RECT_SIZE)
        self.rect = rect.copy()
        self.color = color.copy()

struct CmdText(Copyable, Movable):
    """TEXT: variable-length. Trailing UTF-8 bytes follow the fixed prefix;
    in-buffer command size = `CMD_TEXT_FIXED_SIZE + text_byte_len`."""
    var header: CmdHeader
    var font_id: UInt32
    var size_pt: Int32
    var pos: Vec2
    var color: Color
    var text_byte_len: Int32
    var text: String

    def __init__(
        out self,
        font_id: UInt32,
        size_pt: Int32,
        pos: Vec2,
        color: Color,
        text: String,
    ):
        var n = Int32(text.byte_length())
        self.header = CmdHeader(CMD_TEXT, CMD_TEXT_FIXED_SIZE + n)
        self.font_id = font_id
        self.size_pt = size_pt
        self.pos = pos.copy()
        self.color = color.copy()
        self.text_byte_len = n
        self.text = text.copy()

struct CmdIcon(Copyable, Movable):
    """ICON: small-integer icon glyph painted into `rect` with `color`."""
    var header: CmdHeader
    var rect: Rect
    var icon_id: Int32
    var color: Color

    @always_inline
    def __init__(out self, rect: Rect, icon_id: Int32, color: Color):
        self.header = CmdHeader(CMD_ICON, CMD_ICON_SIZE)
        self.rect = rect.copy()
        self.icon_id = icon_id
        self.color = color.copy()

struct CmdImage(Copyable, Movable):
    """IMAGE: textured rect tinted by `tint`. `texture_id` from `mojoui_make_texture`."""
    var header: CmdHeader
    var rect: Rect
    var texture_id: UInt32
    var tint: Color

    @always_inline
    def __init__(out self, rect: Rect, texture_id: UInt32, tint: Color):
        self.header = CmdHeader(CMD_IMAGE, CMD_IMAGE_SIZE)
        self.rect = rect.copy()
        self.texture_id = texture_id
        self.tint = tint.copy()


struct CmdTriangles(Movable):
    """Read-back view of a `CMD_TRIANGLES` record (M3 c46-fix Bug 2).

    Variable-length geometry payload: `n_verts * 5` Float32 values (vertex
    layout `x, y, u, v, color_bits` matching `Backend.draw_batch_lists`) plus
    `n_indices` UInt16 triangle indices into the vertex array, plus an opaque
    `texture_id` (0 = built-in 1x1 white texture for solid color geometry).

    Movable-only (NOT Copyable) on purpose — copying a heap-backed triangle
    payload through the read-back view would defeat the avoid-redundant-copy
    goal. Use `take_verts` / `take_indices` to move the heap fields out for
    forwarding to `Backend.draw_batch_lists`; both reset the field to an
    empty List in place so the partial-destroy borrow-checker wall doesn't
    fire (see `examples/m3_interactive_demo.mojo::_dispatch_triangles`).
    """

    var n_verts: Int32
    var n_indices: Int32
    var texture_id: UInt32
    var verts: List[Float32]
    var indices: List[UInt16]

    def __init__(out self):
        self.n_verts = 0
        self.n_indices = 0
        self.texture_id = 0
        self.verts = List[Float32]()
        self.indices = List[UInt16]()

    def take_verts(mut self) -> List[Float32]:
        """Move `verts` out, reset to an empty list. Avoids the partial-
        destroy borrow-checker wall when forwarding to FFI."""
        var out = self.verts^
        self.verts = List[Float32]()
        return out^

    def take_indices(mut self) -> List[UInt16]:
        """Move `indices` out, reset to an empty list. Companion to
        `take_verts` — keeps the struct in a consistent state for the
        compiler-inserted destructor."""
        var out = self.indices^
        self.indices = List[UInt16]()
        return out^

# --- CommandBuffer — flat byte stream of commands ---

struct CommandBuffer(Movable):
    """Append-only byte buffer of draw commands. Reset per frame in
    `Context.begin_frame()` (M1 c16). `emit_*` methods return the starting
    byte offset of the appended command (retain it to patch JUMPs)."""

    var bytes: List[UInt8]
    """Raw byte storage; commands back-to-back, each prefixed by CmdHeader."""

    def __init__(out self):
        self.bytes = List[UInt8]()

    def reset(mut self):
        """Drop all commands. Called per frame in `Context.begin_frame()`."""
        self.bytes = List[UInt8]()

    @always_inline
    def byte_count(self) -> Int:
        """Total bytes currently in the buffer (== offset of next emit)."""
        return len(self.bytes)

    # ----- emit helpers -------------------------------------------------

    def emit_jump(mut self, dst_offset: Int32) -> Int32:
        """Append a JUMP targeting `dst_offset`. Returns start offset — use
        it with `patch_jump` to update the destination later (z-order trick)."""
        var off = Int32(self.byte_count())
        _write_header(self.bytes, CMD_JUMP, CMD_JUMP_SIZE)
        _write_i32(self.bytes, dst_offset)
        return off

    def emit_clip(mut self, rect: Rect) -> Int32:
        """Append a CLIP command setting the current clip rect."""
        var off = Int32(self.byte_count())
        _write_header(self.bytes, CMD_CLIP, CMD_CLIP_SIZE)
        _write_rect(self.bytes, rect)
        return off

    def emit_rect(mut self, rect: Rect, color: Color) -> Int32:
        """Append a filled-rect draw command."""
        var off = Int32(self.byte_count())
        _write_header(self.bytes, CMD_RECT, CMD_RECT_SIZE)
        _write_rect(self.bytes, rect)
        _write_color(self.bytes, color)
        return off

    def emit_text(mut self, font_id: UInt32, size_pt: Int32, pos: Vec2,
                  color: Color, text: String) -> Int32:
        """Append a text command. Fixed prefix + raw UTF-8 bytes of `text`
        (no NUL — `text_byte_len` is source of truth, mirroring
        `Backend.input_text` sized-buffer reads)."""
        var off = Int32(self.byte_count())
        # Materialize a stable local copy before reading the raw UTF-8 bytes.
        # Live UIs often pass temporary strings from helper functions; copying
        # here keeps the pointer valid for the whole byte-copy loop.
        var stable = text.copy()
        var n = Int32(stable.byte_length())
        _write_header(self.bytes, CMD_TEXT, CMD_TEXT_FIXED_SIZE + n)
        _write_u32(self.bytes, font_id)
        _write_i32(self.bytes, size_pt)
        _write_vec2(self.bytes, pos)
        _write_color(self.bytes, color)
        _write_i32(self.bytes, n)
        var ptr = stable.unsafe_ptr()
        for i in range(Int(n)):
            self.bytes.append(ptr[i])
        return off

    def emit_icon(mut self, rect: Rect, icon_id: Int32, color: Color) -> Int32:
        """Append an icon-glyph draw command."""
        var off = Int32(self.byte_count())
        _write_header(self.bytes, CMD_ICON, CMD_ICON_SIZE)
        _write_rect(self.bytes, rect)
        _write_i32(self.bytes, icon_id)
        _write_color(self.bytes, color)
        return off

    def emit_image(mut self, rect: Rect, texture_id: UInt32, tint: Color) -> Int32:
        """Append a textured-rect draw command (image)."""
        var off = Int32(self.byte_count())
        _write_header(self.bytes, CMD_IMAGE, CMD_IMAGE_SIZE)
        _write_rect(self.bytes, rect)
        _write_u32(self.bytes, texture_id)
        _write_color(self.bytes, tint)
        return off

    def emit_triangles(
        mut self,
        var verts: List[Float32],
        var indices: List[UInt16],
        texture_id: UInt32,
    ) -> Int32:
        """Append a variable-length CMD_TRIANGLES record (M3 c46-fix Bug 2).

        Restores the architectural invariant `widgets -> commands -> walker
        -> Backend` that c51 accidentally broke: the c46 tessellator used to
        call `Backend.draw_batch_lists` directly, bypassing the command
        buffer entirely. After this fix, tessellator functions emit
        CMD_TRIANGLES via `ctx.commands.emit_triangles(...)` and the demo
        walker dispatches CMD_TRIANGLES -> `Backend.draw_batch_lists`.

        Args:
            verts: Flat List[Float32] of (x, y, u, v, color_bits)*n_verts;
                total length MUST be a multiple of 5 (the vertex stride
                matching `Backend.draw_batch_lists` / `_tessellate_rect`).
            indices: Triangle indices into the vertex array (multiple of 3
                expected but not enforced here — the GPU validates).
            texture_id: Opaque texture handle from `mojoui_make_texture`;
                0 = built-in 1x1 white texture for solid-color geometry.

        Returns the starting byte offset of the appended command.

        Layout:

            bytes[off..off+8]              : CmdHeader (kind=CMD_TRIANGLES, size=total)
            bytes[off+8..off+12]           : Int32 n_verts
            bytes[off+12..off+16]          : Int32 n_indices
            bytes[off+16..off+20]          : UInt32 texture_id
            bytes[off+20..off+20+vn*4]     : packed Float32 verts (vn = n_verts*5)
            bytes[end - n_indices*2..end]  : packed UInt16 indices

        Total size = 20 + len(verts)*4 + len(indices)*2.
        """
        var off = Int32(self.byte_count())
        var n_verts = Int32(len(verts) // 5)
        var n_indices = Int32(len(indices))
        var total_size = Int32(
            20 + Int(len(verts)) * 4 + Int(len(indices)) * 2
        )
        # Header
        _write_header(self.bytes, CMD_TRIANGLES, total_size)
        # Metadata
        _write_i32(self.bytes, n_verts)
        _write_i32(self.bytes, n_indices)
        _write_u32(self.bytes, texture_id)
        # Vertex payload
        var nv_floats = Int(len(verts))
        for i in range(nv_floats):
            _write_f32(self.bytes, verts[i])
        # Index payload
        var ni = Int(n_indices)
        for i in range(ni):
            _write_u16(self.bytes, indices[i])
        return off

    # ----- JUMP patching (the z-order primitive) ------------------------

    def patch_jump(mut self, jump_offset: Int32, new_dst: Int32):
        """Rewrite the `dst_offset` field of a previously-emitted JUMP.
        `jump_offset` is the value returned by the original `emit_jump`.
        Only method that mutates already-written bytes — used at `end_frame`
        to chain root containers in z-order (microui JUMP-patching trick).

        Asserts the byte at `jump_offset` is a CMD_JUMP header — silently
        patching into a non-JUMP command would corrupt the 4 bytes of
        whatever field happens to live at `jump_offset+HEADER_SIZE` (e.g.
        the rect.x of a CMD_RECT). See regression notes
        FRAGILE #1. Invariant for callers: only pass an offset returned by
        a prior `emit_jump` on the SAME CommandBuffer.

        Walker invariant for JUMP destinations (see also `read_jump_dst`):
        `new_dst` MUST point forward (>= jump_offset + CMD_JUMP_SIZE) — a
        backward or self-referential JUMP would infinite-loop the walker.
        """
        if self.kind_at(jump_offset) != CMD_JUMP:
            print(
                "MojoUI: patch_jump called on non-CMD_JUMP offset",
                Int(jump_offset),
                "kind=",
                Int(self.kind_at(jump_offset)),
                "— corrupting bytes; check caller",
            )
            return
        var dst_off = Int(jump_offset) + Int(HEADER_SIZE)
        var p = UnsafePointer(to=new_dst).bitcast[UInt8]()
        for i in range(4): self.bytes[dst_off + i] = p[i]

    # ----- header reading (walker support) -------------------------------

    @always_inline
    def kind_at(self, offset: Int32) -> DrawCmdKind:
        """The DrawCmdKind of the command starting at `offset`."""
        return _read_i32(self.bytes, Int(offset))

    @always_inline
    def size_at(self, offset: Int32) -> Int32:
        """The byte size of the command at `offset` (skip to next:
        `next_off = offset + size_at(offset)`)."""
        return _read_i32(self.bytes, Int(offset) + 4)

    def read_jump_dst(self, offset: Int32) -> Int32:
        """Destination offset of a JUMP at `offset` (caller ensures CMD_JUMP).

        WALKER INVARIANT (see regression notes FRAGILE #2):
        a well-formed JUMP destination MUST be strictly greater than the
        JUMP's own offset (forward only). Walkers should defensively check
        that `new_off > prev_off` (or some similar monotonic-advance
        condition) and break if not — a backward / self-referential JUMP
        would otherwise infinite-loop the walker. M1 emitters never emit a
        JUMP at all; M2+ container z-ordering is the first real user.
        """
        return _read_i32(self.bytes, Int(offset) + Int(HEADER_SIZE))

# --- Typed read-back helpers (consumer / test convenience) ---
# Walking with kind_at + size_at suffices for a renderer that switches on
# `kind` and reads fields it needs. These typed reads reconstitute the
# per-variant value structs in one shot.

def read_cmd_header(buf: CommandBuffer, offset: Int32) -> CmdHeader:
    return CmdHeader(buf.kind_at(offset), buf.size_at(offset))

def read_cmd_jump(buf: CommandBuffer, offset: Int32) -> CmdJump:
    return CmdJump(buf.read_jump_dst(offset))

def read_cmd_clip(buf: CommandBuffer, offset: Int32) -> CmdClip:
    var r = _read_rect(buf.bytes, Int(offset) + Int(HEADER_SIZE))
    return CmdClip(r)

def read_cmd_rect(buf: CommandBuffer, offset: Int32) -> CmdRect:
    var base = Int(offset) + Int(HEADER_SIZE)
    var r = _read_rect(buf.bytes, base)
    var c = _read_color(buf.bytes, base + Int(_RECT_BYTES))
    return CmdRect(r, c)

def read_cmd_text(buf: CommandBuffer, offset: Int32) -> CmdText:
    var base = Int(offset) + Int(HEADER_SIZE)
    var font_id = _read_u32(buf.bytes, base)
    var size_pt = _read_i32(buf.bytes, base + 4)
    var pos = _read_vec2(buf.bytes, base + 8)
    var color = _read_color(buf.bytes, base + 8 + Int(_VEC2_BYTES))
    var n = _read_i32(
        buf.bytes, base + 8 + Int(_VEC2_BYTES) + Int(_COLOR_BYTES)
    )
    var text_start = Int(offset) + Int(CMD_TEXT_FIXED_SIZE)
    var n_int = Int(n)
    var bytes = List[UInt8](capacity=n_int)
    for i in range(n_int):
        bytes.append(buf.bytes[text_start + i])
    var text = String(unsafe_from_utf8=bytes)
    return CmdText(font_id, size_pt, pos, color, text)

def read_cmd_icon(buf: CommandBuffer, offset: Int32) -> CmdIcon:
    var base = Int(offset) + Int(HEADER_SIZE)
    var r = _read_rect(buf.bytes, base)
    var icon_id = _read_i32(buf.bytes, base + Int(_RECT_BYTES))
    var c = _read_color(buf.bytes, base + Int(_RECT_BYTES) + 4)
    return CmdIcon(r, icon_id, c)

def read_cmd_image(buf: CommandBuffer, offset: Int32) -> CmdImage:
    var base = Int(offset) + Int(HEADER_SIZE)
    var r = _read_rect(buf.bytes, base)
    var texture_id = _read_u32(buf.bytes, base + Int(_RECT_BYTES))
    var tint = _read_color(buf.bytes, base + Int(_RECT_BYTES) + 4)
    return CmdImage(r, texture_id, tint)

def read_cmd_triangles(buf: CommandBuffer, offset: Int32) raises -> CmdTriangles:
    """Decode a CMD_TRIANGLES record (M3 c46-fix Bug 2).

    Allocates fresh `List[Float32]` + `List[UInt16]` and copies the payload
    out of the buffer — caller owns the returned struct. Raises if the
    command at `offset` is not a CMD_TRIANGLES (defensive: would otherwise
    silently misinterpret unrelated bytes as a triangle batch).
    """
    if buf.kind_at(offset) != CMD_TRIANGLES:
        raise Error(
            "read_cmd_triangles: not a CMD_TRIANGLES at offset "
            + String(Int(offset))
        )
    var data_off = Int(offset) + Int(HEADER_SIZE)
    var n_verts = _read_i32(buf.bytes, data_off)
    var n_indices = _read_i32(buf.bytes, data_off + 4)
    var texture_id = _read_u32(buf.bytes, data_off + 8)
    var verts = List[Float32]()
    var verts_start = data_off + 12
    var n_floats = Int(n_verts) * 5
    for i in range(n_floats):
        verts.append(_read_f32(buf.bytes, verts_start + i * 4))
    var indices = List[UInt16]()
    var idx_start = verts_start + Int(n_verts) * 20
    for i in range(Int(n_indices)):
        indices.append(_read_u16(buf.bytes, idx_start + i * 2))
    var out = CmdTriangles()
    out.n_verts = n_verts
    out.n_indices = n_indices
    out.texture_id = texture_id
    out.verts = verts^
    out.indices = indices^
    return out^
