"""Smoke tests for `mojoui/serde/json.mojo` (M2.5 c34).

Run: `pixi run test-json`.

Coverage:
  1. Emit scalars: null, true, false, integer 0, integer 3, float 3.14,
     empty string, simple ASCII string.
  2. Emit string with JSON escape: `"hello\\nworld"` → `"\"hello\\nworld\""`.
  3. Emit empty array, empty object → "[]", "{}".
  4. Emit array of mixed kinds: [1, "two", true, null]
     → "[1,\"two\",true,null]".
  5. Emit object with insertion-unsorted keys: {b:1, a:2, c:3}
     → "{\"a\":2,\"b\":1,\"c\":3}" (sorted output, EriGui invariant).
  6. Round-trip: parse(emit(v)) ≡ v structurally for each kind.
  7. Parse error on unexpected token (lone `,`).
  8. Parse error on trailing content (`null xxx`).
  9. Parse negative + fractional number: "-3.14" → -3.14.
 10. get_object_field on missing key returns null.
"""

from mojoui.serde.json import (
    JsonValue, JK_NULL, JK_BOOL, JK_NUMBER, JK_STRING, JK_ARRAY, JK_OBJECT,
    emit_json, parse_json,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def _expect_eq_s(actual: String, expected: String, label: String) raises:
    if actual != expected:
        print("expected:", expected)
        print("actual:  ", actual)
        _fail(label)


# ----------------------------------------------------------------------------
# Test 1: Emit scalars.
# ----------------------------------------------------------------------------


def test_emit_scalars() raises:
    _expect_eq_s(emit_json(JsonValue.null()), String("null"), String("null"))
    _expect_eq_s(emit_json(JsonValue.bool_(True)), String("true"), String("true"))
    _expect_eq_s(emit_json(JsonValue.bool_(False)), String("false"), String("false"))
    _expect_eq_s(emit_json(JsonValue.number(0.0)), String("0"), String("number 0"))
    _expect_eq_s(emit_json(JsonValue.number(3.0)), String("3"), String("number 3"))
    # Float (non-integer): we don't require an exact spelling — just verify
    # round-trip through parse equals the original Float64.
    var pi_emit = emit_json(JsonValue.number(3.14))
    var pi_parsed = parse_json(pi_emit)
    if pi_parsed.kind != JK_NUMBER:
        _fail("3.14 round-trip kind")
    if pi_parsed.num_val != 3.14:
        _fail("3.14 round-trip value")
    _expect_eq_s(emit_json(JsonValue.string(String(""))), String("\"\""), String("empty string"))
    _expect_eq_s(emit_json(JsonValue.string(String("hi"))), String("\"hi\""), String("simple string"))


# ----------------------------------------------------------------------------
# Test 2: String escape.
# ----------------------------------------------------------------------------


def test_emit_string_escape() raises:
    var s = String("hello\nworld")
    var out = emit_json(JsonValue.string(s))
    _expect_eq_s(out, String("\"hello\\nworld\""), String("emit \\n escape"))

    var s2 = String("a\"b\\c\td")
    var out2 = emit_json(JsonValue.string(s2))
    # a "b \c\td  →   "a\"b\\c\td"
    _expect_eq_s(out2, String("\"a\\\"b\\\\c\\td\""), String("emit mixed escapes"))


# ----------------------------------------------------------------------------
# Test 3: Empty array / empty object.
# ----------------------------------------------------------------------------


def test_emit_empty_containers() raises:
    _expect_eq_s(emit_json(JsonValue.empty_array()), String("[]"), String("empty array"))
    _expect_eq_s(emit_json(JsonValue.empty_object()), String("{}"), String("empty object"))


# ----------------------------------------------------------------------------
# Test 4: Mixed-kind array.
# ----------------------------------------------------------------------------


def test_emit_mixed_array() raises:
    var items = List[JsonValue]()
    items.append(JsonValue.number(1.0))
    items.append(JsonValue.string(String("two")))
    items.append(JsonValue.bool_(True))
    items.append(JsonValue.null())
    var arr = JsonValue.array(items^)
    var out = emit_json(arr)
    _expect_eq_s(
        out, String("[1,\"two\",true,null]"), String("mixed array emit"),
    )


# ----------------------------------------------------------------------------
# Test 5: Object keys sorted at emit (insertion order NOT preserved).
# ----------------------------------------------------------------------------


def test_emit_object_sorted_keys() raises:
    var keys = List[String]()
    var vals = List[JsonValue]()
    keys.append(String("b"))
    vals.append(JsonValue.number(1.0))
    keys.append(String("a"))
    vals.append(JsonValue.number(2.0))
    keys.append(String("c"))
    vals.append(JsonValue.number(3.0))
    var obj = JsonValue.object_(keys^, vals^)
    var out = emit_json(obj)
    _expect_eq_s(
        out,
        String("{\"a\":2,\"b\":1,\"c\":3}"),
        String("object emit sorted by key"),
    )


# ----------------------------------------------------------------------------
# Test 6: Round-trip parse(emit(v)) for each kind.
# ----------------------------------------------------------------------------


def test_round_trip_each_kind() raises:
    # null
    var v_null = JsonValue.null()
    var rt_null = parse_json(emit_json(v_null))
    if not v_null.equals(rt_null):
        _fail("round-trip null")

    # bool
    var v_true = JsonValue.bool_(True)
    var rt_true = parse_json(emit_json(v_true))
    if not v_true.equals(rt_true):
        _fail("round-trip true")

    var v_false = JsonValue.bool_(False)
    var rt_false = parse_json(emit_json(v_false))
    if not v_false.equals(rt_false):
        _fail("round-trip false")

    # number (integer-valued)
    var v_n = JsonValue.number(42.0)
    var rt_n = parse_json(emit_json(v_n))
    if not v_n.equals(rt_n):
        _fail("round-trip integer-valued number")

    # string with escapes
    var v_s = JsonValue.string(String("hello\nworld\twith \"quotes\""))
    var rt_s = parse_json(emit_json(v_s))
    if not v_s.equals(rt_s):
        _fail("round-trip string with escapes")

    # array
    var items = List[JsonValue]()
    items.append(JsonValue.number(1.0))
    items.append(JsonValue.bool_(False))
    items.append(JsonValue.null())
    items.append(JsonValue.string(String("nested")))
    var v_arr = JsonValue.array(items^)
    var rt_arr = parse_json(emit_json(v_arr))
    if not v_arr.equals(rt_arr):
        _fail("round-trip array")

    # object (multi-key with nesting)
    var ok = List[String]()
    var ov = List[JsonValue]()
    ok.append(String("name"))
    ov.append(JsonValue.string(String("workflow")))
    ok.append(String("version"))
    ov.append(JsonValue.number(1.0))
    var inner_k = List[String]()
    var inner_v = List[JsonValue]()
    inner_k.append(String("x"))
    inner_v.append(JsonValue.number(40.0))
    inner_k.append(String("y"))
    inner_v.append(JsonValue.number(80.0))
    ok.append(String("position"))
    ov.append(JsonValue.object_(inner_k^, inner_v^))
    var v_obj = JsonValue.object_(ok^, ov^)
    var rt_obj = parse_json(emit_json(v_obj))
    if not v_obj.equals(rt_obj):
        _fail("round-trip nested object")


# ----------------------------------------------------------------------------
# Test 7: Parse error on unexpected token.
# ----------------------------------------------------------------------------


def test_parse_error_unexpected_token() raises:
    var raised = False
    try:
        var _ = parse_json(String(","))
    except e:
        raised = True
    if not raised:
        _fail("expected parse_json(',') to raise")

    var raised2 = False
    try:
        var _ = parse_json(String("xxx"))
    except e:
        raised2 = True
    if not raised2:
        _fail("expected parse_json('xxx') to raise")


# ----------------------------------------------------------------------------
# Test 8: Parse error on trailing content.
# ----------------------------------------------------------------------------


def test_parse_error_trailing_content() raises:
    var raised = False
    try:
        var _ = parse_json(String("null xxx"))
    except e:
        raised = True
    if not raised:
        _fail("expected parse_json('null xxx') to raise (trailing content)")

    var raised2 = False
    try:
        var _ = parse_json(String("42 43"))
    except e:
        raised2 = True
    if not raised2:
        _fail("expected parse_json('42 43') to raise (trailing content)")


# ----------------------------------------------------------------------------
# Test 9: Negative + fractional number.
# ----------------------------------------------------------------------------


def test_parse_negative_fractional() raises:
    var v = parse_json(String("-3.14"))
    if v.kind != JK_NUMBER:
        _fail("parse('-3.14').kind != number")
    # Tolerate IEEE-754 imprecision in the textual round-trip — should be exact
    # for `-3.14` parsed via Float64 ctor.
    if v.num_val > -3.139 or v.num_val < -3.141:
        _fail("parse('-3.14').num_val out of range")
    # Also check the integer-valued negative
    var v2 = parse_json(String("-7"))
    if v2.kind != JK_NUMBER:
        _fail("parse('-7').kind")
    if v2.num_val != -7.0:
        _fail("parse('-7').num_val")
    # Exponent form
    var v3 = parse_json(String("1.5e2"))
    if v3.kind != JK_NUMBER:
        _fail("parse('1.5e2').kind")
    if v3.num_val != 150.0:
        _fail("parse('1.5e2').num_val (expected 150.0)")


# ----------------------------------------------------------------------------
# Test 10: get_object_field on missing key returns null.
# ----------------------------------------------------------------------------


def test_get_object_field_missing() raises:
    var keys = List[String]()
    var vals = List[JsonValue]()
    keys.append(String("present"))
    vals.append(JsonValue.number(42.0))
    var obj = JsonValue.object_(keys^, vals^)
    var hit = obj.get_object_field(String("present"))
    if hit.kind != JK_NUMBER:
        _fail("get_object_field('present') should hit a JK_NUMBER")
    if hit.num_val != 42.0:
        _fail("get_object_field('present').num_val")
    var miss = obj.get_object_field(String("missing"))
    if miss.kind != JK_NULL:
        _fail("get_object_field('missing') should return JK_NULL")

    # set_object_field replaces an existing key.
    var obj2 = obj.copy()
    obj2.set_object_field(String("present"), JsonValue.number(99.0))
    var hit2 = obj2.get_object_field(String("present"))
    if hit2.num_val != 99.0:
        _fail("set_object_field should overwrite the existing value")

    # set_object_field appends a new key.
    obj2.set_object_field(String("new_key"), JsonValue.string(String("hello")))
    var newhit = obj2.get_object_field(String("new_key"))
    if newhit.kind != JK_STRING:
        _fail("set_object_field should append new key")


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------


def main() raises:
    test_emit_scalars()
    test_emit_string_escape()
    test_emit_empty_containers()
    test_emit_mixed_array()
    test_emit_object_sorted_keys()
    test_round_trip_each_kind()
    test_parse_error_unexpected_token()
    test_parse_error_trailing_content()
    test_parse_negative_fractional()
    test_get_object_field_missing()
    print("PASS: serde/json smoke tests (10 tests)")
