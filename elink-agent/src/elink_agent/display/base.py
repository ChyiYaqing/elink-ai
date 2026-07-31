from __future__ import annotations

from abc import ABC, abstractmethod
from PIL import Image

from .frame_diff import Rect


class Display(ABC):
    width = 648
    height = 480

    @abstractmethod
    def show(self, image: Image.Image, *, kind: str = "full",
             regions: tuple[Rect, ...] = ()) -> None:
        """Show a full frame or byte-aligned regions from a 648x480 image."""

    def close(self) -> None:
        pass
