"""Smoke tests for `mojoui/nodes/node.mojo` (M2.5 c32).

Covers `FieldValue` constructors + default, `Node` construction + mutators +
field round-trip + independent copy, and `PortRef` construction + copy.
"""

from mojoui.core.types import Vec2
from mojoui.core.id import RetainedId, RetainedIdAllocator, RET_ID_NONE
from mojoui.nodes.node import (
    FieldValue,
    FK_NONE,
    FK_NUMBER,
    FK_STRING,
    FK_BOOL,
    FK_INT,
    PortRef,
    Node,
)


def _approx(a: Float64, b: Float64, eps: Float64 = 1.0e-9) -> Bool:
    var d = a - b
    if d < 0.0:
        d = -d
    return d <= eps


def test_fieldvalue_number() raises:
    var fv = FieldValue.number(3.14)
    if fv.kind != FK_NUMBER:
        raise Error("FieldValue.number() should have kind=FK_NUMBER")
    if not _approx(fv.num_val, 3.14):
        raise Error("FieldValue.number(3.14).num_val should be 3.14")
    print("PASS: FieldValue.number")


def test_fieldvalue_string() raises:
    var fv = FieldValue.string(String("hello"))
    if fv.kind != FK_STRING:
        raise Error("FieldValue.string() should have kind=FK_STRING")
    if fv.str_val != String("hello"):
        raise Error("FieldValue.string(hello).str_val should be 'hello'")
    print("PASS: FieldValue.string")


def test_fieldvalue_bool() raises:
    var fv = FieldValue.bool_(True)
    if fv.kind != FK_BOOL:
        raise Error("FieldValue.bool_() should have kind=FK_BOOL")
    if fv.bool_val != True:
        raise Error("FieldValue.bool_(True).bool_val should be True")
    var fv2 = FieldValue.bool_(False)
    if fv2.bool_val != False:
        raise Error("FieldValue.bool_(False).bool_val should be False")
    print("PASS: FieldValue.bool_")


def test_fieldvalue_int() raises:
    var fv = FieldValue.int_(Int64(42))
    if fv.kind != FK_INT:
        raise Error("FieldValue.int_() should have kind=FK_INT")
    if fv.int_val != Int64(42):
        raise Error("FieldValue.int_(42).int_val should be 42")
    print("PASS: FieldValue.int_")


def test_fieldvalue_default() raises:
    var fv = FieldValue()
    if fv.kind != FK_NONE:
        raise Error("FieldValue() default kind should be FK_NONE")
    if not _approx(fv.num_val, 0.0):
        raise Error("FieldValue() default num_val should be 0.0")
    if fv.bool_val != False:
        raise Error("FieldValue() default bool_val should be False")
    if fv.int_val != Int64(0):
        raise Error("FieldValue() default int_val should be 0")
    if fv.str_val != String(""):
        raise Error("FieldValue() default str_val should be ''")
    print("PASS: FieldValue() default")


def test_node_construction() raises:
    var alloc = RetainedIdAllocator()
    var id = alloc.alloc()
    if id == RET_ID_NONE:
        raise Error("alloc returned RET_ID_NONE")
    var n = Node(id, String("core/k_sampler"))
    if n.id != id:
        raise Error("Node.id should equal allocator id")
    if n.type_id != String("core/k_sampler"):
        raise Error("Node.type_id mismatch")
    if n.title != String("core/k_sampler"):
        raise Error("Node.title should default to type_id")
    if n.position != Vec2(0.0, 0.0):
        raise Error("Node.position should default to origin")
    if n.size != Vec2(200.0, 80.0):
        raise Error("Node.size should default to 200x80")
    if len(n.inputs) != 0 or len(n.outputs) != 0:
        raise Error("Node ports should default empty")
    if n.field_count() != 0:
        raise Error("Node.fields should default empty")
    print("PASS: Node construction")


def test_node_with_position() raises:
    var alloc = RetainedIdAllocator()
    var n = Node(alloc.alloc(), String("foo"))
    n.with_position(Vec2(50.0, 100.0))
    if n.position != Vec2(50.0, 100.0):
        raise Error("Node.with_position did not update position")
    print("PASS: Node.with_position")


def test_node_fields_round_trip() raises:
    var alloc = RetainedIdAllocator()
    var n = Node(alloc.alloc(), String("core/k_sampler"))
    n.set_field(String("cfg"), FieldValue.number(7.0))
    n.set_field(String("seed"), FieldValue.int_(Int64(42)))
    n.set_field(String("sampler"), FieldValue.string(String("euler")))
    if n.field_count() != 3:
        raise Error("Node should have 3 fields after 3 set_field calls")
    if not n.has_field(String("cfg")):
        raise Error("Node should have 'cfg' field")
    if not n.has_field(String("seed")):
        raise Error("Node should have 'seed' field")
    if n.has_field(String("missing")):
        raise Error("Node should NOT have 'missing' field")

    var cfg = n.get_field(String("cfg"))
    if cfg.kind != FK_NUMBER or not _approx(cfg.num_val, 7.0):
        raise Error("get_field('cfg') round-trip mismatch")

    var seed = n.get_field(String("seed"))
    if seed.kind != FK_INT or seed.int_val != Int64(42):
        raise Error("get_field('seed') round-trip mismatch")

    var sampler = n.get_field(String("sampler"))
    if sampler.kind != FK_STRING or sampler.str_val != String("euler"):
        raise Error("get_field('sampler') round-trip mismatch")

    # Replace existing field — count unchanged.
    n.set_field(String("cfg"), FieldValue.number(9.5))
    if n.field_count() != 3:
        raise Error("set_field on existing key should not grow count")
    var cfg2 = n.get_field(String("cfg"))
    if not _approx(cfg2.num_val, 9.5):
        raise Error("set_field overwrite did not take effect")

    print("PASS: Node.fields round-trip")


def test_node_copy_independence() raises:
    var alloc = RetainedIdAllocator()
    var n = Node(alloc.alloc(), String("foo"))
    n.with_position(Vec2(10.0, 20.0))
    n.set_field(String("cfg"), FieldValue.number(1.0))

    var n2 = n.copy()
    # Mutate the COPY — original must be unaffected.
    n2.with_position(Vec2(999.0, 999.0))
    n2.set_field(String("cfg"), FieldValue.number(7.0))
    n2.set_field(String("extra"), FieldValue.bool_(True))

    if n.position != Vec2(10.0, 20.0):
        raise Error("Node.copy: original position should be untouched")
    var cfg_orig = n.get_field(String("cfg"))
    if not _approx(cfg_orig.num_val, 1.0):
        raise Error("Node.copy: original field should be untouched")
    if n.has_field(String("extra")):
        raise Error("Node.copy: original should not see new field in copy")
    if n.field_count() != 1:
        raise Error("Node.copy: original field_count should stay 1")
    if n2.field_count() != 2:
        raise Error("Node.copy: copy field_count should be 2")
    print("PASS: Node.copy independence")


def test_portref_construction_and_copy() raises:
    var p = PortRef(String("latent"), Int32(1))
    if p.name != String("latent"):
        raise Error("PortRef.name mismatch")
    if p.value_type != Int32(1):
        raise Error("PortRef.value_type mismatch")

    var p2 = p.copy()
    if p2.name != String("latent"):
        raise Error("PortRef.copy: name mismatch")
    if p2.value_type != Int32(1):
        raise Error("PortRef.copy: value_type mismatch")

    # Add ports to a node and verify list independence after copy.
    var alloc = RetainedIdAllocator()
    var n = Node(alloc.alloc(), String("core/foo"))
    n.add_input(PortRef(String("latent_in"), Int32(1)))
    n.add_input(PortRef(String("image_in"), Int32(2)))
    n.add_output(PortRef(String("out"), Int32(1)))
    if len(n.inputs) != 2:
        raise Error("Node.add_input did not grow inputs")
    if len(n.outputs) != 1:
        raise Error("Node.add_output did not grow outputs")
    if n.inputs[0].name != String("latent_in"):
        raise Error("Node.inputs[0].name mismatch")

    var n3 = n.copy()
    n3.add_input(PortRef(String("extra"), Int32(3)))
    if len(n.inputs) != 2:
        raise Error("Node copy independence: original inputs should stay at 2")
    if len(n3.inputs) != 3:
        raise Error("Node copy independence: copy inputs should be 3")
    print("PASS: PortRef construction + copy + Node port list independence")


def main() raises:
    test_fieldvalue_number()
    test_fieldvalue_string()
    test_fieldvalue_bool()
    test_fieldvalue_int()
    test_fieldvalue_default()
    test_node_construction()
    test_node_with_position()
    test_node_fields_round_trip()
    test_node_copy_independence()
    test_portref_construction_and_copy()
    print("PASS: all 10 smoke tests")
