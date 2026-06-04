"""VersionPeek — parse the `version` field of a workflow JSON before full deserialization.

Per EriGui (audit_erigui_nodes.md §"Serde Schema"): the workflow JSON's first
field is always `"version": <int>`. Loaders peek the version BEFORE attempting
the full parse, so a v1 loader that sees a v2 file rejects it with a structured
`UnsupportedVersion` error instead of a generic mid-stream JSON parse error
(which would be impossible to recover from cleanly — the parser might have
already constructed half a graph).

STANDALONE — does not depend on the c34 JSON parser. Substring-scans the
ENTIRE `raw` input for the `"version"` literal then reads ASCII digits.
Returns `VersionPeek(version=SUPPORTED, found=False)` when the key is absent
so callers can either accept the back-compat default or reject `found=False`.
Raises on malformed key/value (missing colon, non-integer).

Why full-scan (not a fixed prefix window): `emit_json` (c34) sorts object
keys alphabetically. For workflow JSON with top-level keys
`edges < nodes < version` (alpha order), `version` is emitted LAST. A
fixed-prefix scan (e.g. 512 bytes) silently misses `version` on any
workflow large enough that the key lands past the window — defeating the
peek-before-parse gate. Per M2.5 skeptic BLOCKER #1, the scan now covers
the full input. Substring search is O(n) and cheap relative to
`parse_json` itself, so there's no measurable overhead.
"""

# ============================================================================
# Supported version constant
# ============================================================================

comptime SUPPORTED_WORKFLOW_VERSION: Int32 = 1
"""Bump this when the serialized workflow schema changes. The v1 → v2 jump
will land alongside the migration logic (out of scope for M2.5)."""

comptime _PEEK_SEARCH_LIMIT: Int = -1
"""Reserved sentinel — no longer used as a fixed prefix limit. peek_version
scans the entire input now (skeptic BLOCKER #1 fix). Kept as a named comptime
so future callers grepping for the symbol can find this comment instead of
silently re-introducing a prefix window."""


# ============================================================================
# VersionPeek result struct
# ============================================================================


struct VersionPeek(Copyable, Movable):
    """The outcome of `peek_version`.

    Fields:
        version: The parsed version number, or `SUPPORTED_WORKFLOW_VERSION` if
                 no version field was found (back-compat default).
        found:   True if the `"version"` key was located AND a valid integer
                 was parsed; False if the key was absent. (Malformed values
                 raise rather than returning found=False.)
    """

    var version: Int32
    var found: Bool

    def __init__(out self):
        self.version = SUPPORTED_WORKFLOW_VERSION
        self.found = False

    def __init__(out self, version: Int32, found: Bool):
        self.version = version
        self.found = found


# ============================================================================
# Top-level peek_version
# ============================================================================


def peek_version(raw: String) raises -> VersionPeek:
    """Scan the entirety of `raw` for `"version": <int>`.

    Approach: substring-search for the literal `"version"`, then walk whitespace
    + the colon + whitespace + ASCII digits. Does NOT do full JSON parsing —
    just enough to extract the integer version number for a peek-before-parse
    schema gate.

    Returns a `VersionPeek` with `found=False` (and `version=SUPPORTED_WORKFLOW_VERSION`)
    if the literal `"version"` key is not found anywhere in `raw`. Raises if
    the `"version"` key IS found but is malformed (missing colon, non-integer
    value).

    Scan window: the FULL input length. See file docstring — `emit_json` sorts
    keys alphabetically, so `"version"` is emitted last for workflow JSON. A
    fixed-prefix window would silently miss the key on any non-trivial payload
    (M2.5 skeptic BLOCKER #1).
    """
    var peek = VersionPeek()
    var raw_len = raw.byte_length()
    if raw_len == 0:
        return peek^

    var key = String("\"version\"")
    var key_len = key.byte_length()
    var pos = _find_substr(raw, key, 0, raw_len)
    if pos < 0:
        return peek^

    # Skip past the `"version"` key.
    pos = pos + key_len
    var hp = raw.unsafe_ptr()

    # Walk whitespace then require a colon.
    var saw_colon = False
    while pos < raw_len:
        var b = Int(hp[pos])
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
            pos = pos + 1
            continue
        if b == 0x3A:  # ':'
            pos = pos + 1
            saw_colon = True
            break
        raise Error("peek_version: malformed version key (expected ':' after \"version\")")
    if not saw_colon:
        raise Error("peek_version: end of input before ':' after \"version\"")

    # Skip whitespace between colon and number.
    while pos < raw_len:
        var b = Int(hp[pos])
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
            pos = pos + 1
            continue
        break

    # Parse one ASCII unsigned integer. JSON strings ("1"), floats (1.0), etc.
    # are rejected — the schema mandates an integer version.
    var num: Int32 = 0
    var any_digit = False
    while pos < raw_len:
        var b = Int(hp[pos])
        if b >= 0x30 and b <= 0x39:
            num = num * Int32(10) + Int32(b - 0x30)
            any_digit = True
            pos = pos + 1
        else:
            break
    if not any_digit:
        raise Error("peek_version: malformed version value (expected unsigned integer)")

    peek.version = num
    peek.found = True
    return peek^


# ============================================================================
# Internal helpers
# ============================================================================


def _find_substr(haystack: String, needle: String, start: Int, limit: Int) -> Int:
    """Naive byte-level substring search within `[start, limit)` of `haystack`.

    Returns the offset of the first occurrence, or -1 if not found. `limit` is
    the upper bound of the search window (typically `_PEEK_SEARCH_LIMIT` or the
    haystack length, whichever is smaller).
    """
    var n = needle.byte_length()
    var h_len = haystack.byte_length()
    if n == 0:
        return start
    if limit > h_len:
        return -1 if start >= h_len else _find_substr(haystack, needle, start, h_len)
    # Upper bound: last position where `needle` could fit fully before `limit`.
    var end = limit - n + 1
    if end <= start:
        return -1
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(start, end):
        var matched = True
        for j in range(n):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return i
    return -1
