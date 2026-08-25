"""Minimal Waveshare 5.83 inch V2 adapter.

The command sequence follows Waveshare's public 5.83 V2 reference driver and
the GPL-3.0 InkyPi integration. Keep this module isolated so another panel can
be added without changing the dashboard service.
"""
from __future__ import annotations

import time
from threading import Lock

from PIL import Image

from .base import Display
from .frame_diff import Rect


class Waveshare583V2Display(Display):
    RST_PIN = 17
    DC_PIN = 25
    BUSY_PIN = 24
    PWR_PIN = 18

    def __init__(self, *, busy_timeout_s: float = 60.0, keep_awake_s: float = 0.0):
        """`keep_awake_s` 是两次刷新之间保持面板初始化状态的最长时间。

        默认 0，即每次刷新后立刻 deep sleep 并断电——Waveshare 要求不刷新时让屏
        进入休眠，长时间停在上电状态会让面板持续处于高压，可能造成永久损伤。所以
        这个窗口只用来覆盖「下一拍马上就来」的情形：跳过复位（402ms）、上电等待
        和收尾休眠（200ms+BUSY），一次局部刷新从约 1.25 秒降到约 0.55 秒。窗口一
        过，主循环的 idle() 会立即把它放回休眠。

        窗口从唤醒那一刻起算，不随刷新续期——否则密集刷新会让它永不休眠，正好落进
        上面那条禁忌里。所以连续上电时间的上界就是这个值（加上主循环一拍的粒度）。
        """
        try:
            import gpiozero
            import spidev
        except ImportError as error:
            raise RuntimeError("install elink-ai[hardware] to use the Waveshare display") from error
        self._spi = spidev.SpiDev()
        self._rst = gpiozero.LED(self.RST_PIN)
        self._dc = gpiozero.LED(self.DC_PIN)
        self._power = gpiozero.LED(self.PWR_PIN)
        self._busy = gpiozero.Button(self.BUSY_PIN, pull_up=False)
        self._busy_timeout_s = busy_timeout_s
        self.last_busy_wait_s = 0.0
        self._lock = Lock()
        self._opened = False
        self._keep_awake_s = max(0.0, keep_awake_s)
        # 面板当前保持着哪一种初始化（partial / full），None 表示已休眠断电
        self._awake_mode: str | None = None
        self._awake_until = 0.0

    def show(self, image: Image.Image, *, kind: str = "full",
             regions: tuple[Rect, ...] = ()) -> None:
        if image.size != (self.width, self.height):
            raise ValueError(f"expected {self.width}x{self.height}, got {image.size}")
        if kind == "region" and not regions:
            raise ValueError("region refresh requires at least one region")
        packed = None
        if kind != "region":
            packed = image.convert("1", dither=Image.Dither.NONE).tobytes()
            if len(packed) != self.width * self.height // 8:
                raise ValueError("unexpected packed image size")
        mode = "full" if kind == "full" else "partial"
        with self._lock:
            self.last_busy_wait_s = 0.0
            try:
                self._open()
                # 已经保持着同一种初始化就直接下发数据，省掉复位和上电等待
                if self._awake_mode != mode:
                    self._init_full() if mode == "full" else self._init_partial()
                    self._awake_mode = mode
                    # 从唤醒那一刻起算，之后的刷新不续期：连续上电时间因此有硬
                    # 上界。续期的写法在密集刷新下等于永不休眠，正是要避免的。
                    self._awake_until = time.monotonic() + self._keep_awake_s
                if kind == "region":
                    self._display_regions(image, regions)
                elif kind in {"partial", "fast-full"}:
                    self._display_partial(packed)
                elif kind == "full":
                    self._display_full(packed)
                else:
                    raise ValueError(f"unsupported refresh kind: {kind}")
            except BaseException:
                # 出了任何问题都别把面板丢在上电状态上
                self._park(graceful=False)
                raise
            if self._keep_awake_s <= 0:
                self._park()

    def _open(self) -> None:
        self._power.on()
        if not self._opened:
            self._spi.open(0, 0)
            self._spi.max_speed_hz = 4_000_000
            self._spi.mode = 0
            self._opened = True

    def _reset(self) -> None:
        self._rst.on(); time.sleep(0.2)
        self._rst.off(); time.sleep(0.002)
        self._rst.on(); time.sleep(0.2)

    def _command(self, value: int) -> None:
        self._dc.off()
        self._spi.writebytes([value])

    def _data(self, value: int) -> None:
        self._dc.on()
        self._spi.writebytes([value])

    def _data_block(self, value: bytes) -> None:
        self._dc.on()
        self._spi.writebytes2(value)

    def _wait_busy(self) -> None:
        started = time.monotonic()
        deadline = time.monotonic() + self._busy_timeout_s
        try:
            while self._busy.value == 0:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"e-paper BUSY remained low for {self._busy_timeout_s}s")
                time.sleep(0.01)
        finally:
            self.last_busy_wait_s += time.monotonic() - started

    def _init_full(self) -> None:
        self._reset()
        self._command(0x00); self._data(0x1F)
        self._command(0x04); time.sleep(0.3); self._wait_busy()
        self._command(0x50); self._data(0x21); self._data(0x07)

    def _init_partial(self) -> None:
        self._reset()
        self._command(0x00); self._data(0x1F)
        self._command(0xE0); self._data(0x02)
        self._command(0xE5); self._data(0x6E)
        self._command(0x04); time.sleep(0.1); self._wait_busy()

    def _turn_on(self) -> None:
        self._command(0x12); time.sleep(0.1); self._wait_busy()

    def _display_full(self, packed: bytes) -> None:
        self._command(0x10); self._data_block(packed)
        self._command(0x13); self._data_block(packed)
        self._turn_on()

    def _display_partial(self, packed: bytes) -> None:
        self._command(0x50); self._data(0xA9); self._data(0x07)
        self._command(0x91); self._command(0x90)
        for value in (0, 0, (self.width - 1) >> 8, (self.width - 1) & 0xFF,
                      0, 0, (self.height - 1) >> 8, (self.height - 1) & 0xFF, 0x01):
            self._data(value)
        self._command(0x13); self._data_block(packed)
        self._turn_on(); self._command(0x92)

    def _display_regions(self, image: Image.Image, regions: tuple[Rect, ...]) -> None:
        """每个窗口一个完整的分区刷新周期。

        0x90 是一组会被覆写的寄存器：把多个窗口攒起来只发一次 0x12，面板就只驱动
        最后设置的那一个，其余窗口的数据留在 RAM 里，要等下一次整屏刷新才现形。
        真机上的表现是监控页右上角的秒数永远不动——区域按 (top, left) 排序，它永远
        是第 0 个，永远轮不到最后。Waveshare 的 5.83 V2 参考实现同样是一窗口一周期。

        代价是每个窗口各付一次 BUSY，所以窗口数量本身就是成本，帧差器的区域预算要
        按这个来定，而不是按面积。
        """
        for region in regions:
            packed = self._pack_region(image, region)
            self._command(0x50); self._data(0xA9); self._data(0x07)
            self._command(0x91)
            self._command(0x90)
            x_end = region.right - 1
            y_end = region.bottom - 1
            for value in (
                region.left >> 8, region.left & 0xFF,
                x_end >> 8, x_end & 0xFF,
                region.top >> 8, region.top & 0xFF,
                y_end >> 8, y_end & 0xFF,
                0x01,
            ):
                self._data(value)
            self._command(0x13)
            self._data_block(packed)
            self._turn_on()
            self._command(0x92)

    def _pack_region(self, image: Image.Image, region: Rect) -> bytes:
        if (region.left < 0 or region.top < 0 or region.right > self.width
                or region.bottom > self.height or region.left >= region.right
                or region.top >= region.bottom):
            raise ValueError("region is outside the display or empty")
        if region.left % 8 or region.right % 8:
            raise ValueError("region x coordinates must be byte-aligned")
        packed = image.convert("1", dither=Image.Dither.NONE).crop((
            region.left, region.top, region.right, region.bottom,
        )).tobytes()
        expected = region.width * region.height // 8
        if len(packed) != expected:
            raise ValueError("unexpected region payload size")
        return packed

    def idle(self) -> None:
        """保活窗口到期就休眠断电。主循环每一拍都会调用。"""
        with self._lock:
            if self._awake_mode is not None and time.monotonic() >= self._awake_until:
                self._park()

    def _park(self, *, graceful: bool = True) -> None:
        """面板长期该待的状态：deep sleep + 断电。

        出错路径上 graceful=False：面板可能已经卡住，再发一次休眠命令只会在
        BUSY 上又等一个超时，还会用第二个异常盖住真正的失败原因。断电本身由
        _close_bus() 完成，那才是安全上必须做到的一步。
        """
        try:
            if graceful and self._awake_mode is not None:
                self._sleep()
        finally:
            self._awake_mode = None
            self._awake_until = 0.0
            self._close_bus()

    def _sleep(self) -> None:
        self._command(0x50); self._data(0xF7)
        self._command(0x02); self._wait_busy()
        self._command(0x07); self._data(0xA5)
        time.sleep(0.2)

    def _close_bus(self) -> None:
        if self._opened:
            self._spi.close()
            self._opened = False
        self._rst.off(); self._dc.off(); self._power.off()

    def close(self) -> None:
        with self._lock:
            self._park()
        self._rst.close(); self._dc.close(); self._power.close(); self._busy.close()
