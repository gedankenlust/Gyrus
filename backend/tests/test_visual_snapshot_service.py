from PIL import Image

from services.visual_snapshot_service import _dominant_colors


def test_dominant_colors_prioritize_design_colors_over_page_chrome(tmp_path):
    image_path = tmp_path / "palette.png"
    image = Image.new("RGB", (100, 100), "white")

    for x in range(20):
        for y in range(100):
            image.putpixel((x, y), (255, 48, 96))
    image.save(image_path)

    colors = _dominant_colors(image_path)

    assert colors[0] == "#ff3060"
    assert colors.count("#f0f0f0") <= 1
