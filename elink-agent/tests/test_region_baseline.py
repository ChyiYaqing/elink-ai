import sys
import types

from PIL import Image
import pytest

from elink_agent.display.region_baseline import (
    Region,
    align_region,
    display_region,
    pack_region,
)
from elink_agent.display.waveshare_5in83_v2 import Waveshare583V2Display


class FakePin:
    def __init__(self, *_args, **_kwargs):
        self.value = 1

    def on(self): self.value = 1
    def off(self): self.value = 0
    def close(self): pass


class FakeSPI:
    def __init__(self):
        self.values = []
        self.blocks = []

    def open(self, bus, device): self.opened = (bus, device)
    def close(self): self.opened = None
    def writebytes(self, values): self.values.extend(values)
    def writebytes2(self, values): self.blocks.append(bytes(values))


def test_align_region_expands_x_to_byte_boundaries():
    assert align_region((9, 10, 18, 20)) == Region(8, 10, 24, 20)


def test_align_region_rejects_invalid_or_external_boxes():
    with pytest.raises(ValueError):
        align_region((-1, 0, 8, 8))
    with pytest.raises(ValueError):
        align_region((8, 8, 8, 9))


def test_pack_region_sends_only_the_aligned_crop():
    image = Image.new("1", (648, 480), 255)
    for y in range(2, 6):
        for x in range(8, 24):
            image.putpixel((x, y), 0)
    region = Region(8, 2, 24, 6)
    packed = pack_region(image, region)
    assert packed == b"\x00\x00" * 4
    assert len(packed) == region.payload_size == 8


def test_display_region_sends_partial_window_and_only_region_payload():
    spi = FakeSPI()
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = types.SimpleNamespace(SpiDev=lambda: spi)
    sys.modules["gpiozero"] = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.1)
        display._busy.value = 1
        image = Image.new("1", (648, 480), 255)
        region = Region(8, 2, 24, 6)
        assert display_region(display, image, region) == 8
        assert spi.blocks == [b"\xff\xff" * 4]
        window = [0x91, 0x90, 0, 8, 0, 23, 0, 2, 0, 5, 0x01, 0x13]
        assert any(spi.values[index:index + len(window)] == window
                   for index in range(len(spi.values) - len(window) + 1))
        display.close()
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio
