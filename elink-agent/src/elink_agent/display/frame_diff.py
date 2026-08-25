from __future__ import annotations

from collections import deque
from dataclasses import dataclass

from PIL import Image, ImageChops


@dataclass(frozen=True, slots=True)
class Rect:
    """A right/bottom-exclusive rectangle."""

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
    def area(self) -> int:
        return self.width * self.height


@dataclass(frozen=True, slots=True)
class RefreshPlan:
    kind: str
    regions: tuple[Rect, ...] = ()
    planned_area: int = 0
    reason: str = "unchanged"


class FrameDiffer:
    # 碎片多到这个数量就不再逐对合并：整页都在变，挑也没用
    MERGE_LIMIT = 32

    # 窗口数的硬上限。再多就不如整屏重画：一个窗口约 350ms BUSY，整屏 4.5s。
    max_windows = 10

    # 窗口数就是成本：面板的分区窗口寄存器一次只认一个，所以每个窗口都要自己走
    # 一遍刷新周期，各付一次约 350ms 的 BUSY。面积反而几乎免费——4MHz 下 3KB 只要
    # 6ms。所以预算的取法是「在不越过面积阈值的前提下窗口尽量少」：真机上监控页
    # 一次 tick 给 4 个窗口是 15.9% 面积、约 1.4 秒，给 8 个是 7.7% 面积但要 2.45
    # 秒，比整页刷新的 4.5 秒省，却已经超过了监控页自己的节拍。

    def __init__(self, *, width: int = 648, height: int = 480,
                 tile_size: int = 8, max_regions: int = 4,
                 fast_full_threshold: float = 0.35):
        if width <= 0 or height <= 0 or width % 8:
            raise ValueError("display width must be positive and byte-aligned")
        if tile_size <= 0 or max_regions <= 0:
            raise ValueError("tile_size and max_regions must be positive")
        if not 0 < fast_full_threshold <= 1:
            raise ValueError("fast_full_threshold must be in (0, 1]")
        self.width = width
        self.height = height
        self.tile_size = tile_size
        self.max_regions = max_regions
        self.fast_full_threshold = fast_full_threshold

    def plan(self, previous: Image.Image | None, current: Image.Image) -> RefreshPlan:
        current = self._normalize(current)
        screen_area = self.width * self.height
        if previous is None:
            return RefreshPlan("full", planned_area=screen_area, reason="missing-baseline")
        try:
            previous = self._normalize(previous)
        except ValueError:
            return RefreshPlan("full", planned_area=screen_area, reason="invalid-baseline")

        difference = ImageChops.difference(previous.convert("L"), current.convert("L"))
        if difference.getbbox() is None:
            return RefreshPlan("none")

        clusters = self._regions(difference)
        regions = self._merge_to_budget(clusters, self.max_regions)
        planned_area = sum(region.area for region in regions)
        if planned_area / screen_area > self.fast_full_threshold:
            # 合并得太狠会把面积撑过阈值。与其整屏重画，不如多花几个窗口：一个
            # 窗口约 350ms BUSY，整屏重画是 4.5s，所以在 max_windows 之前多开窗口
            # 总是划算的，而且不会在屏上留下一次整页重绘。
            for budget in range(self.max_regions + 1, self.max_windows + 1):
                candidate = self._merge_to_budget(clusters, budget)
                candidate_area = sum(region.area for region in candidate)
                if candidate_area / screen_area <= self.fast_full_threshold:
                    return RefreshPlan("region", candidate, candidate_area, "pixel-change")
                if len(candidate) < budget:
                    break  # 已经并无可并，再放宽预算也没有新解
            return RefreshPlan("fast-full", planned_area=screen_area,
                               reason="region-area-threshold")
        return RefreshPlan("region", regions, planned_area, "pixel-change")

    def _normalize(self, image: Image.Image) -> Image.Image:
        if image.size != (self.width, self.height):
            raise ValueError(f"expected {self.width}x{self.height}, got {image.size}")
        return image.convert("1", dither=Image.Dither.NONE)

    def _regions(self, difference: Image.Image) -> tuple[Rect, ...]:
        tile = self.tile_size
        changed: set[tuple[int, int]] = set()
        bounds = difference.getbbox()
        if bounds is None:
            return ()
        left, top, right, bottom = bounds
        for y in range(top // tile, (bottom + tile - 1) // tile):
            y0 = y * tile
            y1 = min(self.height, y0 + tile)
            for x in range(left // tile, (right + tile - 1) // tile):
                x0 = x * tile
                x1 = min(self.width, x0 + tile)
                if difference.crop((x0, y0, x1, y1)).getbbox() is not None:
                    changed.add((x, y))

        regions: list[Rect] = []
        while changed:
            start = changed.pop()
            queue = deque([start])
            min_x = max_x = start[0]
            min_y = max_y = start[1]
            while queue:
                x, y = queue.popleft()
                min_x, max_x = min(min_x, x), max(max_x, x)
                min_y, max_y = min(min_y, y), max(max_y, y)
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        neighbour = (x + dx, y + dy)
                        if neighbour in changed:
                            changed.remove(neighbour)
                            queue.append(neighbour)
            tile_box = (
                min_x * tile,
                min_y * tile,
                min(self.width, (max_x + 1) * tile),
                min(self.height, (max_y + 1) * tile),
            )
            exact = difference.crop(tile_box).getbbox()
            if exact is None:
                continue
            exact_left, exact_top, exact_right, exact_bottom = exact
            pixel_left = tile_box[0] + exact_left
            pixel_right = tile_box[0] + exact_right
            regions.append(Rect(
                pixel_left // 8 * 8,
                tile_box[1] + exact_top,
                min(self.width, (pixel_right + 7) // 8 * 8),
                tile_box[1] + exact_bottom,
            ))
        return tuple(sorted(regions, key=lambda value: (value.top, value.left)))

    def _merge_to_budget(self, regions: tuple[Rect, ...], budget: int) -> tuple[Rect, ...]:
        """把区域数收进预算，每次合并「多出来的面积最小」的一对。

        原来的做法是一旦超预算就把所有区域并成一个外接矩形，那等于让相距最远的
        两处改动决定整块面积：监控页上右上角的时钟改了 78 像素、左侧 CPU 卡改了
        8102 像素，并成一块就是半屏，于是 2.63% 的真实变化被判成整屏刷新。

        碎片多到 MERGE_LIMIT 以上时不值得再挑：那说明整页都在变，并成一块交给
        面积阈值判定即可，也免得在树莓派上跑一个 O(n³) 的合并。
        """
        if len(regions) <= budget:
            return regions
        if len(regions) > self.MERGE_LIMIT:
            return (self._union(regions),)
        merged = list(regions)
        while len(merged) > budget:
            best_cost = best_pair = None
            for first in range(len(merged)):
                for second in range(first + 1, len(merged)):
                    union = self._union((merged[first], merged[second]))
                    cost = union.area - merged[first].area - merged[second].area
                    if best_cost is None or cost < best_cost:
                        best_cost, best_pair = cost, (first, second, union)
            first, second, union = best_pair
            del merged[second]
            merged[first] = union
        return tuple(sorted(merged, key=lambda value: (value.top, value.left)))

    @staticmethod
    def _union(regions: tuple[Rect, ...]) -> Rect:
        return Rect(
            min(region.left for region in regions),
            min(region.top for region in regions),
            max(region.right for region in regions),
            max(region.bottom for region in regions),
        )
