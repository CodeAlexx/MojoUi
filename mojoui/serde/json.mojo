"""JsonValue tagged-union + emit/parse for MojoUI workflow round-trip (M2.5).

Pure Mojo, NO FFI. Invariants from EriGui ("Serde Schema" in
`internal audit notes`): object keys sorted
alphabetically at emit (VCS-stable); numbers Float64 (integers up to 2^53
exact); no JSON5 (no comments, no trailing commas, no NaN/Infinity, no
`\\uXXXX` — sub-0x20 bytes besides `\\n`/`\\r`/`\\t` emit `\\u0000` as a
placeholder; full Unicode escape is M3 / i18n).

`JsonValue` is a tagged union (`kind` discriminator + per-variant slots —
no generic-enum primitive in current beta). `arr_val: List[Self]` works
because list storage is heap-allocated; objects use parallel `obj_keys` /
`obj_values` lists (sidesteps `List[(String, JsonValue)]`). Emit + parse
drive through a private `_StringBuilder` (List[UInt8]) rather than the
`Writer` trait — simpler, single-purpose, beta-stable. Public surface:
`JsonValue` (static ctors `null`/`bool_`/`number`/`string`/`array`/
`object_`/`empty_array`/`empty_object`); `emit_json(v)`; `parse_json(s)
raises`; `JsonParser`; `get_object_field`/`set_object_field`/`equals`.
Deferred: `\\uXXXX`, streaming I/O, JSON5, schema-aware fast-paths.
"""

# Kind tag constants (comptime, NOT alias — per Mojo implementation notes c11+)

comptime JsonKind = Int32

comptime JK_NULL: JsonKind = 0
comptime JK_BOOL: JsonKind = 1
comptime JK_NUMBER: JsonKind = 2   # Float64; integers up to 2^53 exact
comptime JK_STRING: JsonKind = 3
comptime JK_ARRAY: JsonKind = 4
comptime JK_OBJECT: JsonKind = 5

# ASCII byte constants for parse / emit.
comptime _BYTE_QUOTE: Int = 0x22
comptime _BYTE_BACKSLASH: Int = 0x5C
comptime _BYTE_LBRACKET: Int = 0x5B
comptime _BYTE_RBRACKET: Int = 0x5D
comptime _BYTE_LBRACE: Int = 0x7B
comptime _BYTE_RBRACE: Int = 0x7D
comptime _BYTE_COMMA: Int = 0x2C
comptime _BYTE_COLON: Int = 0x3A
comptime _BYTE_MINUS: Int = 0x2D
comptime _BYTE_PLUS: Int = 0x2B
comptime _BYTE_DOT: Int = 0x2E
comptime _BYTE_SPACE: Int = 0x20
comptime _BYTE_TAB: Int = 0x09
comptime _BYTE_LF: Int = 0x0A
comptime _BYTE_CR: Int = 0x0D
comptime _BYTE_0: Int = 0x30
comptime _BYTE_9: Int = 0x39
comptime _BYTE_LOWER_E: Int = 0x65
comptime _BYTE_LOWER_F: Int = 0x66
comptime _BYTE_LOWER_N: Int = 0x6E
comptime _BYTE_LOWER_R: Int = 0x72
comptime _BYTE_LOWER_T: Int = 0x74
comptime _BYTE_UPPER_E: Int = 0x45


# Internal byte-buffer string builder. NOT exposed.

struct _StringBuilder(Movable):
    """Accumulating UTF-8 byte buffer; surface is `write_byte` / `write_str`
    / `write_int` / `write_float` / `result`."""

    var bytes: List[UInt8]

    def __init__(out self):
        self.bytes = List[UInt8]()

    def write_byte(mut self, b: UInt8):
        self.bytes.append(b)

    def write_str(mut self, s: String):
        var n = s.byte_length()
        var ptr = s.unsafe_ptr()
        for i in range(n):
            self.bytes.append(ptr[i])

    def write_int(mut self, n: Int64):
        # Hand-rolled ASCII integer formatter.
        if n == 0:
            self.bytes.append(UInt8(_BYTE_0))
            return
        var negative = n < 0
        var v: Int64 = -n if negative else n
        var digits = List[UInt8]()
        while v > 0:
            var d = Int(v % 10)
            digits.append(UInt8(_BYTE_0 + d))
            v = v // 10
        if negative:
            self.bytes.append(UInt8(_BYTE_MINUS))
        var ndig = len(digits)
        for i in range(ndig):
            self.bytes.append(digits[ndig - 1 - i])

    def write_float(mut self, v: Float64):
        # Integer fast-path (exactly representable Int64 within +-2^53)
        # avoids the `1 → "1.0"` Mojo default-formatter wart for the common
        # workflow case (steps=30, seed=42, version=1, etc.).
        if v >= -9.007199254740992e15 and v <= 9.007199254740992e15:
            var as_int = Int64(v)
            if Float64(as_int) == v:
                self.write_int(as_int)
                return
        self.write_str(String(v))

    def result(var self) -> String:
        return String(unsafe_from_utf8=self.bytes^)


# JsonValue tagged union.

struct JsonValue(Copyable, Movable):
    """Tagged-union JSON value. `kind` is the discriminator; all variant
    slots are present unconditionally. Use the static constructors rather
    than poking raw fields — they keep `kind` aligned with the populated
    slot. Object data is stored as parallel `obj_keys` / `obj_values` lists
    in insertion order; emit sorts alphabetically per the EriGui VCS-stability
    invariant.
    """

    var kind: JsonKind
    var bool_val: Bool
    var num_val: Float64
    var str_val: String
    var arr_val: List[JsonValue]
    var obj_keys: List[String]
    var obj_values: List[JsonValue]

    def __init__(out self):
        """Default: JK_NULL with all slots zero/empty."""
        self.kind = JK_NULL
        self.bool_val = False
        self.num_val = 0.0
        self.str_val = String("")
        self.arr_val = List[JsonValue]()
        self.obj_keys = List[String]()
        self.obj_values = List[JsonValue]()

    # Static constructors — keep `kind` aligned with the populated slot.

    @staticmethod
    def null() -> JsonValue:
        return JsonValue()

    @staticmethod
    def bool_(v: Bool) -> JsonValue:
        var j = JsonValue(); j.kind = JK_BOOL; j.bool_val = v; return j^

    @staticmethod
    def number(v: Float64) -> JsonValue:
        var j = JsonValue(); j.kind = JK_NUMBER; j.num_val = v; return j^

    @staticmethod
    def number_i(v: Int) -> JsonValue:
        """Convenience for integer-valued numbers (id/version/etc.)."""
        var j = JsonValue(); j.kind = JK_NUMBER; j.num_val = Float64(v); return j^

    @staticmethod
    def string(v: String) -> JsonValue:
        var j = JsonValue(); j.kind = JK_STRING; j.str_val = v.copy(); return j^

    @staticmethod
    def array(items: List[JsonValue]) -> JsonValue:
        var j = JsonValue(); j.kind = JK_ARRAY; j.arr_val = items.copy(); return j^

    @staticmethod
    def object_(keys: List[String], values: List[JsonValue]) -> JsonValue:
        var j = JsonValue()
        j.kind = JK_OBJECT
        j.obj_keys = keys.copy()
        j.obj_values = values.copy()
        return j^

    @staticmethod
    def empty_object() -> JsonValue:
        var j = JsonValue(); j.kind = JK_OBJECT; return j^

    @staticmethod
    def empty_array() -> JsonValue:
        var j = JsonValue(); j.kind = JK_ARRAY; return j^

    # Accessors.

    def get_object_field(self, key: String) -> JsonValue:
        """Linear scan; returns `JsonValue.null()` on missing key."""
        var n = len(self.obj_keys)
        for i in range(n):
            if self.obj_keys[i] == key:
                return self.obj_values[i].copy()
        return JsonValue.null()

    def set_object_field(mut self, key: String, value: JsonValue):
        """Add or replace a key. Insertion-ordered; emit sorts. No-op when
        kind != JK_OBJECT."""
        if self.kind != JK_OBJECT:
            return
        var n = len(self.obj_keys)
        for i in range(n):
            if self.obj_keys[i] == key:
                self.obj_values[i] = value.copy()
                return
        self.obj_keys.append(key.copy())
        self.obj_values.append(value.copy())

    def equals(self, other: JsonValue) -> Bool:
        """Structural equality. Objects compare order-independent."""
        if self.kind != other.kind: return False
        if self.kind == JK_NULL: return True
        if self.kind == JK_BOOL: return self.bool_val == other.bool_val
        if self.kind == JK_NUMBER: return self.num_val == other.num_val
        if self.kind == JK_STRING: return self.str_val == other.str_val
        if self.kind == JK_ARRAY:
            var n = len(self.arr_val)
            if n != len(other.arr_val): return False
            for i in range(n):
                if not self.arr_val[i].equals(other.arr_val[i]): return False
            return True
        if self.kind == JK_OBJECT:
            var n = len(self.obj_keys)
            if n != len(other.obj_keys): return False
            for i in range(n):
                var found = False
                var k = self.obj_keys[i]
                for j in range(len(other.obj_keys)):
                    if other.obj_keys[j] == k:
                        if not self.obj_values[i].equals(other.obj_values[j]): return False
                        found = True
                        break
                if not found: return False
            return True
        return False


# Emit (JsonValue → String) — sorted object keys per EriGui invariant.

def emit_json(value: JsonValue) -> String:
    """Encode `value` as a compact JSON string. Object keys are sorted
    alphabetically (insertion order is NOT preserved) for VCS-diff stability
    per the EriGui invariant.
    """
    var sb = _StringBuilder()
    _emit_into(value, sb)
    return sb^.result()


def _emit_into(value: JsonValue, mut sb: _StringBuilder):
    """Recursive emit driver. Objects sort keys alphabetically."""
    if value.kind == JK_NULL:
        sb.write_str(String("null"))
    elif value.kind == JK_BOOL:
        sb.write_str(String("true") if value.bool_val else String("false"))
    elif value.kind == JK_NUMBER:
        sb.write_float(value.num_val)
    elif value.kind == JK_STRING:
        sb.write_byte(UInt8(_BYTE_QUOTE))
        _emit_escaped_string(value.str_val, sb)
        sb.write_byte(UInt8(_BYTE_QUOTE))
    elif value.kind == JK_ARRAY:
        sb.write_byte(UInt8(_BYTE_LBRACKET))
        var n = len(value.arr_val)
        for i in range(n):
            if i > 0: sb.write_byte(UInt8(_BYTE_COMMA))
            _emit_into(value.arr_val[i], sb)
        sb.write_byte(UInt8(_BYTE_RBRACKET))
    elif value.kind == JK_OBJECT:
        # Insertion sort over an index permutation. Object sizes are small.
        var n = len(value.obj_keys)
        var idx = List[Int]()
        for i in range(n): idx.append(i)
        for i in range(1, n):
            var j = i
            while j > 0 and value.obj_keys[idx[j - 1]] > value.obj_keys[idx[j]]:
                var tmp = idx[j - 1]; idx[j - 1] = idx[j]; idx[j] = tmp
                j = j - 1
        sb.write_byte(UInt8(_BYTE_LBRACE))
        for k in range(n):
            if k > 0: sb.write_byte(UInt8(_BYTE_COMMA))
            sb.write_byte(UInt8(_BYTE_QUOTE))
            _emit_escaped_string(value.obj_keys[idx[k]], sb)
            sb.write_byte(UInt8(_BYTE_QUOTE))
            sb.write_byte(UInt8(_BYTE_COLON))
            _emit_into(value.obj_values[idx[k]], sb)
        sb.write_byte(UInt8(_BYTE_RBRACE))


def _emit_escaped_string(s: String, mut sb: _StringBuilder):
    """Emit JSON escapes for `"`, `\\`, `\\n`, `\\r`, `\\t`. Other sub-0x20
    bytes emit the placeholder `\\u0000` (full `\\uXXXX` is M3). Bytes >=
    0x20 pass through verbatim (UTF-8 trusted)."""
    var n = s.byte_length()
    var ptr = s.unsafe_ptr()
    var BS = UInt8(_BYTE_BACKSLASH)
    for i in range(n):
        var b = Int(ptr[i])
        if b == _BYTE_QUOTE:        sb.write_byte(BS); sb.write_byte(UInt8(_BYTE_QUOTE))
        elif b == _BYTE_BACKSLASH:  sb.write_byte(BS); sb.write_byte(BS)
        elif b == _BYTE_LF:         sb.write_byte(BS); sb.write_byte(UInt8(_BYTE_LOWER_N))
        elif b == _BYTE_CR:         sb.write_byte(BS); sb.write_byte(UInt8(_BYTE_LOWER_R))
        elif b == _BYTE_TAB:        sb.write_byte(BS); sb.write_byte(UInt8(_BYTE_LOWER_T))
        elif b < 0x20:              sb.write_str(String("\\u0000"))
        else:                       sb.write_byte(UInt8(b))


# Parse (String → JsonValue).

def parse_json(input: String) raises -> JsonValue:
    """Parse a JSON string. Supports null/true/false, signed decimal numbers
    (with optional fractional + exponent), strings (with `\\"`/`\\\\`/`\\n`/
    `\\r`/`\\t`/`\\/`/`\\b`/`\\f` escapes), arrays, objects. Rejects
    `\\uXXXX`, comments, trailing commas, NaN, Infinity."""
    var p = JsonParser(input)
    var v = p.parse_value()
    p.skip_whitespace()
    if p.pos < p.input.byte_length():
        raise Error("parse_json: trailing content after JSON value at offset " + String(p.pos))
    return v^


struct JsonParser(Movable):
    """Single-pass parser over an in-memory String. Exposed for advanced
    callers; most use cases want `parse_json(input)` instead."""

    var input: String
    var pos: Int

    def __init__(out self, input: String):
        self.input = input.copy()
        self.pos = 0

    def peek(self) -> Int:
        """Peek the byte at `pos`. Returns -1 at end-of-input."""
        if self.pos >= self.input.byte_length():
            return -1
        return Int(self.input.unsafe_ptr()[self.pos])

    def advance(mut self):
        self.pos = self.pos + 1

    def skip_whitespace(mut self):
        var n = self.input.byte_length()
        var ptr = self.input.unsafe_ptr()
        while self.pos < n:
            var b = Int(ptr[self.pos])
            if b == _BYTE_SPACE or b == _BYTE_TAB or b == _BYTE_LF or b == _BYTE_CR:
                self.pos = self.pos + 1
            else:
                break

    def parse_value(mut self) raises -> JsonValue:
        self.skip_whitespace()
        var b = self.peek()
        if b == -1:
            raise Error("parse_json: unexpected end of input at offset " + String(self.pos))
        if b == _BYTE_LOWER_N: self._expect_literal(String("null")); return JsonValue.null()
        if b == _BYTE_LOWER_T: self._expect_literal(String("true")); return JsonValue.bool_(True)
        if b == _BYTE_LOWER_F: self._expect_literal(String("false")); return JsonValue.bool_(False)
        if b == _BYTE_QUOTE: return JsonValue.string(self._parse_string_bytes())
        if b == _BYTE_LBRACKET: return self._parse_array()
        if b == _BYTE_LBRACE: return self._parse_object()
        if b == _BYTE_MINUS or (b >= _BYTE_0 and b <= _BYTE_9):
            return JsonValue.number(self._parse_number())
        raise Error("parse_json: unexpected byte " + String(b) + " at offset " + String(self.pos))

    def _expect_literal(mut self, literal: String) raises:
        var n = literal.byte_length()
        var lp = literal.unsafe_ptr()
        var ip = self.input.unsafe_ptr()
        var input_len = self.input.byte_length()
        if self.pos + n > input_len:
            raise Error("parse_json: expected literal '" + literal + "' at offset " + String(self.pos))
        for i in range(n):
            if ip[self.pos + i] != lp[i]:
                raise Error("parse_json: expected literal '" + literal + "' at offset " + String(self.pos))
        self.pos = self.pos + n

    def _parse_string_bytes(mut self) raises -> String:
        # Caller positioned at the opening `"`. Consumes through closing `"`.
        if self.peek() != _BYTE_QUOTE:
            raise Error("parse_json: expected opening '\"' at offset " + String(self.pos))
        self.pos = self.pos + 1
        var bytes = List[UInt8]()
        var n = self.input.byte_length()
        var ptr = self.input.unsafe_ptr()
        while self.pos < n:
            var b = Int(ptr[self.pos])
            if b == _BYTE_QUOTE:
                self.pos = self.pos + 1
                return String(unsafe_from_utf8=bytes^)
            if b == _BYTE_BACKSLASH:
                self.pos = self.pos + 1
                if self.pos >= n:
                    raise Error("parse_json: unterminated escape at offset " + String(self.pos))
                var e = Int(ptr[self.pos])
                var decoded: Int = -1
                if e == _BYTE_QUOTE: decoded = _BYTE_QUOTE
                elif e == _BYTE_BACKSLASH: decoded = _BYTE_BACKSLASH
                elif e == _BYTE_LOWER_N: decoded = _BYTE_LF
                elif e == _BYTE_LOWER_R: decoded = _BYTE_CR
                elif e == _BYTE_LOWER_T: decoded = _BYTE_TAB
                elif e == 0x2F: decoded = 0x2F             # '/'
                elif e == _BYTE_LOWER_F: decoded = 0x0C    # '\f' form-feed
                elif e == 0x62: decoded = 0x08             # '\b' backspace
                if decoded < 0:
                    raise Error("parse_json: unsupported escape at offset " + String(self.pos))
                bytes.append(UInt8(decoded))
                self.pos = self.pos + 1
            else:
                bytes.append(UInt8(b))
                self.pos = self.pos + 1
        raise Error("parse_json: unterminated string starting at offset " + String(self.pos))

    def _consume_digits(mut self) -> Bool:
        """Consume zero+ ASCII digits; return True if any consumed."""
        var n = self.input.byte_length()
        var ptr = self.input.unsafe_ptr()
        var any = False
        while self.pos < n:
            var b = Int(ptr[self.pos])
            if b >= _BYTE_0 and b <= _BYTE_9:
                any = True
                self.pos = self.pos + 1
            else:
                break
        return any

    def _parse_number(mut self) raises -> Float64:
        var n = self.input.byte_length()
        var ptr = self.input.unsafe_ptr()
        var start = self.pos
        if self.pos < n and Int(ptr[self.pos]) == _BYTE_MINUS:
            self.pos = self.pos + 1
        if not self._consume_digits():
            raise Error("parse_json: malformed number at offset " + String(start))
        if self.pos < n and Int(ptr[self.pos]) == _BYTE_DOT:
            self.pos = self.pos + 1
            if not self._consume_digits():
                raise Error("parse_json: malformed number (no digits after '.') at offset " + String(self.pos))
        if self.pos < n:
            var eb = Int(ptr[self.pos])
            if eb == _BYTE_LOWER_E or eb == _BYTE_UPPER_E:
                self.pos = self.pos + 1
                if self.pos < n:
                    var sb = Int(ptr[self.pos])
                    if sb == _BYTE_MINUS or sb == _BYTE_PLUS:
                        self.pos = self.pos + 1
                if not self._consume_digits():
                    raise Error("parse_json: malformed exponent at offset " + String(self.pos))
        var num_bytes = List[UInt8](capacity=self.pos - start)
        for i in range(start, self.pos):
            num_bytes.append(ptr[i])
        return Float64(String(unsafe_from_utf8=num_bytes^))

    def _parse_array(mut self) raises -> JsonValue:
        if self.peek() != _BYTE_LBRACKET:
            raise Error("parse_json: expected '[' at offset " + String(self.pos))
        self.pos = self.pos + 1
        var items = List[JsonValue]()
        self.skip_whitespace()
        if self.peek() == _BYTE_RBRACKET:
            self.pos = self.pos + 1
            return JsonValue.array(items^)
        while True:
            var v = self.parse_value()
            items.append(v^)
            self.skip_whitespace()
            var b = self.peek()
            if b == _BYTE_COMMA: self.pos = self.pos + 1; self.skip_whitespace(); continue
            if b == _BYTE_RBRACKET: self.pos = self.pos + 1; return JsonValue.array(items^)
            raise Error("parse_json: expected ',' or ']' in array at offset " + String(self.pos))

    def _parse_object(mut self) raises -> JsonValue:
        if self.peek() != _BYTE_LBRACE:
            raise Error("parse_json: expected '{' at offset " + String(self.pos))
        self.pos = self.pos + 1
        var keys = List[String]()
        var values = List[JsonValue]()
        self.skip_whitespace()
        if self.peek() == _BYTE_RBRACE:
            self.pos = self.pos + 1
            return JsonValue.object_(keys^, values^)
        while True:
            self.skip_whitespace()
            if self.peek() != _BYTE_QUOTE:
                raise Error("parse_json: expected string key at offset " + String(self.pos))
            var key = self._parse_string_bytes()
            self.skip_whitespace()
            if self.peek() != _BYTE_COLON:
                raise Error("parse_json: expected ':' after key at offset " + String(self.pos))
            self.pos = self.pos + 1
            var v = self.parse_value()
            keys.append(key^); values.append(v^)
            self.skip_whitespace()
            var b = self.peek()
            if b == _BYTE_COMMA: self.pos = self.pos + 1; continue
            if b == _BYTE_RBRACE: self.pos = self.pos + 1; return JsonValue.object_(keys^, values^)
            raise Error("parse_json: expected ',' or '}' in object at offset " + String(self.pos))
