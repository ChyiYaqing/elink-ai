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

    def __init__(self, *, busy_timeout_s: float = 60.0):
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
        self._lock = Lock()
        self._opened = False

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
        with self._lock:
            try:
                self._open()
                if kind == "region":
                    self._init_partial()
                    self._display_regions(image, regions)
                elif kind in {"partial", "fast-full"}:
                    self._init_partial()
                    self._display_partial(packed)
                elif kind == "full":
                    self._init_full()
                    self._display_full(packed)
                else:
                    raise ValueError(f"unsupported refresh kind: {kind}")
                self._sleep()
            finally:
                self._close_bus()

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
        deadline = time.monotonic() + self._busy_timeout_s
        while self._busy.value == 0:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"e-paper BUSY remained low for {self._busy_timeout_s}s")
            time.sleep(0.01)

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
        self._command(0x50); self._data(0xA9); self._data(0x07)
        self._command(0x91)
        for region in regions:
            packed = self._pack_region(image, region)
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
        self._turn_on(); self._command(0x92)

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
        self._close_bus()
        self._rst.close(); self._dc.close(); self._power.close(); self._busy.close()
