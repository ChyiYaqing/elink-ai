import sys
import time
import types
from contextlib import contextmanager

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


@contextmanager
def _fake_panel(**kwargs):
    spi = FakeSPI()
    old_spi, old_gpio = sys.modules.get("spidev"), sys.modules.get("gpiozero")
    sys.modules["spidev"] = types.SimpleNamespace(SpiDev=lambda: spi)
    sys.modules["gpiozero"] = types.SimpleNamespace(LED=FakePin, Button=FakePin)
    try:
        display = Waveshare583V2Display(busy_timeout_s=0.1, **kwargs)
        display._busy.value = 1
        yield display, spi
    finally:
        if old_spi is None: sys.modules.pop("spidev", None)
        else: sys.modules["spidev"] = old_spi
        if old_gpio is None: sys.modules.pop("gpiozero", None)
        else: sys.modules["gpiozero"] = old_gpio


def _spy(display, name):
    """记录某个驱动步骤被走了几次。

    不数 SPI 字节：FakeSPI 把命令和数据记在同一个列表里，0x04、0x07 这些值在
    数据里也会出现，数出来的次数是假的。
    """
    calls = []
    original = getattr(display, name)

    def spy(*args, **kwargs):
        calls.append(1)
        return original(*args, **kwargs)

    setattr(display, name, spy)
    return calls


REGION = (Rect(8, 2, 24, 6),)
FRAME = Image.new("1", (648, 480), 255)


def test_by_default_every_refresh_ends_asleep_and_powered_off():
    """面板长期该待的状态。Waveshare 要求不刷新时休眠，长期上电会停在高压。"""
    with _fake_panel() as (display, spi):
        slept = _spy(display, "_sleep")
        display.show(FRAME, kind="region", regions=REGION)
        assert display._awake_mode is None
        assert display._power.value == 0
        assert spi.opened is None
        assert len(slept) == 1
        display.close()


def test_keep_awake_skips_the_reset_sequence_on_the_next_refresh():
    """保活窗口内的下一次局刷跳过复位与休眠——真机上这是 1.25s 与 0.55s 的差别。"""
    with _fake_panel(keep_awake_s=30) as (display, _):
        init = _spy(display, "_init_partial")
        slept = _spy(display, "_sleep")
        turned_on = _spy(display, "_turn_on")
        display.show(FRAME, kind="region", regions=REGION)
        assert display._awake_mode == "partial"
        assert display._power.value == 1, "保活期间面板保持上电"
        display.show(FRAME, kind="region", regions=REGION)
        assert len(init) == 1, "第二次刷新不该再走一遍初始化"
        assert len(turned_on) == 2, "但两次都要真的刷新面板"
        assert slept == [], "保活期间不该休眠"
        display.close()


def test_a_full_refresh_reinitialises_even_while_awake():
    """整屏和局刷用的是不同的初始化，保活不能让它们混用。"""
    with _fake_panel(keep_awake_s=30) as (display, _):
        init_full = _spy(display, "_init_full")
        display.show(FRAME, kind="region", regions=REGION)
        assert init_full == []
        display.show(FRAME, kind="full")
        assert display._awake_mode == "full"
        assert len(init_full) == 1
        display.close()


def test_idle_parks_the_panel_once_the_window_expires():
    with _fake_panel(keep_awake_s=30) as (display, spi):
        slept = _spy(display, "_sleep")
        display.show(FRAME, kind="region", regions=REGION)
        display.idle()
        assert display._awake_mode == "partial", "窗口未到期不该休眠"
        display._awake_until = time.monotonic() - 0.001
        display.idle()
        assert display._awake_mode is None
        assert display._power.value == 0
        assert spi.opened is None
        assert len(slept) == 1
        display.close()


def test_the_awake_window_does_not_renew_with_each_refresh():
    """窗口从唤醒起算。若每次刷新都续期，密集刷新下面板就永远不会休眠——那正是
    Waveshare 禁止的长期上电状态，而密集刷新恰恰是启用保活的唯一场景。"""
    with _fake_panel(keep_awake_s=30) as (display, _):
        display.show(FRAME, kind="region", regions=REGION)
        deadline = display._awake_until
        display.show(FRAME, kind="region", regions=REGION)
        assert display._awake_until == deadline, "第二次刷新不该把休眠推后"
        display._awake_until = time.monotonic() - 0.001
        display.idle()
        assert display._awake_mode is None
        assert display._power.value == 0
        display.close()


def test_close_parks_a_panel_left_awake():
    with _fake_panel(keep_awake_s=30) as (display, _):
        display.show(FRAME, kind="region", regions=REGION)
        display.close()
        assert display._awake_mode is None
        assert display._power.value == 0


def test_a_failure_while_awake_cuts_power_without_a_second_busy_wait():
    """面板卡住时再发一次休眠只会再等一个超时，还会盖住真正的失败原因。"""
    with _fake_panel(keep_awake_s=30) as (display, spi):
        display.show(FRAME, kind="region", regions=REGION)
        slept = _spy(display, "_sleep")
        display._busy.value = 0
        with pytest.raises(TimeoutError, match="BUSY remained low"):
            display.show(FRAME, kind="region", regions=REGION)
        assert slept == []
        assert display._awake_mode is None
        assert display._power.value == 0
        assert spi.opened is None


def test_every_window_gets_its_own_refresh_cycle():
    """0x90 是会被覆写的寄存器：攒着多个窗口只发一次 0x12，面板只驱动最后一个。

    真机症状是监控页右上角的秒数永远不动——区域按 (top, left) 排序，时间戳永远是
    第 0 个，永远轮不到最后，只有整屏刷新才能让它现形。Waveshare 的 5.83 V2 参考
    实现也是一窗口一周期。
    """
    with _fake_panel() as (display, _):
        turned_on = _spy(display, "_turn_on")
        display.show(FRAME, kind="region",
                     regions=(Rect(8, 2, 24, 6), Rect(32, 10, 40, 12), Rect(64, 40, 80, 44)))
        assert len(turned_on) == 3, "每个窗口都要自己刷一次"
        display.close()


def test_a_single_window_still_costs_one_cycle():
    with _fake_panel() as (display, _):
        turned_on = _spy(display, "_turn_on")
        display.show(FRAME, kind="region", regions=REGION)
        assert len(turned_on) == 1
        display.close()
