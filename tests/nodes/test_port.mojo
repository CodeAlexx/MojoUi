"""Smoke tests for mojoui.nodes.port — NodeValueType + Port + ports_compatible."""

from mojoui.nodes.port import (
    NodeValueType,
    NVT_LATENT,
    NVT_IMAGE,
    NVT_CONDITIONING,
    NVT_MODEL,
    NVT_VAE,
    NVT_CLIP,
    NVT_LORA,
    NVT_NUMBER,
    NVT_TEXT,
    NVT_SEED,
    NVT_BOOL,
    NVT_COUNT,
    Port,
    node_value_type_name,
    node_value_type_from_name,
    ports_compatible,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_node_value_type_constants_distinct() raises:
    """Test 1: all 11 NodeValueType constants are pairwise distinct AND
    NVT_COUNT is one past the last variant.
    """
    # Build a List[NodeValueType] of all 11 variants in declaration order
    # then verify each value matches its expected ordinal AND every pair is
    # distinct.
    var all_types = List[NodeValueType]()
    all_types.append(NVT_LATENT)
    all_types.append(NVT_IMAGE)
    all_types.append(NVT_CONDITIONING)
    all_types.append(NVT_MODEL)
    all_types.append(NVT_VAE)
    all_types.append(NVT_CLIP)
    all_types.append(NVT_LORA)
    all_types.append(NVT_NUMBER)
    all_types.append(NVT_TEXT)
    all_types.append(NVT_SEED)
    all_types.append(NVT_BOOL)

    if Int(len(all_types)) != 11:
        _fail("expected 11 NodeValueType variants, got " + String(len(all_types)))

    # Verify each variant equals its expected ordinal.
    for i in range(Int(len(all_types))):
        if Int(all_types[i]) != i:
            _fail(
                "variant at index "
                + String(i)
                + " has ordinal "
                + String(Int(all_types[i]))
                + ", expected "
                + String(i)
            )

    # Pairwise distinctness — O(n^2) but n=11 so trivial.
    for i in range(Int(len(all_types))):
        for j in range(i + 1, Int(len(all_types))):
            if all_types[i] == all_types[j]:
                _fail(
                    "variants at indices "
                    + String(i)
                    + " and "
                    + String(j)
                    + " collide on value "
                    + String(Int(all_types[i]))
                )

    # NVT_COUNT must be one past NVT_BOOL (the last valid variant).
    if Int(NVT_COUNT) != 11:
        _fail("NVT_COUNT expected 11, got " + String(Int(NVT_COUNT)))

    print("PASS: test_node_value_type_constants_distinct (11 variants, NVT_COUNT=11)")


def test_node_value_type_name_round_trip() raises:
    """Test 2: from_name(name(t)) == t for all 11 variants."""
    var types = List[NodeValueType]()
    types.append(NVT_LATENT)
    types.append(NVT_IMAGE)
    types.append(NVT_CONDITIONING)
    types.append(NVT_MODEL)
    types.append(NVT_VAE)
    types.append(NVT_CLIP)
    types.append(NVT_LORA)
    types.append(NVT_NUMBER)
    types.append(NVT_TEXT)
    types.append(NVT_SEED)
    types.append(NVT_BOOL)

    for i in range(Int(len(types))):
        var t = types[i]
        var name = node_value_type_name(t)
        var t2 = node_value_type_from_name(name)
        if t2 != t:
            _fail(
                "round-trip failed for ordinal "
                + String(Int(t))
                + " (name='"
                + name
                + "'): got "
                + String(Int(t2))
            )

    print("PASS: test_node_value_type_name_round_trip (11/11)")


def test_node_value_type_from_name_invalid() raises:
    """Test 3: from_name('invalid') returns NVT_COUNT sentinel."""
    var got = node_value_type_from_name(String("invalid"))
    if got != NVT_COUNT:
        _fail("from_name('invalid') expected NVT_COUNT, got " + String(Int(got)))

    var got2 = node_value_type_from_name(String(""))
    if got2 != NVT_COUNT:
        _fail("from_name('') expected NVT_COUNT, got " + String(Int(got2)))

    var got3 = node_value_type_from_name(String("LATENT"))  # case-sensitive
    if got3 != NVT_COUNT:
        _fail(
            "from_name('LATENT') expected NVT_COUNT (case-sensitive), got "
            + String(Int(got3))
        )

    print("PASS: test_node_value_type_from_name_invalid (3 unknown name probes)")


def test_port_construction() raises:
    """Test 4: Port construction sets name, value_type, is_input correctly."""
    var p = Port(String("model"), NVT_MODEL, True)
    if p.name != String("model"):
        _fail("p.name expected 'model', got '" + p.name + "'")
    if p.value_type != NVT_MODEL:
        _fail("p.value_type expected NVT_MODEL, got " + String(Int(p.value_type)))
    if not p.is_input:
        _fail("p.is_input expected True, got False")

    var q = Port(String("latent_out"), NVT_LATENT, False)
    if q.name != String("latent_out"):
        _fail("q.name expected 'latent_out', got '" + q.name + "'")
    if q.value_type != NVT_LATENT:
        _fail("q.value_type expected NVT_LATENT, got " + String(Int(q.value_type)))
    if q.is_input:
        _fail("q.is_input expected False, got True")

    print("PASS: test_port_construction (2 ports — model/input, latent/output)")


def test_port_copy_independent_storage() raises:
    """Test 5: copying a Port produces an independent String storage —
    mutating the source's name (by reassignment) does not affect the copy.
    """
    var src = Port(String("alpha"), NVT_NUMBER, True)
    var dst = src.copy()

    # Reassign the source's name to a fresh String. The copy must still
    # carry the original "alpha" — proves the String storage was actually
    # copied, not aliased.
    src.name = String("beta")

    if dst.name != String("alpha"):
        _fail("after src.name='beta', dst.name expected 'alpha', got '" + dst.name + "'")
    if src.name != String("beta"):
        _fail("src.name expected 'beta' after reassignment, got '" + src.name + "'")

    # All other fields should also be preserved on the copy.
    if dst.value_type != NVT_NUMBER:
        _fail(
            "dst.value_type expected NVT_NUMBER, got " + String(Int(dst.value_type))
        )
    if not dst.is_input:
        _fail("dst.is_input expected True, got False")

    print("PASS: test_port_copy_independent_storage")


def test_ports_compatible_match_opposite_directions() raises:
    """Test 6: same value_type + opposite directions → True."""
    var out_port = Port(String("model_out"), NVT_MODEL, False)
    var in_port = Port(String("model_in"), NVT_MODEL, True)

    if not ports_compatible(out_port, in_port):
        _fail("ports_compatible(out, in) expected True for matching MODEL types")
    # Order-independent — input first should also compatible.
    if not ports_compatible(in_port, out_port):
        _fail("ports_compatible(in, out) expected True for matching MODEL types")

    print("PASS: test_ports_compatible_match_opposite_directions (both orders)")


def test_ports_compatible_same_direction_rejected() raises:
    """Test 7: same value_type + same direction → False (can't connect
    input to input or output to output).
    """
    var in_a = Port(String("a_in"), NVT_LATENT, True)
    var in_b = Port(String("b_in"), NVT_LATENT, True)
    if ports_compatible(in_a, in_b):
        _fail("ports_compatible(in, in) expected False for two LATENT inputs")

    var out_a = Port(String("a_out"), NVT_LATENT, False)
    var out_b = Port(String("b_out"), NVT_LATENT, False)
    if ports_compatible(out_a, out_b):
        _fail("ports_compatible(out, out) expected False for two LATENT outputs")

    print("PASS: test_ports_compatible_same_direction_rejected (input+input, output+output)")


def test_ports_compatible_different_types_rejected() raises:
    """Test 8: different value_type → False even with opposite directions."""
    var model_out = Port(String("m_out"), NVT_MODEL, False)
    var image_in = Port(String("i_in"), NVT_IMAGE, True)
    if ports_compatible(model_out, image_in):
        _fail("ports_compatible(MODEL out, IMAGE in) expected False")

    # Number vs text, opposite directions — also rejected.
    var num_out = Port(String("n_out"), NVT_NUMBER, False)
    var text_in = Port(String("t_in"), NVT_TEXT, True)
    if ports_compatible(num_out, text_in):
        _fail("ports_compatible(NUMBER out, TEXT in) expected False")

    print("PASS: test_ports_compatible_different_types_rejected")


def test_port_write_to_string_format() raises:
    """Test 9: String(port) produces the canonical 'Port(name=..., type=..., input=...)'
    format used for debug logging and test assertions.
    """
    var p = Port(String("model"), NVT_MODEL, True)
    var s = String(p)
    var want = String("Port(name='model', type=model, input=True)")
    if s != want:
        _fail("String(port) expected '" + want + "', got '" + s + "'")

    var q = Port(String("seed_out"), NVT_SEED, False)
    var s2 = String(q)
    var want2 = String("Port(name='seed_out', type=seed, input=False)")
    if s2 != want2:
        _fail("String(port) expected '" + want2 + "', got '" + s2 + "'")

    print("PASS: test_port_write_to_string_format (2 formatted ports)")


def main() raises:
    test_node_value_type_constants_distinct()
    test_node_value_type_name_round_trip()
    test_node_value_type_from_name_invalid()
    test_port_construction()
    test_port_copy_independent_storage()
    test_ports_compatible_match_opposite_directions()
    test_ports_compatible_same_direction_rejected()
    test_ports_compatible_different_types_rejected()
    test_port_write_to_string_format()
    print("PASS: all 9 smoke tests")
