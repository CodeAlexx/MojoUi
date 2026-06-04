"""Smoke tests for `mojoui/serde/version.mojo` — M2.5 chunk 35.

Run: `pixi run test-version`

Exercises `peek_version` (the EriGui peek-before-parse pattern):

  * Spaced + spaceless + multi-line `"version": <int>` shapes parse correctly.
  * Absent version key returns `found=False` + default `SUPPORTED_WORKFLOW_VERSION`.
  * Malformed key/value (string value, missing colon) raises.
  * Empty input is a graceful no-op (returns default, does not raise).
  * `_find_substr` returns the correct offset for present, -1 for absent.

No FFI involved — runs cleanly under `mojo run` (JIT) without
`libmojoui_floor.so` being loaded.
"""

from mojoui.serde.version import (
    VersionPeek,
    SUPPORTED_WORKFLOW_VERSION,
    peek_version,
    _find_substr,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


# ----------------------------------------------------------------------------
# Test 1 — spaced version field
# ----------------------------------------------------------------------------


def test_spaced_version() raises:
    var raw = String("{\"version\": 1, \"nodes\": []}")
    var peek = peek_version(raw)
    if not peek.found:
        _fail("test 1: expected found=True for spaced \"version\": 1")
    if peek.version != Int32(1):
        _fail("test 1: expected version=1 got " + String(peek.version))


# ----------------------------------------------------------------------------
# Test 2 — spaceless version field
# ----------------------------------------------------------------------------


def test_spaceless_version() raises:
    var raw = String("{\"version\":2,\"nodes\":[]}")
    var peek = peek_version(raw)
    if not peek.found:
        _fail("test 2: expected found=True for spaceless \"version\":2")
    if peek.version != Int32(2):
        _fail("test 2: expected version=2 got " + String(peek.version))


# ----------------------------------------------------------------------------
# Test 3 — version field absent → default + found=False
# ----------------------------------------------------------------------------


def test_absent_version() raises:
    var raw = String("{\"nodes\": []}")
    var peek = peek_version(raw)
    if peek.found:
        _fail("test 3: expected found=False when version key absent")
    if peek.version != SUPPORTED_WORKFLOW_VERSION:
        _fail("test 3: expected version=SUPPORTED_WORKFLOW_VERSION as default")


# ----------------------------------------------------------------------------
# Test 4 — multi-digit version
# ----------------------------------------------------------------------------


def test_multi_digit_version() raises:
    var raw = String("{\"version\":42}")
    var peek = peek_version(raw)
    if not peek.found:
        _fail("test 4: expected found=True for \"version\":42")
    if peek.version != Int32(42):
        _fail("test 4: expected version=42 got " + String(peek.version))


# ----------------------------------------------------------------------------
# Test 5 — string version value (rejected: not an integer)
# ----------------------------------------------------------------------------


def test_string_value_rejected() raises:
    var raw = String("{\"version\": \"1\"}")
    var raised = False
    try:
        var _peek = peek_version(raw)
    except e:
        raised = True
    if not raised:
        _fail("test 5: expected raise for string value \"1\"")


# ----------------------------------------------------------------------------
# Test 6 — missing colon (rejected)
# ----------------------------------------------------------------------------


def test_missing_colon_rejected() raises:
    var raw = String("{\"version\" 1}")
    var raised = False
    try:
        var _peek = peek_version(raw)
    except e:
        raised = True
    if not raised:
        _fail("test 6: expected raise for missing colon after \"version\"")


# ----------------------------------------------------------------------------
# Test 7 — newlines and whitespace around the value are tolerated
# ----------------------------------------------------------------------------


def test_newline_whitespace_value() raises:
    var raw = String("{\"version\":\n  1\n}")
    var peek = peek_version(raw)
    if not peek.found:
        _fail("test 7: expected found=True with newlines around value")
    if peek.version != Int32(1):
        _fail("test 7: expected version=1 got " + String(peek.version))


# ----------------------------------------------------------------------------
# Test 8 — _find_substr offset correctness
# ----------------------------------------------------------------------------


def test_find_substr() raises:
    var hay = String("hello world banana")
    var off1 = _find_substr(hay, String("world"), 0, hay.byte_length())
    if off1 != 6:
        _fail("test 8a: expected offset 6 for 'world' in 'hello world banana', got " + String(off1))
    var off2 = _find_substr(hay, String("zzz"), 0, hay.byte_length())
    if off2 != -1:
        _fail("test 8b: expected -1 for absent needle 'zzz', got " + String(off2))
    var off3 = _find_substr(hay, String("hello"), 0, hay.byte_length())
    if off3 != 0:
        _fail("test 8c: expected offset 0 for 'hello' at start, got " + String(off3))


# ----------------------------------------------------------------------------
# Test 9 — empty string is a graceful no-op
# ----------------------------------------------------------------------------


def test_empty_string() raises:
    var raw = String("")
    var peek = peek_version(raw)
    if peek.found:
        _fail("test 9: expected found=False for empty string")
    if peek.version != SUPPORTED_WORKFLOW_VERSION:
        _fail("test 9: expected default SUPPORTED_WORKFLOW_VERSION for empty input")


# ----------------------------------------------------------------------------
# Test 10 — version key past the legacy 512-byte prefix (M2.5 BLOCKER #1 regression)
# ----------------------------------------------------------------------------


def test_version_past_legacy_prefix() raises:
    """Per M2.5 skeptic BLOCKER #1: `emit_json` sorts keys alphabetically, so
    `"version"` ends up last in workflow JSON. A fixed-prefix scan window
    (the old 512-byte cap) silently missed it on any non-trivial payload.

    This regression test synthesizes a JSON where the `"version"` literal
    sits past byte 256 (well past any plausible fixed prefix would have to
    be raised to in-spirit) and asserts that peek_version finds it.
    """
    # Build a >256-byte preamble of edges+nodes before "version", then v=2.
    var raw = String("{\"edges\":[")
    # Append ~50 short edge stubs to push the version offset well past 256.
    for _i in range(50):
        raw = raw + "{\"from\":\"node_xx\",\"to\":\"node_yy\"},"
    raw = raw + "{\"from\":\"a\",\"to\":\"b\"}],\"nodes\":[],\"version\":2}"

    if raw.byte_length() < 256:
        _fail("test 10: setup error — synthesized JSON too short to test")

    var peek = peek_version(raw)
    if not peek.found:
        _fail(
            "test 10: BLOCKER regression — version=2 past byte 256 not"
            " detected (raw is "
            + String(raw.byte_length())
            + " bytes)"
        )
    if peek.version != Int32(2):
        _fail(
            "test 10: expected version=2, got " + String(peek.version)
        )


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------


def main() raises:
    test_spaced_version()
    test_spaceless_version()
    test_absent_version()
    test_multi_digit_version()
    test_string_value_rejected()
    test_missing_colon_rejected()
    test_newline_whitespace_value()
    test_find_substr()
    test_empty_string()
    test_version_past_legacy_prefix()
    print("PASS: all 10 mojoui/serde/version.mojo smoke tests")
