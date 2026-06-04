"""Command-buffer renderer adapter for live MojoUI windows.

This is the shared bridge from `Context.commands` to `Backend`. Keeping the
walker here prevents demos from drifting: `CMD_CLIP`, `CMD_IMAGE`, and
`CMD_TRIANGLES` should have one live interpretation.
"""

from mojoui.core.context import Context
from mojoui.core.commands import (
    CommandBuffer,
    CMD_JUMP,
    CMD_CLIP,
    CMD_RECT,
    CMD_TEXT,
    CMD_ICON,
    CMD_IMAGE,
    CMD_TRIANGLES,
    CmdTriangles,
    read_cmd_clip,
    read_cmd_rect,
    read_cmd_text,
    read_cmd_image,
    read_cmd_triangles,
)
from mojoui.render.backend import Backend


def _dispatch_triangles(mut cmd: CmdTriangles) -> Int32:
    var verts = cmd.take_verts()
    var indices = cmd.take_indices()
    return Backend.draw_batch_lists(verts^, indices^, cmd.texture_id)


def render_command_buffer(buf: CommandBuffer, label: String) raises -> Int32:
    """Walk `buf` in document order and submit supported commands.

    Returns the count of submitted draw commands. `CMD_ICON` is intentionally
    skipped until the icon atlas exists; clipping state still advances for
    every `CMD_CLIP` command.
    """
    var off: Int32 = 0
    var end_off = Int32(buf.byte_count())
    var submitted: Int32 = 0
    while off < end_off:
        if off < Int32(0):
            print(label, "walker aborted: negative offset", Int(off))
            return submitted
        var kind = buf.kind_at(off)
        if kind == CMD_JUMP:
            var prev_off = off
            off = buf.read_jump_dst(off)
            if off <= prev_off or off > end_off:
                print(label, "walker aborted: invalid JUMP at", Int(prev_off))
                return submitted
            continue

        var size = buf.size_at(off)
        if size <= Int32(0) or off + size > end_off:
            print(label, "walker aborted: invalid command size at", Int(off))
            return submitted

        if kind == CMD_CLIP:
            var cmd = read_cmd_clip(buf, off)
            Backend.set_clip(cmd.rect.copy())
        elif kind == CMD_RECT:
            var cmd = read_cmd_rect(buf, off)
            Backend.draw_rect(cmd.rect.copy(), cmd.color.copy())
            submitted = submitted + Int32(1)
        elif kind == CMD_TEXT:
            var cmd = read_cmd_text(buf, off)
            _ = Backend.draw_text(
                cmd.font_id,
                cmd.size_pt,
                cmd.text,
                cmd.pos.copy(),
                cmd.color.copy(),
            )
            submitted = submitted + Int32(1)
        elif kind == CMD_IMAGE:
            var cmd = read_cmd_image(buf, off)
            Backend.draw_image_rect(
                cmd.rect.copy(),
                cmd.texture_id,
                cmd.tint.copy(),
            )
            submitted = submitted + Int32(1)
        elif kind == CMD_TRIANGLES:
            var cmd = read_cmd_triangles(buf, off)
            submitted = submitted + _dispatch_triangles(cmd)
        elif kind == CMD_ICON:
            pass

        off = off + size
    return submitted


def render_context_commands(mut ctx: Context, label: String) raises -> Int32:
    """Render `ctx.commands` through the shared live backend adapter."""
    return render_command_buffer(ctx.commands, label)
