from __future__ import annotations

from pathlib import Path
from PIL import Image

from .base import Display


class MockDisplay(Display):
    def __init__(self, output_path: Path):
        self.output_path = output_path
        self.calls: list[str] = []

    def show(self, image: Image.Image, *, kind: str = "full") -> None:
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.output_path.with_suffix(self.output_path.suffix + ".tmp")
        image.convert("1", dither=Image.Dither.NONE).save(temporary, format="PNG")
        temporary.replace(self.output_path)
        self.calls.append(kind)
