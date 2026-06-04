"""Smoke tests for `mojoui/core/id.mojo`.

Run: `pixi run test-id`
"""

from mojoui.core.id import (
    fnv1a_32,
    hash_str,
    hash_int,
    derive_id,
    ImmediateId,
    IMM_ID_NONE,
    FNV1A_OFFSET_32,
    FNV1A_PRIME_32,
    RetainedIdAllocator,
    RetainedId,
    RET_ID_NONE,
    retained_index,
    retained_generation,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# ImmediateId / FNV-1a tests
# ----------------------------------------------------------------------------

def test_fnv1a_canonical() raises:
    """FNV-1a 32-bit hash of "hello" is the well-known constant 0x4F9F2CAB.
    If this fails the algorithm or constants are wrong."""
    var h = hash_str("hello")
    if UInt32(h) != UInt32(0x4F9F2CAB):
        _fail(
            String("fnv1a_32('hello') expected 0x4F9F2CAB got ") + String(UInt32(h))
        )


def test_fnv1a_constants() raises:
    """Confirm the standard FNV-1a 32-bit constants."""
    if UInt32(FNV1A_OFFSET_32) != UInt32(0x811C9DC5):
        _fail("FNV1A_OFFSET_32 wrong")
    if UInt32(FNV1A_PRIME_32) != UInt32(0x01000193):
        _fail("FNV1A_PRIME_32 wrong")


def test_imm_id_none_is_zero() raises:
    if UInt32(IMM_ID_NONE) != UInt32(0):
        _fail("IMM_ID_NONE must be 0")


def test_hash_str_stable() raises:
    """Hashing the same string twice yields the same ID."""
    var a = hash_str("button_ok")
    var b = hash_str("button_ok")
    if UInt32(a) != UInt32(b):
        _fail("hash_str not stable")


def test_hash_str_distinct() raises:
    """Different strings hash to different IDs (statistically certain for FNV)."""
    var a = hash_str("a")
    var b = hash_str("b")
    if UInt32(a) == UInt32(b):
        _fail("hash_str('a') collided with hash_str('b')")


def test_derive_id_contextual() raises:
    """The same child key under different parents yields different IDs."""
    var parent_a = hash_str("window_a")
    var parent_b = hash_str("window_b")
    var child_under_a = derive_id(parent_a, "ok")
    var child_under_b = derive_id(parent_b, "ok")
    if UInt32(child_under_a) == UInt32(child_under_b):
        _fail("derive_id is not contextual — same child under different parents collided")


def test_derive_id_same_parent_different_keys() raises:
    """Under one parent, different keys still yield different IDs."""
    var parent = hash_str("dialog")
    var a = derive_id(parent, "ok")
    var b = derive_id(parent, "cancel")
    if UInt32(a) == UInt32(b):
        _fail("derive_id(p, 'ok') collided with derive_id(p, 'cancel')")


def test_hash_int_distinct() raises:
    """Different ints hash to different IDs."""
    var a = hash_int(42)
    var b = hash_int(43)
    if UInt32(a) == UInt32(b):
        _fail("hash_int(42) collided with hash_int(43)")


def test_hash_distribution_small_set() raises:
    """Hashes of "0".."9" are all distinct (no collisions)."""
    var hashes = List[UInt32]()
    for i in range(10):
        var s = String(i)
        hashes.append(UInt32(hash_str(s)))
    for i in range(10):
        for j in range(i + 1, 10):
            if hashes[i] == hashes[j]:
                _fail(String("hash collision between '") + String(i) + String("' and '") + String(j) + String("'"))


# ----------------------------------------------------------------------------
# RetainedId / generational allocator tests
# ----------------------------------------------------------------------------

def test_alloc_returns_nonzero() raises:
    """A fresh allocator's first alloc is never RET_ID_NONE."""
    var a = RetainedIdAllocator()
    var id = a.alloc()
    if UInt64(id) == UInt64(RET_ID_NONE):
        _fail("first alloc returned RET_ID_NONE")


def test_alloc_ids_distinct() raises:
    """Two consecutive allocs return distinct IDs (different indices)."""
    var a = RetainedIdAllocator()
    var id1 = a.alloc()
    var id2 = a.alloc()
    if UInt64(id1) == UInt64(id2):
        _fail("two allocs returned the same ID")
    if retained_index(id1) == retained_index(id2):
        _fail("two allocs returned the same slot index")


def test_alloc_free_realloc_bumps_generation() raises:
    """Alloc → free → alloc reuses the slot but bumps the generation,
    so the new ID has the same index but a higher generation."""
    var a = RetainedIdAllocator()
    var id1 = a.alloc()
    a.free(id1)
    var id2 = a.alloc()
    if retained_index(id1) != retained_index(id2):
        _fail("realloc should reuse the freed slot index")
    if retained_generation(id2) <= retained_generation(id1):
        _fail("realloc should bump the generation")
    if UInt64(id1) == UInt64(id2):
        _fail("old and reallocated IDs must differ")


def test_freed_id_is_invalid() raises:
    """After free+realloc, the old ID's is_valid() returns False."""
    var a = RetainedIdAllocator()
    var id1 = a.alloc()
    if not a.is_valid(id1):
        _fail("freshly-alloced ID should be valid")
    a.free(id1)
    var id2 = a.alloc()  # reuses slot, bumps gen → invalidates id1
    if a.is_valid(id1):
        _fail("freed-then-reallocated old ID should be invalid")
    if not a.is_valid(id2):
        _fail("newly-alloced ID should be valid")


def test_ret_id_none_invalid() raises:
    var a = RetainedIdAllocator()
    if a.is_valid(RET_ID_NONE):
        _fail("RET_ID_NONE should never be valid")


def test_free_none_is_noop() raises:
    """Freeing RET_ID_NONE must not panic or corrupt state."""
    var a = RetainedIdAllocator()
    a.free(RET_ID_NONE)
    # Subsequent alloc still works, returns slot 1.
    var id = a.alloc()
    if retained_index(id) != UInt64(1):
        _fail("free(RET_ID_NONE) corrupted free_list")


def test_pack_decode_roundtrip() raises:
    """The retained_index + retained_generation helpers round-trip through alloc."""
    var a = RetainedIdAllocator()
    var id1 = a.alloc()  # gen=0, idx=1
    if retained_index(id1) != UInt64(1):
        _fail(String("first ID's index should be 1, got ") + String(retained_index(id1)))
    if UInt16(retained_generation(id1)) != UInt16(0):
        _fail("first ID's generation should be 0")
    a.free(id1)
    var id2 = a.alloc()  # gen=1, idx=1
    if retained_index(id2) != UInt64(1):
        _fail("reallocated ID should keep index=1")
    if UInt16(retained_generation(id2)) != UInt16(1):
        _fail("reallocated ID's generation should be 1")


def test_100_cycles_generation_counter() raises:
    """100 alloc→free cycles on the same slot bump the generation 100 times,
    proving no overflow / drift in the List[UInt16] generation table."""
    var a = RetainedIdAllocator()
    var id = a.alloc()  # gen=0
    var last_gen: UInt16 = 0
    for _ in range(100):
        a.free(id)
        id = a.alloc()
        var g = retained_generation(id)
        if UInt16(g) != UInt16(last_gen + UInt16(1)):
            _fail(String("generation did not increment by exactly 1 (was ") + String(UInt16(last_gen)) + String(", now ") + String(UInt16(g)) + String(")"))
        last_gen = g
    if UInt16(last_gen) != UInt16(100):
        _fail(String("after 100 cycles, generation should be 100, got ") + String(UInt16(last_gen)))
    if not a.is_valid(id):
        _fail("after 100 cycles, current ID should still be valid")


def main() raises:
    test_fnv1a_canonical()
    test_fnv1a_constants()
    test_imm_id_none_is_zero()
    test_hash_str_stable()
    test_hash_str_distinct()
    test_derive_id_contextual()
    test_derive_id_same_parent_different_keys()
    test_hash_int_distinct()
    test_hash_distribution_small_set()
    test_alloc_returns_nonzero()
    test_alloc_ids_distinct()
    test_alloc_free_realloc_bumps_generation()
    test_freed_id_is_invalid()
    test_ret_id_none_invalid()
    test_free_none_is_noop()
    test_pack_decode_roundtrip()
    test_100_cycles_generation_counter()
    print("PASS: id smoke tests (17 tests)")
