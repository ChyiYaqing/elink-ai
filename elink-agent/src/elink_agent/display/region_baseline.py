"""Isolated hardware baseline for Waveshare 5.83 V2 region refreshes.

This module is intentionally not used by AgentService. Run it only while the
service is stopped, then restore a known full frame before resuming the agent.
"""
from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .waveshare_5in83_v2 import Waveshare583V2Display


@dataclass(frozen=True, slots=True)
class Region:
    """A byte-aligned, right/bottom-exclusive display region."""

    left: int
    top: int
    right: int
    bottom: int

    @property
    def width(self) -> int:
        return self.right - self.left

    @property
    def height(self) -> int:
        return self.bottom - self.top

    @property
    def payload_size(self) -> int:
        return self.width * self.height // 8


def align_region(box: tuple[int, int, int, int], *, width: int = 648,
                 height: int = 480) -> Region:
    left, top, right, bottom = box
    if left < 0 or top < 0 or right > width or bottom > height:
        raise ValueError("region is outside the display")
    if left >= right or top >= bottom:
        raise ValueError("region must have positive area")
    left = left // 8 * 8
    right = min(width, (right + 7) // 8 * 8)
    if left % 8 or right % 8:
        raise ValueError("display width must permit byte-aligned regions")
    return Region(left, top, right, bottom)


def pack_region(image: Image.Image, region: Region) -> bytes:
    if image.size != (648, 480):
        raise ValueError(f"expected 648x480, got {image.size}")
    if region.left % 8 or region.right % 8:
        raise ValueError("region x coordinates must be byte-aligned")
    crop = image.convert("1", dither=Image.Dither.NONE).crop(
        (region.left, region.top, region.right, region.bottom)
    )
    packed = crop.tobytes()
    if len(packed) != region.payload_size:
        raise ValueError("unexpected region payload size")
    return packed


def display_region(display: Waveshare583V2Display, image: Image.Image,
                   region: Region) -> int:
    """Send one region with the controller's partial-window command sequence."""
    packed = pack_region(image, region)
    with display._lock:
        try:
            display._open()
            display._init_partial()
            display._command(0x50)
            display._data(0xA9)
            display._data(0x07)
            display._command(0x91)
            display._command(0x90)
            x_end = region.right - 1
            y_end = region.bottom - 1
            for value in (
                region.left >> 8,
                region.left & 0xFF,
                x_end >> 8,
                x_end & 0xFF,
                region.top >> 8,
                region.top & 0xFF,
                y_end >> 8,
                y_end & 0xFF,
                0x01,
            ):
                display._data(value)
            display._command(0x13)
            display._data_block(packed)
            display._turn_on()
            display._command(0x92)
            display._sleep()
        finally:
            display._close_bus()
    return len(packed)


def render_frame(iteration: int) -> tuple[Image.Image, Region]:
    image = Image.new("1", (648, 480), 255)
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()
    draw.rectangle((0, 0, 647, 479), outline=0, width=2)
    draw.text((24, 20), "ELINK REGION REFRESH BASELINE", fill=0, font=font)
    draw.text((24, 42), "Only the center box should change during region updates.",
              fill=0, font=font)
    for x, y, label in ((24, 88, "TL"), (544, 88, "TR"),
                        (24, 388, "BL"), (544, 388, "BR")):
        draw.rectangle((x, y, x + 72, y + 48), outline=0, width=2)
        draw.text((x + 26, y + 19), label, fill=0, font=font)
    region = align_region((192, 168, 456, 312))
    fill = 0 if iteration % 2 else 255
    ink = 255 if fill == 0 else 0
    draw.rectangle((region.left, region.top, region.right - 1, region.bottom - 1),
                   fill=fill, outline=ink, width=3)
    draw.text((region.left + 24, region.top + 56),
              f"REGION UPDATE {iteration:03d}", fill=ink, font=font)
    return image, region


def _record(kind: str, started: float, *, payload_bytes: int,
            region: Region | None = None) -> None:
    value: dict[str, object] = {
        "kind": kind,
        "elapsed_s": round(time.monotonic() - started, 3),
        "payload_bytes": payload_bytes,
    }
    if region:
        value["region"] = [region.left, region.top, region.right, region.bottom]
    print(json.dumps(value), flush=True)


def run(*, iterations: int, interval_s: float, restore: Path | None) -> None:
    if iterations < 1:
        raise ValueError("iterations must be at least one")
    display = Waveshare583V2Display()
    try:
        frame, _ = render_frame(0)
        started = time.monotonic()
        display.show(frame, kind="full")
        _record("full-baseline", started, payload_bytes=648 * 480 // 8 * 2)
        for iteration in range(1, iterations + 1):
            if interval_s:
                time.sleep(interval_s)
            frame, region = render_frame(iteration)
            started = time.monotonic()
            payload_size = display_region(display, frame, region)
            _record("region", started, payload_bytes=payload_size, region=region)
        if restore:
            with Image.open(restore) as source:
                restored = source.convert("1", dither=Image.Dither.NONE)
            started = time.monotonic()
            display.show(restored, kind="full")
            _record("full-restore", started, payload_bytes=648 * 480 // 8 * 2)
    finally:
        display.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Waveshare 5.83 V2 region-refresh baseline")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--interval-s", type=float, default=1.0)
    parser.add_argument("--restore", type=Path)
    parser.add_argument("--confirm-hardware-refresh", action="store_true")
    args = parser.parse_args()
    if not args.confirm_hardware_refresh:
        parser.error("--confirm-hardware-refresh is required")
    run(iterations=args.iterations, interval_s=max(0.0, args.interval_s), restore=args.restore)


if __name__ == "__main__":
    main()
