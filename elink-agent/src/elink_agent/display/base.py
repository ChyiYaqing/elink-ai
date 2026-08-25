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

    def idle(self) -> None:
        """没有刷新任务时由主循环调用，让驱动收拾自己的电源状态。

        默认什么也不做：只有会在两次刷新之间保持面板上电的驱动才需要它。
        """

    def close(self) -> None:
        pass
