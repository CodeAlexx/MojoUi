"""Prompt-syntax parser for the gen screen (plan P9/P10).

Three syntaxes, resolved at SUBMIT time (the original prompt is preserved in
genparams as `prompt_raw`, the resolved prompt goes in `prompt`):

  (text:1.3)        — attention weighting. Backends do not consume weights yet,
                      so the group is PASSED THROUGH verbatim; the parser only
                      VALIDATES paren balance + that the weight tail is numeric
                      (soft notes, never a rewrite).
  <lora:name:0.8>   — extracted from the prompt text and returned as a LoRA
                      request (weight optional, default 1.0); the tag is
                      REMOVED from the resolved prompt. The caller merges the
                      extraction into the UI LoRA stack (dedup by name — the
                      UI stack wins on conflict).
  <random:a|b|c>    — uniform pick, seeded by the JOB seed (splitmix64):
                      deterministic per seed, replacement at submit. Nested
                      <random:> inside an option resolves on the next pass
                      (outer-first, left-to-right, max 16 passes).

MALFORMED syntax is NEVER fatal: the broken span is passed through verbatim
and a human-readable note is appended (surfaced as a status line). The parser
never raises on user input.

Byte-level scanning is UTF-8 safe: every delimiter ('<', '>', '|', ':', '(',
')') is ASCII and UTF-8 continuation bytes have the high bit set.
"""


struct PromptLora(Copyable, Movable):
    """One <lora:name:weight> extraction."""

    var name: String
    var weight: Float64

    def __init__(out self, name: String, weight: Float64):
        self.name = name.copy()
        self.weight = weight


struct PromptParse(Movable):
    """resolve_prompt() result."""

    var resolved: String          # prompt with <lora:>/<random:> consumed
    var loras: List[PromptLora]   # extracted <lora:> requests, in order
    var notes: List[String]       # malformed-syntax notes (status line)
    var had_syntax: Bool          # any tag consumed (=> keep prompt_raw)

    def __init__(out self):
        self.resolved = String("")
        self.loras = List[PromptLora]()
        self.notes = List[String]()
        self.had_syntax = False


# ── deterministic per-seed RNG (splitmix64) ─────────────────────────────────
def _mix64(mut state: UInt64) -> UInt64:
    state += UInt64(0x9E3779B97F4A7C15)
    var z = state
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


# ── tiny helpers ─────────────────────────────────────────────────────────────
def _bytes_to_string(bytes: List[UInt8]) -> String:
    var b = bytes.copy()
    return String(unsafe_from_utf8=b^)


def _substr(s: String, lo: Int, hi: Int) -> String:
    var src = s.as_bytes()
    var out = List[UInt8]()
    var stop = hi
    if stop > s.byte_length():
        stop = s.byte_length()
    var i = lo
    while i < stop:
        out.append(src[i])
        i += 1
    return _bytes_to_string(out)


def _starts_at(s: String, pos: Int, pat: String) -> Bool:
    var n = pat.byte_length()
    if pos + n > s.byte_length():
        return False
    var sb = s.as_bytes()
    var pb = pat.as_bytes()
    for i in range(n):
        if sb[pos + i] != pb[i]:
            return False
    return True


def _parse_float(s: String, mut ok: Bool) -> Float64:
    """[+-]?digits[.digits] — strict; anything else fails. Surrounding
    spaces tolerated."""
    ok = False
    var b = s.as_bytes()
    var n = s.byte_length()
    var i = 0
    while i < n and (b[i] == 32 or b[i] == 9):
        i += 1
    var neg = False
    if i < n and (b[i] == 45 or b[i] == 43):  # '-' / '+'
        neg = b[i] == 45
        i += 1
    var int_part = Float64(0.0)
    var got_int = False
    while i < n and b[i] >= 48 and b[i] <= 57:
        int_part = int_part * 10.0 + Float64(Int(b[i]) - 48)
        got_int = True
        i += 1
    var frac = Float64(0.0)
    var scale = Float64(1.0)
    var got_frac = False
    if i < n and b[i] == 46:  # '.'
        i += 1
        while i < n and b[i] >= 48 and b[i] <= 57:
            frac = frac * 10.0 + Float64(Int(b[i]) - 48)
            scale *= 10.0
            got_frac = True
            i += 1
    while i < n and (b[i] == 32 or b[i] == 9):
        i += 1
    if i != n or not (got_int or got_frac):
        return Float64(0.0)
    ok = True
    var v = int_part + frac / scale
    return -v if neg else v


def _trim(s: String) -> String:
    var b = s.as_bytes()
    var n = s.byte_length()
    var lo = 0
    while lo < n and (b[lo] == 32 or b[lo] == 9):
        lo += 1
    var hi = n
    while hi > lo and (b[hi - 1] == 32 or b[hi - 1] == 9):
        hi -= 1
    return _substr(s, lo, hi)


# ── <random:a|b|c> — one outer-first, left-to-right pass ────────────────────
def _resolve_randoms_pass(
    text: String, mut rng: UInt64, mut notes: List[String], mut changed: Bool,
) -> String:
    var b = text.as_bytes()
    var n = text.byte_length()
    var out = List[UInt8]()
    var i = 0
    while i < n:
        if not _starts_at(text, i, String("<random:")):
            out.append(b[i])
            i += 1
            continue
        # find the matching '>' (depth-counted: nested <...> stay intact)
        var body_lo = i + 8
        var j = body_lo
        var depth = 1
        var close = -1
        while j < n:
            if b[j] == 60:  # '<'
                depth += 1
            elif b[j] == 62:  # '>'
                depth -= 1
                if depth == 0:
                    close = j
                    break
            j += 1
        if close < 0:
            notes.append(
                String("unterminated <random:...> passed through verbatim")
            )
            while i < n:  # rest of the text is verbatim
                out.append(b[i])
                i += 1
            break
        if close == body_lo:
            notes.append(String("empty <random:> passed through verbatim"))
            while i <= close:
                out.append(b[i])
                i += 1
            continue
        # split the body on TOP-LEVEL '|' (nested tags keep their own '|')
        var options = List[String]()
        var seg_lo = body_lo
        var d2 = 0
        var k = body_lo
        while k <= close:
            if k == close or (b[k] == 124 and d2 == 0):  # '|'
                options.append(_substr(text, seg_lo, k))
                seg_lo = k + 1
            elif b[k] == 60:
                d2 += 1
            elif b[k] == 62:
                d2 -= 1
            k += 1
        var pick = Int(_mix64(rng) % UInt64(len(options)))
        var chosen = options[pick]
        var cb = chosen.as_bytes()
        for t in range(chosen.byte_length()):
            out.append(cb[t])
        changed = True
        i = close + 1
    return _bytes_to_string(out)


# ── <lora:name[:weight]> extraction ──────────────────────────────────────────
def _extract_loras(
    text: String, mut loras: List[PromptLora], mut notes: List[String],
) -> String:
    var b = text.as_bytes()
    var n = text.byte_length()
    var out = List[UInt8]()
    var i = 0
    while i < n:
        if not _starts_at(text, i, String("<lora:")):
            out.append(b[i])
            i += 1
            continue
        var body_lo = i + 6
        var j = body_lo
        var close = -1
        var nested = False
        while j < n:
            if b[j] == 62:  # '>'
                close = j
                break
            if b[j] == 60:  # '<' before '>' — malformed
                nested = True
                break
            j += 1
        if close < 0 or nested:
            notes.append(
                String("malformed <lora:...> passed through verbatim")
            )
            out.append(b[i])
            i += 1  # re-scan from the next byte (tag is broken anyway)
            continue
        var body = _substr(text, body_lo, close)
        # last ':'-segment = weight IF it parses as a float; else whole
        # body is the name (weight 1.0)
        var name = _trim(body)
        var weight = Float64(1.0)
        var bb = body.as_bytes()
        var last_colon = -1
        for t in range(body.byte_length()):
            if bb[t] == 58:  # ':'
                last_colon = t
        var weight_ok = True
        if last_colon >= 0:
            var tail = _substr(body, last_colon + 1, body.byte_length())
            var wok = False
            var w = _parse_float(tail, wok)
            if wok:
                name = _trim(_substr(body, 0, last_colon))
                weight = w
            else:
                weight_ok = False
        if name.byte_length() == 0 or not weight_ok:
            notes.append(
                String("malformed <lora:") + body
                + String("> passed through verbatim")
            )
            while i <= close:
                out.append(b[i])
                i += 1
            continue
        loras.append(PromptLora(name^, weight))
        # collapse the seam: tag removal must not leave a double space
        i = close + 1
        if len(out) > 0 and out[len(out) - 1] == 32:
            while i < n and b[i] == 32:
                i += 1
        elif len(out) == 0:
            while i < n and b[i] == 32:
                i += 1
    return _bytes_to_string(out)


# ── (text:1.3) weighting — VALIDATE ONLY (pass-through) ──────────────────────
def _validate_weight_syntax(text: String, mut notes: List[String]):
    """Soft validation: paren balance + numeric weight tails. The text is
    never modified (backends do not consume weights yet)."""
    var b = text.as_bytes()
    var n = text.byte_length()
    var depth = 0
    var group_start = List[Int]()   # stack: byte pos of each open '('
    var group_colon = List[Int]()   # stack: last top-of-group ':' (-1 = none)
    for i in range(n):
        if b[i] == 40:  # '('
            depth += 1
            group_start.append(i)
            group_colon.append(-1)
        elif b[i] == 58 and depth > 0:  # ':'
            group_colon[len(group_colon) - 1] = i
        elif b[i] == 41:  # ')'
            if depth == 0:
                notes.append(
                    String("unbalanced ')' in prompt — weights passed through")
                )
                return
            depth -= 1
            var gs = group_start.pop()
            var gc = group_colon.pop()
            if gc >= 0:
                var tail = _substr(text, gc + 1, i)
                var wok = False
                _ = _parse_float(tail, wok)
                if not wok:
                    notes.append(
                        String("weight tag '")
                        + _substr(text, gs, i + 1)
                        + String("' not numeric — passed through")
                    )
    if depth != 0:
        notes.append(
            String("unbalanced '(' in prompt — weights passed through")
        )


# ── the public entry point ───────────────────────────────────────────────────
def resolve_prompt(prompt: String, seed: Int) -> PromptParse:
    """Resolve all prompt syntax against the CONCRETE job seed. Never raises
    on user input; malformed spans pass through verbatim with a note."""
    var r = PromptParse()
    var rng = UInt64(seed if seed >= 0 else -seed)
    var text = prompt.copy()
    var any_random = False
    for _ in range(16):  # nesting cap (outer-first, one level per pass)
        var changed = False
        text = _resolve_randoms_pass(text, rng, r.notes, changed)
        if not changed:
            break
        any_random = True
    var n_loras_before = len(r.loras)
    text = _extract_loras(text, r.loras, r.notes)
    _validate_weight_syntax(text, r.notes)
    r.had_syntax = any_random or len(r.loras) > n_loras_before
    r.resolved = text^
    return r^


def parse_float_strict(s: String, mut ok: Bool) -> Float64:
    """Public strict float parse ([+-]?digits[.digits]); ok=False on junk."""
    return _parse_float(s, ok)


def join_notes(notes: List[String]) -> String:
    var out = String("")
    for i in range(len(notes)):
        if i > 0:
            out += String("; ")
        out += notes[i]
    return out^


# ── unit gate (G3a): 10+ cases incl. nesting + malformed ────────────────────
def selftest_prompt_syntax() raises:
    print("[selftest-syntax] === prompt-syntax unit gate (G3a) ===")
    var fails = 0

    # 1. plain prompt — untouched, no syntax
    var r1 = resolve_prompt(String("a red bicycle, golden hour"), 42)
    if r1.resolved != String("a red bicycle, golden hour") or r1.had_syntax \
            or len(r1.loras) != 0 or len(r1.notes) != 0:
        print("[selftest-syntax] FAIL 1 plain prompt:", r1.resolved)
        fails += 1

    # 2. (text:1.3) — pass-through verbatim, valid, no notes
    var r2 = resolve_prompt(String("a (ornate:1.3) castle"), 42)
    if r2.resolved != String("a (ornate:1.3) castle") or len(r2.notes) != 0 \
            or r2.had_syntax:
        print("[selftest-syntax] FAIL 2 weight pass-through:", r2.resolved,
              join_notes(r2.notes))
        fails += 1

    # 3. unbalanced '(' — pass-through + note, never crash
    var r3 = resolve_prompt(String("a (broken:1.2 castle"), 42)
    if r3.resolved != String("a (broken:1.2 castle") or len(r3.notes) == 0:
        print("[selftest-syntax] FAIL 3 unbalanced paren:", r3.resolved)
        fails += 1

    # 4. non-numeric weight — pass-through + note
    var r4 = resolve_prompt(String("a (text:abc) castle"), 42)
    if r4.resolved != String("a (text:abc) castle") or len(r4.notes) == 0:
        print("[selftest-syntax] FAIL 4 non-numeric weight:", r4.resolved)
        fails += 1

    # 5. <lora:name:0.8> — extracted + removed
    var r5 = resolve_prompt(String("a castle <lora:detail-tweaker:0.8> at dusk"), 42)
    if r5.resolved != String("a castle at dusk") or len(r5.loras) != 1 \
            or r5.loras[0].name != String("detail-tweaker") \
            or r5.loras[0].weight != 0.8 or not r5.had_syntax:
        print("[selftest-syntax] FAIL 5 lora extract: '", r5.resolved, "'",
              len(r5.loras))
        fails += 1

    # 6. <lora:name> — default weight 1.0
    var r6 = resolve_prompt(String("<lora:film-grain> a castle"), 42)
    if r6.resolved != String("a castle") or len(r6.loras) != 1 \
            or r6.loras[0].weight != 1.0:
        print("[selftest-syntax] FAIL 6 lora default weight: '", r6.resolved, "'")
        fails += 1

    # 7. malformed <lora:> (empty name) — verbatim + note
    var r7 = resolve_prompt(String("a castle <lora:> here"), 42)
    if r7.resolved != String("a castle <lora:> here") or len(r7.notes) == 0 \
            or len(r7.loras) != 0:
        print("[selftest-syntax] FAIL 7 empty lora: '", r7.resolved, "'")
        fails += 1

    # 8. malformed <lora:name:xx> (bad weight) — verbatim + note
    var r8 = resolve_prompt(String("a <lora:style:xx> castle"), 42)
    if r8.resolved != String("a <lora:style:xx> castle") or len(r8.notes) == 0 \
            or len(r8.loras) != 0:
        print("[selftest-syntax] FAIL 8 bad lora weight: '", r8.resolved, "'")
        fails += 1

    # 9. <random:a|b|c> — deterministic per seed; picks one of the options;
    # different seeds reach >= 2 distinct picks
    var base = resolve_prompt(String("sky at <random:dawn|dusk|midnight>"), 7)
    var again = resolve_prompt(String("sky at <random:dawn|dusk|midnight>"), 7)
    if base.resolved != again.resolved:
        print("[selftest-syntax] FAIL 9a determinism:", base.resolved, "vs",
              again.resolved)
        fails += 1
    var is_opt = (
        base.resolved == String("sky at dawn")
        or base.resolved == String("sky at dusk")
        or base.resolved == String("sky at midnight")
    )
    if not is_opt or not base.had_syntax:
        print("[selftest-syntax] FAIL 9b pick not an option:", base.resolved)
        fails += 1
    var distinct = List[String]()
    for seed in range(24):
        var rr = resolve_prompt(String("sky at <random:dawn|dusk|midnight>"), seed)
        var seen = False
        for k in range(len(distinct)):
            if distinct[k] == rr.resolved:
                seen = True
        if not seen:
            distinct.append(rr.resolved.copy())
    if len(distinct) < 2:
        print("[selftest-syntax] FAIL 9c seeds 0..23 all picked the same option")
        fails += 1

    # 10. nested <random:a|<random:b|c>> — resolves fully, to a leaf option
    var r10 = resolve_prompt(String("color <random:red|<random:green|blue>>"), 3)
    var leaf = (
        r10.resolved == String("color red")
        or r10.resolved == String("color green")
        or r10.resolved == String("color blue")
    )
    if not leaf:
        print("[selftest-syntax] FAIL 10 nested random: '", r10.resolved, "'")
        fails += 1
    var r10b = resolve_prompt(String("color <random:red|<random:green|blue>>"), 3)
    if r10b.resolved != r10.resolved:
        print("[selftest-syntax] FAIL 10b nested determinism")
        fails += 1

    # 11. unterminated <random: — verbatim + note, never crash
    var r11 = resolve_prompt(String("sky at <random:dawn|dusk"), 7)
    if r11.resolved != String("sky at <random:dawn|dusk") or len(r11.notes) == 0:
        print("[selftest-syntax] FAIL 11 unterminated random: '", r11.resolved, "'")
        fails += 1

    # 12. all three syntaxes combined
    var r12 = resolve_prompt(
        String("(epic:1.2) castle <lora:style:0.5> at <random:day|day>"), 99
    )
    if r12.resolved != String("(epic:1.2) castle at day") \
            or len(r12.loras) != 1 or r12.loras[0].name != String("style") \
            or r12.loras[0].weight != 0.5 or len(r12.notes) != 0:
        print("[selftest-syntax] FAIL 12 combined: '", r12.resolved, "'",
              join_notes(r12.notes))
        fails += 1

    # 13. weight syntax round-trip survives lora/random resolution untouched
    var r13 = resolve_prompt(
        String("a (red:1.4) wall <lora:g:1.1> (soft light:0.9)"), 5
    )
    if r13.resolved != String("a (red:1.4) wall (soft light:0.9)"):
        print("[selftest-syntax] FAIL 13 weight round-trip: '", r13.resolved, "'")
        fails += 1

    if fails > 0:
        raise Error(
            String("selftest-syntax: ") + String(fails) + String(" case(s) FAILED")
        )
    print("[selftest-syntax] ALL 13 CASES PASS")
