import sys
import types

from PIL import Image

from elink_agent.display.waveshare_5in83_v2 import Waveshare583V2Display


class FakePin:
    def __init__(self, *_args, **_kwargs):
        self.value = 1
    def on(self): self.value = 1
    def off(self): self.value = 0
    def close(self): pass


class FakeSPI:
    def __init__(self):
        self.commands = []
        self.blocks = []
    def open(self, bus, device): self.opened = (bus, device)
    def close(self): self.opened = None
    def writebytes(self, value): self.commands.extend(value)
    def writebytes2(self, value): self.blocks.append(bytes(value))


def test_full_and_partial_transfer_exact_frame_size(monkeypatch=None):
    spi = FakeSPI()
    fake_spidev = types.SimpleNamespace(SpiDev=lambda: spi)
    fake_gpiozero = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = fake_spidev
    sys.modules["gpiozero"] = fake_gpiozero
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.1)
        # BUSY is an input and remains high in the fake regardless of power pin changes.
        display._busy.value = 1
        image = Image.new("1", (648, 480), 255)
        display.show(image, kind="full")
        display._busy.value = 1
        display.show(image, kind="partial")
        assert len(spi.blocks) == 3
        assert all(len(block) == 648 * 480 // 8 for block in spi.blocks)
        display.close()
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio
