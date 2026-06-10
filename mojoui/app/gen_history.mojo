"""Persistent gen-screen history, stars, and presets (P8/P14/P15/P16).

* History (P14): read the daemon's jobs.db (pure-Mojo MOJO-libs sqlite
  reader) + merge live session jobs — survives UI restarts.
* Reuse-params (P15): read the `serenity.genparams.v1` tEXt chunk straight
  out of an output PNG (MOJO-libs image read_png_text).
* Stars (P16): a sidecar JSON (~/.serenity/ui_stars.json) holding starred
  job ids — persisted on every toggle.
* Presets (P8): named genparams JSON files under ~/.serenity/ui_presets/.
"""

from std.ffi import external_call
from std.io.file import open
from std.memory import alloc, UnsafePointer
from std.builtin.type_aliases import MutExternalOrigin

from http.request import byte_substr
from image.png import read_png_text
from json.parser import loads
from json.serialize import dumps
from json.value import JSONValue
from sqlite.db import Database


comptime DAEMON_ROOT = "/home/alex/mojodiffusion"
comptime JOBS_DB_PATH = "/home/alex/mojodiffusion/output/serenity_daemon/jobs.db"
comptime STARS_PATH = "/home/alex/.serenity/ui_stars.json"
comptime PRESETS_DIR = "/home/alex/.serenity/ui_presets"
comptime PRESET_LIST_TMP = "/tmp/serenityui_preset_scan.txt"
comptime GENPARAMS_TEXT_KEY = "serenity.genparams.v1"


def _shell(cmd: String) -> Int:
    var n = cmd.byte_length()
    var buf = alloc[UInt8](n + 1)
    var src = cmd.as_bytes()
    for i in range(n):
        buf[i] = src[i]
    buf[n] = 0
    var status = Int(external_call["system", Int32](
        UnsafePointer[UInt8, MutExternalOrigin](unsafe_from_address=Int(buf))
    ))
    buf.free()
    return status


def _write_text(path: String, text: String) raises:
    var bytes = List[UInt8]()
    var src = text.as_bytes()
    for i in range(text.byte_length()):
        bytes.append(src[i])
    with open(path, String("w")) as f:
        f.write_bytes(Span(bytes))


def _read_text(path: String) raises -> String:
    with open(path, String("r")) as f:
        return f.read()


struct GalleryItem(Copyable, Movable):
    """One persisted generation (a jobs.db row / a finished daemon job)."""

    var job_id: String
    var created: String
    var model: String
    var state: String
    var output_path: String   # absolute
    var params_json: String   # genparams (db copy; PNG tEXt is authoritative)
    var starred: Bool

    def __init__(out self):
        self.job_id = String("")
        self.created = String("")
        self.model = String("")
        self.state = String("")
        self.output_path = String("")
        self.params_json = String("")
        self.starred = False


def absolutize_output_path(path: String) -> String:
    """The daemon records output paths relative to its own cwd."""
    if path.byte_length() == 0 or path.startswith("/"):
        return path.copy()
    return String(DAEMON_ROOT) + "/" + path


def load_gallery_from_db(starred_ids: List[String]) -> List[GalleryItem]:
    """jobs.db rows (id, created, model, params_json, state, output_path) ->
    GalleryItems for every DONE job with an output. Missing/unreadable db ->
    empty history (first run)."""
    var out = List[GalleryItem]()
    try:
        var db = Database.open(String(JOBS_DB_PATH))
        var rows = db.read_table(String("jobs"))
        for i in range(len(rows)):
            var v = rows[i].values.copy()
            if len(v) < 6:
                continue
            var item = GalleryItem()
            item.job_id = v[0].as_text()
            item.created = v[1].as_text()
            item.model = v[2].as_text()
            item.params_json = v[3].as_text()
            item.state = v[4].as_text()
            item.output_path = absolutize_output_path(v[5].as_text())
            if item.state != "done" or item.output_path.byte_length() == 0:
                continue
            for k in range(len(starred_ids)):
                if starred_ids[k] == item.job_id:
                    item.starred = True
                    break
            out.append(item^)
    except:
        pass
    return out^


def read_genparams_from_png(path: String) raises -> String:
    """P15: pull the serenity.genparams.v1 tEXt value out of an output PNG."""
    var kws = List[String]()
    var vals = List[String]()
    read_png_text(path, kws, vals)
    for i in range(len(kws)):
        if kws[i] == GENPARAMS_TEXT_KEY:
            return vals[i].copy()
    raise Error("no " + GENPARAMS_TEXT_KEY + " tEXt chunk in " + path)


# ── stars (P16) ──────────────────────────────────────────────────────────────
def load_stars() -> List[String]:
    var out = List[String]()
    try:
        var obj = loads(_read_text(String(STARS_PATH)))
        if obj.is_object() and obj.contains(String("starred")):
            var arr = obj[String("starred")]
            if arr.is_array():
                for i in range(arr.length()):
                    if arr[i].is_string():
                        out.append(arr[i].as_string())
    except:
        pass  # no stars file yet
    return out^


def save_stars(ids: List[String]):
    try:
        _ = _shell(String("mkdir -p /home/alex/.serenity"))
        var arr = JSONValue.new_array()
        for i in range(len(ids)):
            arr.append(JSONValue.from_string(ids[i]))
        var o = JSONValue.new_object()
        o.set(String("starred"), arr^)
        _write_text(String(STARS_PATH), dumps(o))
    except e:
        print("[gen-history] stars save failed:", String(e))


# ── presets (P8) ─────────────────────────────────────────────────────────────
def sanitize_preset_name(name: String) -> String:
    """Keep [A-Za-z0-9_-]; everything else becomes '_'. Empty -> 'preset'."""
    var out = String("")
    var b = name.as_bytes()
    for i in range(name.byte_length()):
        var c = Int(b[i])
        var ok = (
            (c >= 48 and c <= 57) or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122) or c == 45 or c == 95
        )
        out += chr(c) if ok else String("_")
    if out.byte_length() == 0:
        out = String("preset")
    return out^


def list_presets() -> List[String]:
    """Names (no .json) of saved presets under PRESETS_DIR, sorted."""
    var out = List[String]()
    var cmd = (
        String("mkdir -p ") + PRESETS_DIR + " && find '" + PRESETS_DIR
        + "' -maxdepth 1 -type f -name '*.json' -printf '%f\\n' 2>/dev/null"
        + " | sort > " + PRESET_LIST_TMP
    )
    if _shell(cmd) != 0:
        return out^
    try:
        var text = _read_text(String(PRESET_LIST_TMP))
        for line in text.split("\n"):
            var l = String(line)
            if l.endswith(".json"):
                out.append(byte_substr(l, 0, l.byte_length() - 5))
    except:
        pass
    return out^


def save_preset(name: String, genparams_json: String) raises -> String:
    """Write a named preset (canonical genparams JSON). Returns the
    sanitized name actually used."""
    _ = _shell(String("mkdir -p ") + PRESETS_DIR)
    var clean = sanitize_preset_name(name)
    _write_text(String(PRESETS_DIR) + "/" + clean + ".json", genparams_json)
    return clean^


def load_preset(name: String) raises -> String:
    return _read_text(String(PRESETS_DIR) + "/" + name + ".json")
