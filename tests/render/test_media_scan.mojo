"""Media scanner test. Uses temp files prepared by the pixi task."""

from mojoui.render.backend import Backend


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def main() raises:
    var files = Backend.scan_media_files(String("/tmp/mojoui_media_scan"), True, 32)
    if len(files) < 2:
        _fail("expected scanner to find temp image and video files")
    var saw_image = False
    var saw_video = False
    for i in range(len(files)):
        if files[i].is_video:
            saw_video = True
        else:
            saw_image = True
    if not saw_image:
        _fail("expected at least one image file")
    if not saw_video:
        _fail("expected at least one video file")
    Backend.clear_media_scan_cache()
    print("PASS: media scan found", len(files), "files")
