import sys
import types

from PIL import Image
import pytest

from elink_agent.display.frame_diff import Rect
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


def test_region_refresh_transfers_only_each_window_payload():
    spi = FakeSPI()
    fake_spidev = types.SimpleNamespace(SpiDev=lambda: spi)
    fake_gpiozero = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = fake_spidev
    sys.modules["gpiozero"] = fake_gpiozero
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.1)
        display._busy.value = 1
        image = Image.new("1", (648, 480), 255)
        regions = (Rect(8, 2, 24, 6), Rect(32, 10, 40, 12))
        display.show(image, kind="region", regions=regions)
        assert [len(block) for block in spi.blocks] == [8, 2]
        assert spi.commands.count(0x90) == 2
        assert spi.commands.count(0x13) == 2
        assert spi.commands.count(0x12) == 1
        display.close()
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio


def test_region_refresh_rejects_unaligned_x_coordinates():
    spi = FakeSPI()
    fake_spidev = types.SimpleNamespace(SpiDev=lambda: spi)
    fake_gpiozero = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = fake_spidev
    sys.modules["gpiozero"] = fake_gpiozero
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.1)
        display._busy.value = 1
        image = Image.new("1", (648, 480), 255)
        try:
            display.show(image, kind="region", regions=(Rect(9, 2, 24, 6),))
            raise AssertionError("unaligned region was accepted")
        except ValueError as error:
            assert "byte-aligned" in str(error)
        display.close()
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio


def test_busy_timeout_closes_spi_and_powers_off():
    spi = FakeSPI()
    fake_spidev = types.SimpleNamespace(SpiDev=lambda: spi)
    fake_gpiozero = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = fake_spidev
    sys.modules["gpiozero"] = fake_gpiozero
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.01)
        display._busy.value = 0
        image = Image.new("1", (648, 480), 255)
        with pytest.raises(TimeoutError, match="BUSY remained low"):
            display.show(image, kind="full")
        assert display.last_busy_wait_s >= 0.01
        assert not display._opened
        assert spi.opened is None
        assert display._power.value == 0
        display.close()
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio
