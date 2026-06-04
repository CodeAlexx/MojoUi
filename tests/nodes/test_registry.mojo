"""Smoke tests for `mojoui/nodes/registry.mojo` — NodeRegistry + NodeTypeDef.

Pure data tests. NO FFI in the call graph — runs cleanly under `mojo run`
(JIT) without symbol-resolution drama (c33/c35 pattern).
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedIdAllocator
from mojoui.nodes.port import (
    NVT_MODEL,
    NVT_CLIP,
    NVT_VAE,
    NVT_LATENT,
    NVT_CONDITIONING,
    NVT_IMAGE,
    NVT_NUMBER,
)
from mojoui.nodes.node import FieldValue, FK_NUMBER, FK_STRING, FK_INT
from mojoui.nodes.registry import (
    NodeTypeDef,
    NodeRegistry,
    register_builtins,
)


def test_empty_registry() raises:
    """Empty registry has 0 types, all_type_ids returns empty."""
    var reg = NodeRegistry()
    if reg.size() != 0:
        raise Error("empty registry should have size 0")
    var ids = reg.all_type_ids()
    if len(ids) != 0:
        raise Error("empty registry should have empty all_type_ids")
    if reg.is_registered(String("anything")):
        raise Error("empty registry should not have any type registered")
    print("  PASS test_empty_registry")


def test_register_one_typedef() raises:
    """Register one typedef → is_registered True, lookup succeeds."""
    var reg = NodeRegistry()
    var td = NodeTypeDef(
        String("core/foo"), String("Foo"), String("core")
    )
    reg.register(td^)
    if not reg.is_registered(String("core/foo")):
        raise Error("is_registered should be True after register")
    if reg.size() != 1:
        raise Error("registry size should be 1")
    var fetched = reg.lookup(String("core/foo"))
    if fetched.type_id != String("core/foo"):
        raise Error("lookup type_id mismatch")
    if fetched.display_name != String("Foo"):
        raise Error("lookup display_name mismatch")
    if fetched.category != String("core"):
        raise Error("lookup category mismatch")
    print("  PASS test_register_one_typedef")


def test_register_builtins_count() raises:
    """The `register_builtins` helper registers exactly 5 ComfyUI-core typedefs."""
    var reg = NodeRegistry()
    register_builtins(reg)
    if reg.size() != 5:
        raise Error("expected 5 builtins, got " + String(reg.size()))
    if not reg.is_registered(String("core/load_checkpoint")):
        raise Error("missing core/load_checkpoint")
    if not reg.is_registered(String("core/encode_prompt")):
        raise Error("missing core/encode_prompt")
    if not reg.is_registered(String("core/k_sampler")):
        raise Error("missing core/k_sampler")
    if not reg.is_registered(String("core/vae_decode")):
        raise Error("missing core/vae_decode")
    if not reg.is_registered(String("core/save_image")):
        raise Error("missing core/save_image")
    print("  PASS test_register_builtins_count")


def test_by_category() raises:
    """The `by_category` accessor groups the 5 builtins into 4 categories."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var groups = reg.by_category()
    if len(groups) != 4:
        raise Error("expected 4 categories, got " + String(len(groups)))
    if not (String("core") in groups):
        raise Error("missing 'core' category")
    if not (String("sampler") in groups):
        raise Error("missing 'sampler' category")
    if not (String("vae") in groups):
        raise Error("missing 'vae' category")
    if not (String("image") in groups):
        raise Error("missing 'image' category")
    # core has 2 typedefs (load_checkpoint, encode_prompt), the other three
    # have one each.
    if len(groups[String("core")]) != 2:
        raise Error("core category should have 2 typedefs")
    if len(groups[String("sampler")]) != 1:
        raise Error("sampler category should have 1 typedef")
    if len(groups[String("vae")]) != 1:
        raise Error("vae category should have 1 typedef")
    if len(groups[String("image")]) != 1:
        raise Error("image category should have 1 typedef")
    print("  PASS test_by_category")


def test_make_node_k_sampler() raises:
    """The `make_node(core/k_sampler)` call yields 4 inputs, 1 output, 4 fields."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var alloc = RetainedIdAllocator()
    var id = alloc.alloc()
    var node = reg.make_node(String("core/k_sampler"), Vec2(50.0, 50.0), id)

    if node.type_id != String("core/k_sampler"):
        raise Error("node type_id mismatch")
    if node.title != String("K-Sampler"):
        raise Error("node title should default to display_name 'K-Sampler'")
    if node.position.x != 50.0 or node.position.y != 50.0:
        raise Error("node position mismatch")

    if len(node.inputs) != 4:
        raise Error(
            "k_sampler should have 4 inputs (model/cond/uncond/latent), got "
            + String(len(node.inputs))
        )
    if len(node.outputs) != 1:
        raise Error(
            "k_sampler should have 1 output (latent), got "
            + String(len(node.outputs))
        )

    # Check input names in order.
    if node.inputs[0].name != String("model"):
        raise Error("input[0] should be 'model'")
    if node.inputs[1].name != String("cond"):
        raise Error("input[1] should be 'cond'")
    if node.inputs[2].name != String("uncond"):
        raise Error("input[2] should be 'uncond'")
    if node.inputs[3].name != String("latent"):
        raise Error("input[3] should be 'latent'")
    if node.outputs[0].name != String("latent"):
        raise Error("output[0] should be 'latent'")

    # Check field count + presence.
    if node.field_count() != 4:
        raise Error(
            "k_sampler should have 4 fields (cfg/steps/seed/sampler), got "
            + String(node.field_count())
        )
    if not node.has_field(String("cfg")):
        raise Error("missing field 'cfg'")
    if not node.has_field(String("steps")):
        raise Error("missing field 'steps'")
    if not node.has_field(String("seed")):
        raise Error("missing field 'seed'")
    if not node.has_field(String("sampler")):
        raise Error("missing field 'sampler'")

    # Check field kinds + values.
    var cfg = node.get_field(String("cfg"))
    if cfg.kind != FK_NUMBER:
        raise Error("cfg should be FK_NUMBER")
    if cfg.num_val != 7.0:
        raise Error("cfg default should be 7.0")
    var steps = node.get_field(String("steps"))
    if steps.kind != FK_INT:
        raise Error("steps should be FK_INT")
    if steps.int_val != 30:
        raise Error("steps default should be 30")
    var sampler = node.get_field(String("sampler"))
    if sampler.kind != FK_STRING:
        raise Error("sampler should be FK_STRING")
    if sampler.str_val != String("euler"):
        raise Error("sampler default should be 'euler'")

    print("  PASS test_make_node_k_sampler")


def test_make_node_unknown_raises() raises:
    """The `make_node` call for an unknown type_id raises."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var alloc = RetainedIdAllocator()
    var id = alloc.alloc()
    var raised = False
    try:
        var n = reg.make_node(
            String("core/does_not_exist"), Vec2(0.0, 0.0), id
        )
        # Silence unused warning by referencing.
        if n.field_count() < 0:
            raised = False
    except e:
        raised = True
    if not raised:
        raise Error("make_node should raise for unknown type_id")
    # Also confirm lookup raises.
    var raised2 = False
    try:
        var td = reg.lookup(String("core/does_not_exist"))
        if td.type_id == String("dummy"):
            raised2 = False
    except e:
        raised2 = True
    if not raised2:
        raise Error("lookup should raise for unknown type_id")
    print("  PASS test_make_node_unknown_raises")


def test_re_register_replaces() raises:
    """Re-registering the same type_id replaces the typedef in-place
    (Dict overwrite) and does NOT grow insertion_order."""
    var reg = NodeRegistry()
    var td1 = NodeTypeDef(
        String("core/foo"), String("Foo v1"), String("core")
    )
    reg.register(td1^)
    if reg.size() != 1:
        raise Error("size should be 1 after first register")
    var td2 = NodeTypeDef(
        String("core/foo"), String("Foo v2"), String("core")
    )
    td2.with_field(String("new_param"), FieldValue.number(1.5))
    reg.register(td2^)
    if reg.size() != 1:
        raise Error(
            "size should still be 1 after re-register (replace not append)"
        )
    var fetched = reg.lookup(String("core/foo"))
    if fetched.display_name != String("Foo v2"):
        raise Error("re-register should replace display_name to 'Foo v2'")
    if len(fetched.default_fields) != 1:
        raise Error("re-register should pick up the new_param field")
    print("  PASS test_re_register_replaces")


def test_chainable_mutators() raises:
    """NodeTypeDef.with_input/with_output/with_field accumulate correctly
    (4 inputs + 1 output + 2 fields)."""
    var td = NodeTypeDef(
        String("test/widget"), String("Widget"), String("test")
    )
    td.with_input(String("a"), NVT_MODEL)
    td.with_input(String("b"), NVT_CLIP)
    td.with_input(String("c"), NVT_VAE)
    td.with_input(String("d"), NVT_LATENT)
    td.with_output(String("out"), NVT_IMAGE)
    td.with_field(String("freq"), FieldValue.number(440.0))
    td.with_field(String("name"), FieldValue.string(String("widget-1")))

    if len(td.default_inputs) != 4:
        raise Error("expected 4 inputs")
    if len(td.default_outputs) != 1:
        raise Error("expected 1 output")
    if len(td.default_fields) != 2:
        raise Error("expected 2 fields")
    if td.default_inputs[0].name != String("a"):
        raise Error("input[0] should be 'a'")
    if td.default_inputs[0].value_type != NVT_MODEL:
        raise Error("input[0] type should be NVT_MODEL")
    if td.default_inputs[0].is_input != True:
        raise Error("input[0] is_input should be True")
    if td.default_outputs[0].is_input != False:
        raise Error("output[0] is_input should be False")
    if not (String("freq") in td.default_fields):
        raise Error("missing field 'freq'")
    if not (String("name") in td.default_fields):
        raise Error("missing field 'name'")
    print("  PASS test_chainable_mutators")


def test_insertion_order_stable() raises:
    """The `all_type_ids` accessor returns insertion order, not random."""
    var reg = NodeRegistry()
    var td_a = NodeTypeDef(
        String("z/zebra"), String("Zebra"), String("z")
    )
    var td_b = NodeTypeDef(
        String("a/aardvark"), String("Aardvark"), String("a")
    )
    var td_c = NodeTypeDef(
        String("m/mantis"), String("Mantis"), String("m")
    )
    reg.register(td_a^)
    reg.register(td_b^)
    reg.register(td_c^)
    var ids = reg.all_type_ids()
    if len(ids) != 3:
        raise Error("expected 3 type_ids in insertion order list")
    if ids[0] != String("z/zebra"):
        raise Error("ids[0] should be 'z/zebra' (first registered)")
    if ids[1] != String("a/aardvark"):
        raise Error("ids[1] should be 'a/aardvark' (second registered)")
    if ids[2] != String("m/mantis"):
        raise Error("ids[2] should be 'm/mantis' (third registered)")
    print("  PASS test_insertion_order_stable")


def test_make_node_load_checkpoint() raises:
    """Bonus end-to-end check: make_node for load_checkpoint → 0 inputs,
    3 outputs (model/clip/vae), 1 field (path)."""
    var reg = NodeRegistry()
    register_builtins(reg)
    var alloc = RetainedIdAllocator()
    var id = alloc.alloc()
    var node = reg.make_node(
        String("core/load_checkpoint"), Vec2(10.0, 20.0), id
    )
    if len(node.inputs) != 0:
        raise Error("load_checkpoint should have 0 inputs")
    if len(node.outputs) != 3:
        raise Error("load_checkpoint should have 3 outputs")
    if node.outputs[0].name != String("model"):
        raise Error("output[0] should be 'model'")
    if node.outputs[1].name != String("clip"):
        raise Error("output[1] should be 'clip'")
    if node.outputs[2].name != String("vae"):
        raise Error("output[2] should be 'vae'")
    if node.field_count() != 1:
        raise Error("load_checkpoint should have 1 field")
    if not node.has_field(String("path")):
        raise Error("missing field 'path'")
    var path = node.get_field(String("path"))
    if path.kind != FK_STRING:
        raise Error("path field should be FK_STRING")
    if path.str_val != String("model.safetensors"):
        raise Error("path default should be 'model.safetensors'")
    # Title from display_name.
    if node.title != String("Load Checkpoint"):
        raise Error("title should default to display_name")
    # Size defaults to 200x80 since builtin didn't override.
    if node.size.x != 200.0 or node.size.y != 80.0:
        raise Error("size should default to 200x80")
    print("  PASS test_make_node_load_checkpoint")


def main() raises:
    print("Running registry tests...")
    test_empty_registry()
    test_register_one_typedef()
    test_register_builtins_count()
    test_by_category()
    test_make_node_k_sampler()
    test_make_node_unknown_raises()
    test_re_register_replaces()
    test_chainable_mutators()
    test_insertion_order_stable()
    test_make_node_load_checkpoint()
    print("PASS: all 10 smoke tests")
