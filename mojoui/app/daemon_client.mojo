"""SerenityUI ↔ serenity_daemon HTTP client (DAEMON_BRIDGE_SPEC.md).

Thin blocking client over MOJO-libs http/client.mojo against the resident
generation daemon on 127.0.0.1:7801. Every call opens a fresh localhost
connection with a short recv timeout, so a daemon that dies mid-session costs
one bounded stall and then reads as unhealthy (the UI falls back to CLI).

Endpoints used: /v1/health, /v1/models, /v1/generate, /v1/jobs,
/v1/cancel/<id>. Progress is polled from /v1/jobs (the spec's "start with
polling" option); the WS channel stays daemon-side for later.
"""

from http.client import request, ClientOptions, Header, HttpResponse
from json.parser import loads
from json.value import JSONValue


comptime DAEMON_HOST = "127.0.0.1"
comptime DAEMON_PORT = 7801
comptime DAEMON_BASE = "http://127.0.0.1:7801"


struct DaemonHealth(Copyable, Movable):
    var ok: Bool
    var backend: String
    var model: String
    var resident: String

    def __init__(out self):
        self.ok = False
        self.backend = String("")
        self.model = String("")
        self.resident = String("")


struct DaemonModelEntry(Copyable, Movable):
    var name: String
    var path: String
    var arch: String
    var size: Int
    var loaded: Bool

    def __init__(out self, name: String, path: String, arch: String, size: Int, loaded: Bool):
        self.name = name.copy()
        self.path = path.copy()
        self.arch = arch.copy()
        self.size = size
        self.loaded = loaded


struct DaemonLoraEntry(Copyable, Movable):
    var name: String
    var path: String
    var size: Int

    def __init__(out self, name: String, path: String, size: Int):
        self.name = name.copy()
        self.path = path.copy()
        self.size = size


struct DaemonJobInfo(Copyable, Movable):
    var id: String
    var created: String
    var model: String
    var state: String      # queued|running|done|failed|cancelled|interrupted
    var progress: Int      # 0..100
    var step: Int
    var total: Int
    var output_path: String
    var error: String

    def __init__(out self):
        self.id = String("")
        self.created = String("")
        self.model = String("")
        self.state = String("")
        self.progress = 0
        self.step = 0
        self.total = 0
        self.output_path = String("")
        self.error = String("")

    def is_terminal(self) -> Bool:
        return (
            self.state == "done" or self.state == "failed"
            or self.state == "cancelled" or self.state == "interrupted"
        )


def _opts(timeout_ms: Int) -> ClientOptions:
    var o = ClientOptions()
    o.timeout_ms = timeout_ms
    o.max_redirects = 0
    o.decompress = False
    o.verify_tls = False
    return o^


def _get(path: String, timeout_ms: Int) raises -> HttpResponse:
    return request(
        String("GET"), String(DAEMON_BASE) + path,
        List[Header](), List[UInt8](), _opts(timeout_ms),
    )


def _post(path: String, body: String, timeout_ms: Int) raises -> HttpResponse:
    var hdrs = List[Header]()
    hdrs.append(Header(String("content-type"), String("application/json")))
    var bytes = List[UInt8]()
    var src = body.as_bytes()
    for i in range(body.byte_length()):
        bytes.append(src[i])
    return request(
        String("POST"), String(DAEMON_BASE) + path, hdrs^, bytes^, _opts(timeout_ms),
    )


def _opt_str(obj: JSONValue, key: String) raises -> String:
    if obj.contains(key) and obj[key].is_string():
        return obj[key].as_string()
    return String("")


def _opt_int(obj: JSONValue, key: String) raises -> Int:
    if obj.contains(key) and obj[key].is_int():
        return obj[key].as_int()
    return 0


def daemon_health(timeout_ms: Int = 500) -> DaemonHealth:
    """GET /v1/health. Never raises: any failure -> ok=False (CLI fallback)."""
    var h = DaemonHealth()
    try:
        var resp = _get(String("/v1/health"), timeout_ms)
        if resp.status != 200:
            return h^
        var obj = loads(resp.text())
        if not obj.is_object():
            return h^
        h.ok = _opt_str(obj, String("status")) == "ok"
        h.backend = _opt_str(obj, String("backend"))
        h.model = _opt_str(obj, String("model"))
        h.resident = _opt_str(obj, String("resident"))
    except:
        h.ok = False
    return h^


def daemon_models(
    mut models: List[DaemonModelEntry], mut loras: List[DaemonLoraEntry],
    timeout_ms: Int = 4000,
) raises:
    """GET /v1/models — the disk scan (P1 model selector + P2 LoRA options)."""
    var resp = _get(String("/v1/models"), timeout_ms)
    if resp.status != 200:
        raise Error("daemon /v1/models -> HTTP " + String(resp.status))
    var obj = loads(resp.text())
    if obj.contains(String("models")) and obj[String("models")].is_array():
        var arr = obj[String("models")]
        for i in range(arr.length()):
            var m = arr[i]
            if not m.is_object():
                continue
            var loaded = False
            if m.contains(String("loaded")) and m[String("loaded")].is_bool():
                loaded = m[String("loaded")].as_bool()
            models.append(DaemonModelEntry(
                _opt_str(m, String("name")), _opt_str(m, String("path")),
                _opt_str(m, String("arch")), _opt_int(m, String("size")), loaded,
            ))
    if obj.contains(String("loras")) and obj[String("loras")].is_array():
        var arr = obj[String("loras")]
        for i in range(arr.length()):
            var m = arr[i]
            if not m.is_object():
                continue
            loras.append(DaemonLoraEntry(
                _opt_str(m, String("name")), _opt_str(m, String("path")),
                _opt_int(m, String("size")),
            ))


def daemon_generate(genparams_json: String, timeout_ms: Int = 4000) raises -> String:
    """POST /v1/generate with a canonical serenity.genparams.v1 body.
    Returns the job_id; raises with the server's detail on any error."""
    var resp = _post(String("/v1/generate"), genparams_json, timeout_ms)
    var obj = loads(resp.text())
    if resp.status != 200:
        var detail = String("")
        if obj.is_object():
            detail = _opt_str(obj, String("detail"))
        raise Error(
            "daemon /v1/generate -> HTTP " + String(resp.status) + ": " + detail
        )
    if not obj.is_object():
        raise Error("daemon /v1/generate: malformed response")
    return _opt_str(obj, String("job_id"))


def _job_from_value(v: JSONValue) raises -> DaemonJobInfo:
    var j = DaemonJobInfo()
    j.id = _opt_str(v, String("id"))
    j.created = _opt_str(v, String("created"))
    j.model = _opt_str(v, String("model"))
    j.state = _opt_str(v, String("state"))
    j.progress = _opt_int(v, String("progress"))
    j.step = _opt_int(v, String("step"))
    j.total = _opt_int(v, String("total"))
    j.output_path = _opt_str(v, String("output_path"))
    j.error = _opt_str(v, String("error"))
    return j^


def daemon_jobs(timeout_ms: Int = 1500) raises -> List[DaemonJobInfo]:
    """GET /v1/jobs — the queue rail + progress poll source (P11/P12)."""
    var resp = _get(String("/v1/jobs"), timeout_ms)
    if resp.status != 200:
        raise Error("daemon /v1/jobs -> HTTP " + String(resp.status))
    var arr = loads(resp.text())
    var out = List[DaemonJobInfo]()
    if not arr.is_array():
        return out^
    for i in range(arr.length()):
        if arr[i].is_object():
            out.append(_job_from_value(arr[i]))
    return out^


def daemon_cancel(job_id: String, timeout_ms: Int = 2000) raises -> Bool:
    """POST /v1/cancel/<id>. True on 200; False on 409 (already terminal);
    raises on anything else."""
    var resp = _post(String("/v1/cancel/") + job_id, String(""), timeout_ms)
    if resp.status == 200:
        return True
    if resp.status == 409:
        return False
    raise Error("daemon /v1/cancel -> HTTP " + String(resp.status))
