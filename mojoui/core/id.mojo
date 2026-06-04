"""Two ID systems for MojoUI.

System 1 — `ImmediateId` (UInt32): FNV-1a hash for immediate-mode widget identity.
The seed is the parent's ID (top of the `Context.id_stack`), so the same label
under different parents hashes to different IDs. Mirrors microui (`mu_Id`,
`mu_get_id`, `mu_push_id`).

System 2 — `RetainedId` (UInt64): index (low 48 bits) + generation (high 16 bits)
for retained-mode Node graph IDs. Free-listed slots have their generation bumped
on reuse, so dangling IDs from before a free become invalid. Replaces Rust's
`slotmap::DefaultKey` (Mojo has no slotmap crate — see AUDIT_erigui_core.md).

The two systems do NOT share a type. Different problems, different solutions.
This module ships hashing + allocation primitives only; the `id_stack` lives in
`Context` (chunk 16).
"""

from std.memory import UnsafePointer
from std.builtin.type_aliases import ImmutAnyOrigin


# ============================================================================
# System 1: ImmediateId — FNV-1a 32-bit contextual hash
# ============================================================================

comptime ImmediateId = UInt32

comptime IMM_ID_NONE: ImmediateId = 0
"""Sentinel value for "no widget". No real widget hashes to 0 in practice
(probability is 2^-32) — if it does, it just collides harmlessly with NONE."""

comptime FNV1A_OFFSET_32: UInt32 = 0x811C9DC5
"""FNV-1a 32-bit offset basis (= 2166136261). Standard reference constant."""

comptime FNV1A_PRIME_32: UInt32 = 0x01000193
"""FNV-1a 32-bit prime (= 16777619). Standard reference constant."""


def fnv1a_32(
    bytes: UnsafePointer[UInt8, ImmutAnyOrigin],
    length: Int,
    seed: UInt32 = FNV1A_OFFSET_32,
) -> ImmediateId:
    """FNV-1a 32-bit hash.

    Args:
        bytes: Pointer to the data to hash.
        length: Number of bytes to hash.
        seed: Starting hash value. Use `FNV1A_OFFSET_32` for a fresh hash;
              use a parent ID to derive a contextual child ID.

    Returns:
        The 32-bit hash as an `ImmediateId`.
    """
    var hash: UInt32 = seed
    for i in range(length):
        hash = hash ^ UInt32(bytes[i])
        hash = hash * FNV1A_PRIME_32
    return hash


def hash_str(s: String, seed: UInt32 = FNV1A_OFFSET_32) -> ImmediateId:
    """Hash a `String`'s bytes (UTF-8 storage, NUL terminator NOT included)."""
    return fnv1a_32(s.unsafe_ptr(), s.byte_length(), seed)


def hash_int(i: Int64, seed: UInt32 = FNV1A_OFFSET_32) -> ImmediateId:
    """Hash an `Int64` (useful for loop-iteration widget IDs).

    Packs the int little-endian into 8 bytes then runs FNV-1a over them.
    """
    var buf = InlineArray[UInt8, 8](fill=0)
    for k in range(8):
        buf[k] = UInt8((i >> Int64(k * 8)) & 0xFF)
    return fnv1a_32(buf.unsafe_ptr(), 8, seed)


def derive_id(parent: ImmediateId, child_key: String) -> ImmediateId:
    """Hash `child_key` seeded by `parent` — the contextual-ID primitive.

    `Context.push_id(key)` pushes `derive_id(current_top, key)` onto the
    id_stack; widgets then call `hash_str(label, seed=top())` to get their
    final per-widget ID.
    """
    return hash_str(child_key, seed=parent)


# ============================================================================
# System 2: RetainedId — generational UInt64 for retained Node graph IDs
# ============================================================================

comptime RetainedId = UInt64

comptime RET_ID_NONE: RetainedId = 0
"""Reserved null. Real IDs are never 0 because `next_index` starts at 1
and the high 16 bits (generation) start at 0, so the first ID is `1`."""

comptime _RET_INDEX_MASK: UInt64 = 0x0000_FFFF_FFFF_FFFF
comptime _RET_GEN_SHIFT: UInt64 = 48


@always_inline
def retained_index(id: RetainedId) -> UInt64:
    """Decode the index (low 48 bits) of a `RetainedId`."""
    return id & _RET_INDEX_MASK


@always_inline
def retained_generation(id: RetainedId) -> UInt16:
    """Decode the generation (high 16 bits) of a `RetainedId`."""
    return UInt16((id >> _RET_GEN_SHIFT) & 0xFFFF)


struct RetainedIdAllocator(Copyable, Movable):
    """Vends and recycles `RetainedId`s. Owned by `Graph` (M2.5).

    Layout: generation is the high 16 bits, index is the low 48 bits.
    Index 0 is reserved (`RET_ID_NONE`), so `next_index` starts at 1.
    Generation wraps at 2^16 — a slot freed and reused 65 536 times will
    hand out an ID that collides with the very first ID for that slot. In
    practice this is astronomically unlikely for a UI node graph.
    """

    var next_index: UInt64
    """Next monotonically-increasing slot index when the free list is empty.
    Starts at 1; slot 0 is reserved as `RET_ID_NONE`."""

    var free_list: List[UInt64]
    """Indices of freed slots waiting to be reused (LIFO)."""

    var generations: List[UInt16]
    """Per-slot generation counter. `generations[idx - 1]` is the *current*
    generation of slot `idx` (the `-1` because slot 0 is reserved and never
    appears in this table). IDs with a lower generation are stale."""

    def __init__(out self):
        self.next_index = 1  # Slot 0 reserved as RET_ID_NONE.
        self.free_list = List[UInt64]()
        self.generations = List[UInt16]()

    def alloc(mut self) -> RetainedId:
        """Return a fresh `RetainedId`. Reuses a freed slot if any, otherwise
        extends the slot table. The returned ID's generation matches the
        current slot generation; previously-freed IDs for the same slot are
        now invalid (their generation is one lower).
        """
        var idx: UInt64
        if len(self.free_list) > 0:
            idx = self.free_list.pop()
            # Bump generation on reuse so old IDs for this slot become invalid.
            var slot = Int(idx) - 1
            self.generations[slot] = self.generations[slot] + 1
        else:
            idx = self.next_index
            self.next_index = self.next_index + 1
            self.generations.append(0)  # Fresh slot starts at generation 0.
        var gen: UInt64 = UInt64(self.generations[Int(idx) - 1])
        return (gen << _RET_GEN_SHIFT) | (idx & _RET_INDEX_MASK)

    def free(mut self, id: RetainedId):
        """Recycle an ID's slot. The next `alloc` that picks this slot will
        bump the generation, making `id` invalid from then on."""
        if id == RET_ID_NONE:
            return
        var idx = id & _RET_INDEX_MASK
        self.free_list.append(idx)

    def is_valid(self, id: RetainedId) -> Bool:
        """True iff `id`'s generation matches the slot's current generation.

        Returns False for `RET_ID_NONE`, out-of-range indices, and stale IDs
        whose slot was freed and reallocated (generation no longer matches).
        """
        if id == RET_ID_NONE:
            return False
        var idx = Int(id & _RET_INDEX_MASK)
        var gen = UInt16((id >> _RET_GEN_SHIFT) & 0xFFFF)
        if idx < 1 or idx - 1 >= len(self.generations):
            return False
        return self.generations[idx - 1] == gen
