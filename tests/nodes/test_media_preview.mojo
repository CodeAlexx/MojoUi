"""Smoke tests for node media preview controls.

Run: `pixi run test-node-media-preview`
"""

from mojoui.core.context import Context
from mojoui.core.types import Vec2, Rect, Color
from mojoui.widgets.image import ImageOverlayBox
from mojoui.nodes.media_preview import (
    NodeMediaPreview,
    NodeImagePreviewAction,
    NODE_MEDIA_NONE,
    NODE_MEDIA_PREVIEW,
    NODE_MEDIA_PLAY,
    NODE_MEDIA_BOX,
    draw_node_media_preview,
    draw_node_image_preview_boxes,
    draw_node_video_preview,
)


def _fail(msg: String) raises:
    print("FAIL:", msg)
    raise Error(msg)


def test_node_media_preview_default() raises:
    var preview = NodeMediaPreview()
    if preview.texture_id != UInt32(0):
        _fail("default texture_id should be 0")
    if preview.is_video:
        _fail("default preview should not be a video")
    if preview.title != String(""):
        _fail("default title should be empty")
    print("PASS: test_node_media_preview_default")


def test_card_press_returns_preview() raises:
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(500.0, 320.0), Vec2(10.0, 100.0), True, False
    )
    var preview = NodeMediaPreview(
        UInt32(0),
        0,
        0,
        String("Clip"),
        String("caption"),
        String("/tmp/clip.mp4"),
        True,
    )
    var action = draw_node_media_preview(
        ctx,
        String("node_media"),
        Rect(0.0, 0.0, 180.0, 110.0),
        preview,
    )
    if action != NODE_MEDIA_PREVIEW:
        _fail("card body press should return NODE_MEDIA_PREVIEW")
    ctx.end_frame()
    print("PASS: test_card_press_returns_preview")


def test_video_play_press_returns_play() raises:
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(500.0, 320.0), Vec2(90.0, 40.0), True, False
    )
    var action = draw_node_video_preview(
        ctx,
        String("node_video"),
        Rect(0.0, 0.0, 180.0, 110.0),
        UInt32(0),
        String("Video"),
        String("clip.mp4"),
        String("/tmp/clip.mp4"),
        480,
        288,
    )
    if action != NODE_MEDIA_PLAY:
        _fail("play button press should return NODE_MEDIA_PLAY")
    ctx.end_frame()
    print("PASS: test_video_play_press_returns_play")


def test_no_interaction_returns_none() raises:
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(500.0, 320.0), Vec2(300.0, 300.0), False, False
    )
    var preview = NodeMediaPreview(
        UInt32(0),
        0,
        0,
        String("Clip"),
        String("caption"),
        String("/tmp/clip.mp4"),
        True,
    )
    var action = draw_node_media_preview(
        ctx,
        String("node_media_idle"),
        Rect(0.0, 0.0, 180.0, 110.0),
        preview,
    )
    if action != NODE_MEDIA_NONE:
        _fail("idle preview should return NODE_MEDIA_NONE")
    ctx.end_frame()
    print("PASS: test_no_interaction_returns_none")


def test_image_box_press_returns_box_id() raises:
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(500.0, 320.0), Vec2(60.0, 25.0), True, False
    )
    var preview = NodeMediaPreview(
        UInt32(7),
        100,
        100,
        String("Image"),
        String("858 x 1285"),
        String("/tmp/image.webp"),
        False,
    )
    var boxes = List[ImageOverlayBox]()
    boxes.append(
        ImageOverlayBox(
            Int64(11),
            Rect(10.0, 10.0, 20.0, 20.0),
            String("01"),
            String("subject"),
            Color(80, 180, 255, 220),
        )
    )
    var action = draw_node_image_preview_boxes(
        ctx,
        String("node_image_boxes"),
        Rect(0.0, 0.0, 180.0, 140.0),
        preview,
        boxes,
    )
    if action.action != NODE_MEDIA_BOX:
        _fail("press inside image box should return NODE_MEDIA_BOX")
    if action.box_id != Int64(11):
        _fail("box action should report clicked box id")
    if action.fitted_rect.w <= 0.0 or action.fitted_rect.h <= 0.0:
        _fail("image node preview should return fitted rect")
    ctx.end_frame()
    print("PASS: test_image_box_press_returns_box_id")


def test_image_press_outside_box_returns_preview() raises:
    var ctx = Context()
    ctx.begin_frame_no_input(
        Vec2(500.0, 320.0), Vec2(130.0, 30.0), True, False
    )
    var preview = NodeMediaPreview(
        UInt32(7),
        100,
        100,
        String("Image"),
        String("858 x 1285"),
        String("/tmp/image.webp"),
        False,
    )
    var boxes = List[ImageOverlayBox]()
    boxes.append(
        ImageOverlayBox(
            Int64(11),
            Rect(10.0, 10.0, 20.0, 20.0),
            String("01"),
            String("subject"),
            Color(80, 180, 255, 220),
        )
    )
    var action = draw_node_image_preview_boxes(
        ctx,
        String("node_image_preview"),
        Rect(0.0, 0.0, 180.0, 140.0),
        preview,
        boxes,
    )
    if action.action != NODE_MEDIA_PREVIEW:
        _fail("press inside image preview but outside boxes should open preview")
    if action.box_id != Int64(-1):
        _fail("preview action should not report a box id")
    ctx.end_frame()
    print("PASS: test_image_press_outside_box_returns_preview")


def main() raises:
    test_node_media_preview_default()
    test_card_press_returns_preview()
    test_video_play_press_returns_play()
    test_no_interaction_returns_none()
    test_image_box_press_returns_box_id()
    test_image_press_outside_box_returns_preview()
    print("PASS: all node media preview smoke tests")
