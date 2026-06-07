"""Headless Backend.system_metrics smoke test."""

from mojoui.render.backend import Backend


def _expect(cond: Bool, msg: String) raises:
    if not cond:
        print("FAIL:", msg)
        raise Error(msg)


def main() raises:
    var metrics = Backend.system_metrics()
    _expect(metrics.ram_total_mb >= 0, "ram total is non-negative")
    _expect(metrics.ram_used_mb >= 0, "ram used is non-negative")
    _expect(metrics.cpu_util_percent >= 0, "cpu util is non-negative")
    if metrics.gpu_available:
        _expect(metrics.gpu_name.byte_length() > 0, "gpu name is populated")
        _expect(metrics.gpu_memory_total_mb > 0, "gpu memory total is populated")
        _expect(metrics.gpu_temperature_c >= 0, "gpu temperature is populated")
    print("PASS: system metrics")
