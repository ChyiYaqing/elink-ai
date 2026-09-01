from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from . import __version__
from .models import ProviderStatus, RecentEvent, SessionSummary, StatusSnapshot

_CPU_CORES = os.cpu_count() or 1


class DashboardRenderer:
    width = 648
    height = 480

    # 组件框，固定坐标且顶层互不重叠。区域刷新的脏矩形由像素差得出，所以布局
    # 唯一的义务是让每个组件只在自己的框内绘制：任何随数据量变化的重排都会把
    # 一次小改动放大成整块刷新。
    HEADER_BOX = (18, 8, 630, 66)
    CLAUDE_BOX = (18, 74, 316, 458)
    CODEX_BOX = (332, 74, 630, 458)
    SINGLE_BOX = (18, 74, 630, 458)
    FOOTER_BOX = (18, 459, 630, 476)

    # 设备监控版面：左侧一张主角卡（CPU），右侧四条紧凑指标行，底部一条面板健康
    # 状态条。分组靠发丝线而不是卡片边框——边框是四条边连成的环，任何重绘都会把
    # 脏矩形撑成整张卡的外接矩形。所有框固定且互不重叠，分隔线画在框与框的缝里，
    # 因此它们永远不会进入任何一次区域刷新。
    MONITOR_HEADER_BOX = (18, 8, 630, 66)
    MONITOR_HERO_BOX = (18, 76, 316, 404)
    MONITOR_ROW_X = (332, 630)
    MONITOR_ROW_TOPS = (76, 158, 240, 322)
    MONITOR_ROW_HEIGHT = 78
    MONITOR_STRIP_BOX = (18, 414, 630, 470)
    MONITOR_SPARK_SLOTS = 30
    # 状态条右下角留给翻页点的宽度：地址行到此为止
    MONITOR_DOTS_GUTTER = 40
    # 状态条第二行（面板健康 + 地址）的基线。比原来高 4px，好给折行的地址腾出
    # 第三行，同时不动状态条的框和翻页点。
    MONITOR_STRIP_SUB_Y = 26
    MONITOR_ADDRESS_LINE_H = 15
    # 比这更窄的空档放不下一段「名字 地址」，与其挤成省略号不如整段折到下一行
    MONITOR_ADDRESS_MIN_WIDTH = 60
    MONITOR_ADDRESS_SEP = " · "
    MONITOR_SPARK_MIN_SCALE = 25.0

    _MODEL_ROWS = 4
    _MODEL_ROW_HEIGHT = 15
    _MODEL_FONT_SIZE = 11

    def __init__(self, font_path: str = ""):
        self.font_path = self._find_font(font_path)
        self._bold_font_path = self._bold_variant(self.font_path)
        # 字体按 (size, bold) 缓存。每次重新 truetype 都会丢掉 FreeType 的字形
        # 缓存，而一帧监控页要取二十多次字体，重复开销比真正的绘制还大。
        self._fonts: dict[tuple[int, bool], ImageFont.FreeTypeFont | ImageFont.ImageFont] = {}

    def render(self, snapshot: StatusSnapshot, *, stale: bool = False,
               mode: str = "dashboard", updated_at: datetime | None = None) -> Image.Image:
        image = Image.new("L", (self.width, self.height), 255)
        draw = ImageDraw.Draw(image)
        updated_at = updated_at or datetime.now().astimezone()
        self._header(draw, stale, updated_at)
        if mode in {"claude", "codex"}:
            provider = snapshot.claude if mode == "claude" else snapshot.codex
            self._provider_panel(
                draw, self.SINGLE_BOX, mode.capitalize(), provider,
                sessions=self._for_provider(snapshot.current_sessions, mode),
                events=self._for_provider(snapshot.recent_events, mode),
                updated_at=updated_at, large=True,
            )
        else:
            self._provider_panel(
                draw, self.CLAUDE_BOX, "Claude", snapshot.claude,
                sessions=self._for_provider(snapshot.current_sessions, "claude"),
                events=self._for_provider(snapshot.recent_events, "claude"),
                updated_at=updated_at,
            )
            self._provider_panel(
                draw, self.CODEX_BOX, "Codex", snapshot.codex,
                sessions=self._for_provider(snapshot.current_sessions, "codex"),
                events=self._for_provider(snapshot.recent_events, "codex"),
                updated_at=updated_at,
            )
        self._footer(draw)
        return image.convert("1", dither=Image.Dither.NONE)

    def component_boxes(self, mode: str = "dashboard") -> dict[str, tuple[int, int, int, int]]:
        """The layout contract: which pixels each component is allowed to touch.

        Right/bottom-exclusive, matching `Rect`, because the caller compares these
        against refresh regions. The drawing constants are PIL's closed corners.
        """
        if mode in {"claude", "codex"}:
            panels = {mode: self.SINGLE_BOX,
                      f"{mode}.badge": self._badge_box(self.SINGLE_BOX, large=True),
                      f"{mode}.session": self._activity_box(self.SINGLE_BOX, 2),
                      f"{mode}.event": self._activity_box(self.SINGLE_BOX, 3)}
        else:
            panels = {
                "claude": self.CLAUDE_BOX,
                "claude.badge": self._badge_box(self.CLAUDE_BOX, large=False),
                "claude.session": self._activity_box(self.CLAUDE_BOX, 2),
                "claude.event": self._activity_box(self.CLAUDE_BOX, 3),
                "codex": self.CODEX_BOX,
                "codex.badge": self._badge_box(self.CODEX_BOX, large=False),
                "codex.session": self._activity_box(self.CODEX_BOX, 2),
                "codex.event": self._activity_box(self.CODEX_BOX, 3),
            }
        boxes = {"header": self.HEADER_BOX, **panels, "footer": self.FOOTER_BOX}
        return {name: (box[0], box[1], box[2] + 1, box[3] + 1) for name, box in boxes.items()}

    def _header(self, draw: ImageDraw.ImageDraw, stale: bool, updated_at: datetime) -> None:
        draw.rounded_rectangle((18, 10, 102, 31), radius=6, fill=0)
        draw.text((28, 12), "ELINK AI", font=self._font(12, bold=True), fill=255)
        draw.text((18, 31), "MISSION CONTROL", font=self._font(27, bold=True), fill=0)
        state = "STALE / MAC OFFLINE" if stale else "LIVE"
        state_font = self._font(14, bold=True)
        state_width = draw.textbbox((0, 0), state, font=state_font)[2]
        badge = (630 - state_width - 20, 10, 630, 33)
        draw.rounded_rectangle(badge, radius=11, fill=0)
        draw.text((badge[0] + 10, 13), state, font=state_font, fill=255)
        stamp = updated_at.strftime("TELEMETRY · %H:%M")
        stamp_font = self._font(12)
        stamp_width = draw.textbbox((0, 0), stamp, font=stamp_font)[2]
        draw.text((630 - stamp_width, 42), stamp, font=stamp_font, fill=0)
        draw.line((18, 64, 630, 64), fill=0, width=2)

    def _footer(self, draw: ImageDraw.ImageDraw) -> None:
        draw.text((18, 461), f"ELINK AGENT · v{__version__}", font=self._font(12, bold=False), fill=0)
        self._page_dots(draw, 630, 468, active=0)

    @staticmethod
    def _page_dots(draw: ImageDraw.ImageDraw, right: int, cy: int, *, active: int) -> None:
        """两页轮播的指示点：AI 面板是第一页，设备监控是第二页。"""
        for index in range(2):
            cx = right - 22 + index * 16
            draw.ellipse((cx - 4, cy - 4, cx + 4, cy + 4), outline=0, width=2,
                         fill=0 if index == active else 255)

    def _provider_panel(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                        name: str, provider: ProviderStatus, *,
                        sessions: list[SessionSummary], events: list[RecentEvent],
                        updated_at: datetime, large: bool = False) -> None:
        x0, y0, x1, y1 = box
        # PocketJS 风格的实体偏移阴影在 1-bit 屏上比灰阶阴影更可靠。两层都收在
        # 组件框内，静态外形不会扩大额度变化时的脏矩形。
        draw.rounded_rectangle((x0 + 3, y0 + 3, x1, y1), radius=12, fill=0)
        draw.rounded_rectangle((x0, y0, x1 - 3, y1 - 3), radius=12,
                               fill=255, outline=0, width=2)
        title_size = 32 if large else 25
        provider_index = "PROVIDER 01" if name.lower() == "claude" else "PROVIDER 02"
        draw.text((x0 + 16, y0 + 10), provider_index,
                  font=self._font(10, bold=True), fill=0)
        draw.text((x0 + 16, y0 + 25), name.upper(),
                  font=self._font(title_size, bold=True), fill=0)
        self._status_badge(draw, box, provider, large)

        pct = self._percentage(provider.primary_pct)
        label_x = x0 + (250 if large else 168)
        draw.text((x0 + 16, y0 + 67), "5 HOUR WINDOW",
                  font=self._font(12, bold=True), fill=0)
        pct_font = self._fit_font(draw, pct, preferred=92 if large else 68,
                                  minimum=54 if large else 42,
                                  max_width=label_x - (x0 + 16) - 12, bold=True)
        draw.text((x0 + 16, y0 + 79), pct, font=pct_font, fill=0)
        draw.text((label_x, y0 + 91), "USED", font=self._font(15, bold=True), fill=0)
        reset = self._reset(provider.primary_reset_min).replace("reset ", "")
        draw.text((label_x, y0 + 115), f"RESET {reset.upper()}",
                  font=self._font(12), fill=0)

        bar_y = y0 + 156
        self._progress(draw, x0 + 16, bar_y, x1 - 16, provider.primary_pct)

        weekly_y = bar_y + 45
        draw.text((x0 + 16, weekly_y), "WEEKLY LIMIT", font=self._font(14, bold=True), fill=0)
        weekly = self._percentage(provider.weekly_pct)
        wf = self._font(24, bold=True)
        ww = draw.textbbox((0, 0), weekly, font=wf)[2]
        draw.text((x1 - 16 - ww, weekly_y - 6), weekly, font=wf, fill=0)
        self._progress(draw, x0 + 16, weekly_y + 28, x1 - 16, provider.weekly_pct, height=12)
        draw.text((x0 + 16, weekly_y + 48), self._reset(provider.weekly_reset_min).upper(),
                  font=self._font(12), fill=0)

        token_y = y1 - 108
        draw.line((x0 + 16, token_y, x1 - 16, token_y), fill=0, width=1)
        draw.text((x0 + 16, token_y + 8), "TODAY TOKENS", font=self._font(12, bold=True), fill=0)
        token = self._compact(provider.tokens_today)
        tf = self._font(24, bold=True)
        tw = draw.textbbox((0, 0), token, font=tf)[2]
        draw.text((x1 - 16 - tw, token_y + 1), token, font=tf, fill=0)
        has_activity = bool(sessions or events)
        self._model_usage(
            draw, x0 + 16, token_y + 34, x1 - 16, provider.model_usage_today, name,
            max_rows=2 if has_activity else self._MODEL_ROWS,
            show_hidden=True,
        )
        if has_activity:
            self._activity_rows(draw, box, sessions, events, updated_at)

    def _badge_box(self, box: tuple[int, int, int, int],
                   large: bool) -> tuple[int, int, int, int]:
        _, y0, x1, _ = box
        width = 186 if large else 152
        height = 32 if large else 28
        return (x1 - 16 - width, y0 + 17, x1 - 16, y0 + 17 + height)

    def _activity_box(self, box: tuple[int, int, int, int], index: int) -> tuple[int, int, int, int]:
        x0, _, x1, y1 = box
        top = y1 - 108 + 34 + index * self._MODEL_ROW_HEIGHT
        return (x0 + 16, top, x1 - 16, top + self._MODEL_ROW_HEIGHT - 1)

    def _status_badge(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                      provider: ProviderStatus, large: bool) -> None:
        """待处理动作用反白徽章表示，而不是加粗卡片边框。

        加粗边框改的是卡片四条边，它们连成一个环，脏矩形就是整张卡片的外接矩形
        （约屏幕的 37%），刚好越过区域刷新的面积阈值。于是最需要立刻看见的事件
        反而触发了整帧刷新。徽章把同一个信号收进一个固定矩形，代价约 2.5% 屏幕。
        """
        bx0, by0, bx1, by1 = self._badge_box(box, large)
        # 反白只留给真正要人处理的事。额度停止刷新但数字仍可信时画 STALE 且
        # 不反白，免得它跟 ACTION REQUIRED 抢同一份注意力。
        stale = provider.usage_is_stale
        attention = provider.needs_input or (bool(provider.error) and not stale)
        if provider.needs_input:
            text = "ACTION REQUIRED"
        elif stale:
            text = "STALE"
        elif provider.error:
            text = "ERROR"
        else:
            text = provider.status.upper()
        font = self._font(18 if large else 15, bold=True)
        radius = (by1 - by0) // 2
        draw.rounded_rectangle((bx0, by0, bx1, by1), radius=radius,
                               fill=0 if attention else 255, outline=0, width=1)
        bounds = draw.textbbox((0, 0), text, font=font)
        y = by0 + (by1 - by0 - bounds[3]) // 2
        text_x = bx0 + (bx1 - bx0 - bounds[2]) // 2
        draw.text((text_x, y), text, font=font, fill=255 if attention else 0)

    def _model_usage(self, draw: ImageDraw.ImageDraw, x0: int, y0: int, x1: int,
                     usage: list, provider_name: str, *, max_rows: int,
                     show_hidden: bool) -> None:
        # 行高和字号固定：让它们跟随模型数量，会把「多用了一个模型」变成整列重排
        if not usage:
            return
        font = self._font(self._MODEL_FONT_SIZE, bold=True)
        visible = list(usage[:max_rows])
        if show_hidden and len(usage) > len(visible):
            visible = visible[:max_rows - 1]
        for index, item in enumerate(visible):
            y = y0 + index * self._MODEL_ROW_HEIGHT
            value = self._compact(item.tokens)
            value_width = draw.textbbox((0, 0), value, font=font)[2]
            label = self._model_label(item.model, provider_name)
            label = self._truncate(draw, label, font, max(12, x1 - x0 - value_width - 8))
            draw.text((x0, y), label, font=font, fill=0)
            draw.text((x1 - value_width, y), value, font=font, fill=0)
        hidden = len(usage) - len(visible)
        if show_hidden and hidden:
            y = y0 + len(visible) * self._MODEL_ROW_HEIGHT
            draw.text((x0, y), f"+{hidden} more", font=font, fill=0)

    def _activity_rows(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                       sessions: list[SessionSummary], events: list[RecentEvent],
                       updated_at: datetime) -> None:
        font = self._font(self._MODEL_FONT_SIZE, bold=True)
        now = int(updated_at.timestamp())
        if sessions:
            item = sessions[0]
            state = "WORK" if item.state == "working" else "IDLE"
            detail = " · ".join(part for part in (item.project, item.model) if part)
            text = f"NOW {state} {detail}".rstrip()
            if item.updated_at:
                text += f" · {self._age(now, item.updated_at)}"
            self._activity_text(draw, box, 2, text, font)
        if events:
            item = events[0]
            kind = {"needs_input": "ACTION", "working": "WORKING", "idle": "IDLE"}[item.kind]
            text = f"EVENT {kind}"
            if item.occurred_at:
                text += f" · {self._age(now, item.occurred_at)}"
            self._activity_text(draw, box, 3, text, font)

    def _activity_text(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                       index: int, text: str, font) -> None:
        x0, y0, x1, _ = self._activity_box(box, index)
        draw.text((x0, y0), self._truncate(draw, text, font, x1 - x0), font=font, fill=0)

    @staticmethod
    def _for_provider(items: list, provider: str) -> list:
        return [item for item in items if item.provider == provider]

    @staticmethod
    def _age(now: int, occurred_at: int) -> str:
        minutes = max(0, (now - occurred_at) // 60)
        if minutes < 1:
            return "now"
        if minutes < 60:
            return f"{minutes}m"
        return f"{minutes // 60}h"

    @staticmethod
    def _progress(draw: ImageDraw.ImageDraw, x0: int, y0: int, x1: int,
                  value: float | None, height: int = 18) -> None:
        radius = max(2, height // 2)
        draw.rounded_rectangle((x0, y0, x1, y0 + height), radius=radius,
                               outline=0, width=2)
        if value is None:
            for x in range(x0 + 3, x1 - 2, 9):
                draw.line((x, y0 + height - 3, min(x + 6, x1 - 2), y0 + 3), fill=0, width=1)
            return
        fill_width = int((x1 - x0 - 6) * min(100, max(0, value)) / 100)
        if fill_width:
            draw.rounded_rectangle((x0 + 3, y0 + 3, x0 + 3 + fill_width, y0 + height - 3),
                                   radius=max(1, (height - 6) // 2), fill=0)

    @staticmethod
    def _reset(minutes: int | None) -> str:
        if minutes is None:
            return "reset —"
        if minutes >= 1440:
            return f"reset {minutes // 1440}d {minutes % 1440 // 60}h"
        if minutes >= 60:
            return f"reset {minutes // 60}h {minutes % 60}m"
        return f"reset {minutes}m"

    @staticmethod
    def _percentage(value: float | None) -> str:
        return "—" if value is None else f"{int(value)}%"

    @staticmethod
    def _compact(value: int) -> str:
        if value >= 1_000_000:
            return f"{value / 1_000_000:.1f}M"
        if value >= 1_000:
            return f"{value / 1_000:.1f}K"
        return str(value)

    @staticmethod
    def _model_label(model: str, provider_name: str) -> str:
        value = model.strip()
        prefixes = ["claude-"] if provider_name.lower() == "claude" else ["gpt-", "openai-"]
        lowered = value.lower()
        for prefix in prefixes:
            if lowered.startswith(prefix):
                value = value[len(prefix):]
                break
        return value or "unknown"

    @staticmethod
    def _truncate(draw: ImageDraw.ImageDraw, text: str, font, max_width: int) -> str:
        if draw.textbbox((0, 0), text, font=font)[2] <= max_width:
            return text
        suffix = "…"
        while text and draw.textbbox((0, 0), text + suffix, font=font)[2] > max_width:
            text = text[:-1]
        return text + suffix

    def _font(self, size: int, bold: bool = True) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
        font = self._fonts.get((size, bold))
        if font is None:
            font = self._load_font(size, bold)
            self._fonts[(size, bold)] = font
        return font

    def _load_font(self, size: int, bold: bool) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
        path = self._bold_font_path if bold else self.font_path
        try:
            return ImageFont.truetype(path, size=size)
        except (OSError, ValueError):
            return ImageFont.load_default(size=size)

    @staticmethod
    def _bold_variant(path: str) -> str:
        if path.endswith("DejaVuSans.ttf"):
            bold_path = path.replace("DejaVuSans.ttf", "DejaVuSans-Bold.ttf")
            if Path(bold_path).exists():
                return bold_path
        return path

    def _fit_font(self, draw: ImageDraw.ImageDraw, text: str, *, preferred: int,
                  minimum: int, max_width: int,
                  bold: bool = True) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
        for size in range(preferred, minimum - 1, -2):
            font = self._font(size, bold=bold)
            if draw.textbbox((0, 0), text, font=font)[2] <= max_width:
                return font
        return self._font(minimum, bold=bold)

    # ---------------------------------------------------------------------- #
    #  Device-monitor page. Rendered straight to a full 648x480 frame; the
    #  frame differ keeps region refreshes inside the card that changed.
    # ---------------------------------------------------------------------- #

    def render_monitor(self, mon, *, updated_at=None, panel=None) -> Image.Image:
        updated_at = updated_at or datetime.now().astimezone()
        image = Image.new("L", (self.width, self.height), 255)
        draw = ImageDraw.Draw(image)
        self._monitor_header(draw, mon, updated_at)
        self._monitor_rules(draw)
        boxes = self._monitor_boxes()
        self._monitor_hero(draw, boxes[0], mon)
        for box, spec in zip(boxes[1:5], self._monitor_rows(mon)):
            self._monitor_row(draw, box, **spec)
        self._monitor_strip(draw, boxes[5], mon, panel)
        return image.convert("1", dither=Image.Dither.NONE)

    def _monitor_boxes(self):
        x0, x1 = self.MONITOR_ROW_X
        rows = [(x0, top, x1, top + self.MONITOR_ROW_HEIGHT) for top in self.MONITOR_ROW_TOPS]
        return [self.MONITOR_HERO_BOX, *rows, self.MONITOR_STRIP_BOX]

    def _monitor_rules(self, draw: ImageDraw.ImageDraw) -> None:
        """分组发丝线。全部画在框与框的空隙里，所以是纯静态墨水。"""
        hero = self.MONITOR_HERO_BOX
        row_x0, row_x1 = self.MONITOR_ROW_X
        gutter = (hero[2] + row_x0) // 2
        draw.line((gutter, hero[1], gutter, hero[3]), fill=0, width=1)
        for previous, top in zip(self.MONITOR_ROW_TOPS, self.MONITOR_ROW_TOPS[1:]):
            # 落在两行之间的空隙正中，而不是压在上一行的下边界上
            gap = (previous + self.MONITOR_ROW_HEIGHT + top) // 2
            draw.line((row_x0, gap, row_x1, gap), fill=0, width=1)
        strip_top = self.MONITOR_STRIP_BOX[1]
        draw.line((hero[0], strip_top - 6, row_x1, strip_top - 6), fill=0, width=1)

    def _monitor_hero(self, draw: ImageDraw.ImageDraw, box, mon) -> None:
        """主角卡：一个压倒性的 load 数字，下面挂使用率条和最近半小时的趋势。"""
        x0, y0, x1, y1 = box
        self._monitor_surface(draw, box, radius=12)
        left, right = x0 + 14, x1 - 14
        draw.text((left, y0 + 10), "PRIMARY METRIC", font=self._font(10, bold=True), fill=0)
        draw.text((left, y0 + 26), "CPU LOAD", font=self._font(20, bold=True), fill=0)
        value = f"{mon.load_1m:.1f}"
        draw.text((left, y0 + 50),
                  value,
                  font=self._fit_font(draw, value, preferred=76, minimum=52,
                                      max_width=right - left, bold=True),
                  fill=0)
        draw.text((left, y0 + 129), f"1 MIN AVERAGE · {_CPU_CORES} CORES",
                  font=self._font(11), fill=0)

        usage = self._cpu_usage_pct(mon)
        draw.text((left, y0 + 158), "CPU USAGE", font=self._font(12, bold=True), fill=0)
        pct = self._percentage(usage)
        pct_font = self._font(20, bold=True)
        pct_w = draw.textbbox((0, 0), pct, font=pct_font)[2]
        draw.text((right - pct_w, y0 + 151), pct, font=pct_font, fill=0)
        self._progress(draw, left, y0 + 181, right, usage, height=14)

        history = tuple(mon.cpu_history)[-self.MONITOR_SPARK_SLOTS:]
        caption = f"LAST {self.MONITOR_SPARK_SLOTS} SAMPLES"
        if history:
            caption += f" · PEAK {max(history):.0f}%"
        draw.text((left, y0 + 207), caption, font=self._font(10), fill=0)
        self._sparkline(draw, left, y0 + 224, right, y0 + 286, history)
        draw.text((left, y0 + 298),
                  f"5m {mon.load_5m:.1f} · 15m {mon.load_15m:.1f}",
                  font=self._font(11), fill=0)

    def _monitor_rows(self, mon):
        return [
            dict(title="MEMORY", value=f"{mon.mem_percent:.0f}%", bar_pct=mon.mem_percent,
                 sub=f"{self._fmt_bytes(mon.mem_available_kb * 1024)} free of "
                     f"{self._fmt_bytes(mon.mem_total_kb * 1024)}"),
            dict(title="STORAGE", value=f"{mon.disk_percent:.0f}%", bar_pct=mon.disk_percent,
                 sub=f"{self._fmt_bytes(mon.disk_used)} used of {self._fmt_bytes(mon.disk_total)}"),
            dict(title="THERMAL", value=self._fmt_temp(mon.temp_c), bar_pct=self._temp_pct(mon.temp_c),
                 sub="cpu thermal zone · 85°C limit"),
            dict(title="NETWORK", value=self._net_rate(mon), bar_pct=None, value_size=19,
                 sub=f"rx {self._fmt_bytes(mon.net_rx_total)} · tx {self._fmt_bytes(mon.net_tx_total)}"),
        ]

    def _monitor_row(self, draw: ImageDraw.ImageDraw, box, *, title, value,
                     sub="", bar_pct=None, value_size: int = 26) -> None:
        x0, y0, x1, y1 = box
        self._monitor_surface(draw, box, radius=6)
        left, right = x0 + 12, x1 - 12
        title_font = self._font(12, bold=True)
        draw.text((left, y0 + 10), title, font=title_font, fill=0)
        title_w = draw.textbbox((0, 0), title, font=title_font)[2]
        value_font = self._fit_font(draw, value, preferred=value_size, minimum=15,
                                    max_width=right - left - title_w - 12, bold=True)
        value_w = draw.textbbox((0, 0), value, font=value_font)[2]
        draw.text((right - value_w, y0 + 4), value, font=value_font, fill=0)
        if bar_pct is not None:
            self._progress(draw, left, y0 + 35, right, bar_pct, height=10)
        if sub:
            font = self._font(10, bold=False)
            draw.text((left, y1 - 20), self._truncate(draw, sub, font, right - left),
                      font=font, fill=0)

    def _monitor_strip(self, draw: ImageDraw.ImageDraw, box, mon, panel) -> None:
        x0, y0, x1, y1 = box
        self._monitor_surface(draw, box, radius=6)
        left, right_edge = x0 + 12, x1 - 12
        draw.text((left, y0 + 7), "PANEL", font=self._font(11, bold=True), fill=0)
        value = self._panel_value(panel)
        value_font = self._font(13, bold=True)
        value_w = draw.textbbox((0, 0), value, font=value_font)[2]
        state_box = (left + 50, y0 + 5, left + 70 + value_w, y0 + 25)
        alert = value == "ERROR"
        draw.rounded_rectangle(state_box, radius=10, fill=0 if alert else 255,
                               outline=0, width=1)
        draw.text((state_box[0] + 10, y0 + 7), value, font=value_font,
                  fill=255 if alert else 0)
        value_right = state_box[2]
        host_font = self._font(14, bold=True)
        host = self._truncate(draw, mon.hostname, host_font, right_edge - value_right - 16)
        host_w = draw.textbbox((0, 0), host, font=host_font)[2]
        draw.text((right_edge - host_w, y0 + 7), host, font=host_font, fill=0)
        sub_font = self._font(10)
        sub = self._truncate(draw, self._panel_sub(panel), sub_font, x1 - x0 - 60)
        sub_y = y0 + self.MONITOR_STRIP_SUB_Y
        draw.text((left, sub_y), sub, font=sub_font, fill=0)
        # 地址行和面板副标题共用一行：左边是面板健康，右边是每张网卡的地址。右端停
        # 在翻页点左侧的 DOTS_GUTTER 处，所以再长的地址列表也不会画到点上。网卡多
        # 到一行放不下时折到下一行——那一行整条都空着，宽度比第一行的空档宽得多。
        sub_w = draw.textbbox((0, 0), sub, font=sub_font)[2]
        right = x1 - self.MONITOR_DOTS_GUTTER
        slots = [(0, right - (left + sub_w + 16)),
                 (self.MONITOR_ADDRESS_LINE_H, right - left)]
        slots = [slot for slot in slots if slot[1] >= self.MONITOR_ADDRESS_MIN_WIDTH]
        lines = self._address_lines(draw, self._address_segments(mon), sub_font,
                                    [width for _, width in slots])
        for (offset, _), line in zip(slots, lines):
            text_w = draw.textbbox((0, 0), line, font=sub_font)[2]
            draw.text((right - text_w, sub_y + offset), line, font=sub_font, fill=0)
        self._page_dots(draw, x1, y1 - 12, active=1)

    def _sparkline(self, draw: ImageDraw.ImageDraw, x0: int, y0: int, x1: int, y1: int,
                   values) -> None:
        """CPU 使用率柱状趋势。柱位固定、右对齐（最新的在最右），样本不足时左侧
        留空，这样新样本只改变柱高，不会让整条重排。

        纵轴按峰值自适应，并有一个 25% 的下限：闲置的树莓派长期在 2% 上下，固定
        0-100 会把整条趋势压成一条看不见的线（真机上就是这样），而没有下限又会把
        1% 和 2% 的噪声放大成剧烈起伏。
        """
        draw.line((x0, y1, x1, y1), fill=0, width=1)
        slot = (x1 - x0) // self.MONITOR_SPARK_SLOTS
        recent = list(values)[-self.MONITOR_SPARK_SLOTS:]
        if not recent:
            draw.text((x0, y0 + 4), "collecting samples…", font=self._font(12), fill=0)
            return
        span = y1 - y0 - 1
        scale = max(self.MONITOR_SPARK_MIN_SCALE, max(recent))
        first = x1 - len(recent) * slot
        for index, value in enumerate(recent):
            value = min(scale, max(0.0, value))
            if value <= 0:
                continue
            # 有负载就至少画得见：2px 的柱子比 0px 的空白诚实
            height = max(2, int(span * value / scale))
            left = first + index * slot
            draw.rectangle((left, y1 - height, left + slot - 2, y1 - 1), fill=0)

    @staticmethod
    def _cpu_usage_pct(mon) -> float:
        """采样器给不出瞬时使用率时（第一帧），用 load/核数 近似，别让卡片空着。"""
        if mon.cpu_percent is not None:
            return mon.cpu_percent
        return min(100.0, mon.load_1m / _CPU_CORES * 100)

    def _monitor_header(self, draw, mon, updated_at) -> None:
        draw.rounded_rectangle((18, 10, 102, 31), radius=6, fill=0)
        draw.text((28, 12), "ELINK AI", font=self._font(12, bold=True), fill=255)
        draw.text((18, 31), "DEVICE CONTROL", font=self._font(27, bold=True), fill=0)
        # 监控页的时间戳带秒。分钟粒度下四次 tick 里只有一次看得出变化，这一页
        # 看起来就像卡住了。代价是每一拍时钟都变，也就没有「整帧未变直接跳过」
        # 那条省刷新的路径了——AI 页仍是分钟粒度，它只在数据变化时才重绘。
        up = self._uptime_str(mon.uptime_s)
        up_font = self._font(13, bold=True)
        up_w = draw.textbbox((0, 0), up, font=up_font)[2]
        badge = (630 - up_w - 20, 10, 630, 33)
        draw.rounded_rectangle(badge, radius=11, fill=0)
        draw.text((badge[0] + 10, 13), up.upper(), font=up_font, fill=255)
        stamp = updated_at.strftime("TELEMETRY · %H:%M:%S")
        stamp_font = self._font(11)
        stamp_w = draw.textbbox((0, 0), stamp, font=stamp_font)[2]
        draw.text((630 - stamp_w, 43), stamp, font=stamp_font, fill=0)
        draw.line((18, 64, 630, 64), fill=0, width=2)

    @staticmethod
    def _monitor_surface(draw: ImageDraw.ImageDraw, box, *, radius: int) -> None:
        """PocketJS 式实体表面；阴影和白色面板都严格收在动态组件框内。"""
        x0, y0, x1, y1 = box
        draw.rounded_rectangle((x0 + 3, y0 + 3, x1 - 1, y1 - 1), radius=radius, fill=0)
        draw.rounded_rectangle((x0, y0, x1 - 4, y1 - 4), radius=radius,
                               fill=255, outline=0, width=1)

    @staticmethod
    def _address_segments(mon) -> tuple[str, ...]:
        """每张网卡一段「名字 地址」。无头设备上这一行就是「怎么连上它」的答案，
        而带 overlay 的机器有好几个都是对的答案，所以全列出来而不是只挑一个。

        取不到具名地址时（非 Linux）退回出口 IP：一个没有名字的地址仍然可用。
        """
        interfaces = tuple(getattr(mon, "interfaces", ()) or ())
        if interfaces:
            return tuple(f"{name} {address}" for name, address in interfaces)
        fallback = getattr(mon, "ip_address", None)
        return (fallback,) if fallback else ()

    def _address_lines(self, draw: ImageDraw.ImageDraw, segments, font,
                       widths) -> tuple[str, ...]:
        """把地址段贪心地装进给定宽度的几行。折行永远在段与段之间，所以每张网卡
        的「名字 地址」不会被拆到两行上。

        行数还是不够时，剩下的段挤进最后一行再截断：截掉几个字符仍然看得出还有
        别的网卡，而直接丢掉一段会让人以为那条路不通。
        """
        pending = list(segments)
        if not pending or not widths:
            return ()
        lines: list[str] = []
        for width in widths:
            if not pending:
                break
            line = pending.pop(0)
            while pending:
                candidate = f"{line}{self.MONITOR_ADDRESS_SEP}{pending[0]}"
                if draw.textbbox((0, 0), candidate, font=font)[2] > width:
                    break
                line = candidate
                pending.pop(0)
            lines.append(line)
        if pending:
            lines[-1] = self.MONITOR_ADDRESS_SEP.join([lines[-1], *pending])
        return tuple(self._truncate(draw, line, font, width)
                     for line, width in zip(lines, widths))

    @staticmethod
    def _panel_value(panel) -> str:
        if not panel:
            return "WAIT"
        if panel.get("error"):
            return "ERROR"
        kind = panel.get("last_refresh_kind") or "none"
        return kind.upper()

    @staticmethod
    def _panel_sub(panel) -> str:
        if not panel:
            return "no refresh yet"
        parts = []
        kind = panel.get("last_refresh_kind") or "none"
        parts.append(kind)
        regions = panel.get("last_refresh_region_count")
        if regions:
            parts.append(f"{regions} win")
        busy = panel.get("last_busy_wait_ms")
        if busy:
            parts.append(f"busy {busy}ms")
        if panel.get("error"):
            parts.append("error")
        return " · ".join(parts)

    @staticmethod
    def _net_rate(mon) -> str:
        if mon.net_rx_bps is None and mon.net_tx_bps is None:
            return "—"
        down = DashboardRenderer._fmt_rate(mon.net_rx_bps)
        up = DashboardRenderer._fmt_rate(mon.net_tx_bps)
        return f"↓{down} ↑{up}"

    @staticmethod
    def _fmt_rate(bps: float | None) -> str:
        if bps is None:
            return "—"
        # 三位有效数字就够：440.0K/s 比 440K/s 只多噪音，还多一次局部刷新
        for scale, suffix in ((1_000_000, "M/s"), (1_000, "K/s")):
            if bps >= scale:
                value = bps / scale
                return f"{value:.0f}{suffix}" if value >= 100 else f"{value:.1f}{suffix}"
        return f"{bps:.0f}B/s"

    @staticmethod
    def _fmt_bytes(value: int) -> str:
        if value >= 1 << 30:
            return f"{value / (1 << 30):.1f}G"
        if value >= 1 << 20:
            return f"{value / (1 << 20):.0f}M"
        if value >= 1 << 10:
            return f"{value / (1 << 10):.0f}K"
        return f"{value}B"

    @staticmethod
    def _fmt_temp(temp: float | None) -> str:
        return "—" if temp is None else f"{temp:.1f}°C"

    @staticmethod
    def _temp_pct(temp: float | None) -> float | None:
        if temp is None:
            return None
        return min(100.0, temp / 85.0 * 100)

    @staticmethod
    def _uptime_str(seconds: float) -> str:
        seconds = int(seconds)
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        minutes = (seconds % 3600) // 60
        if days:
            return f"up {days}d {hours}h"
        if hours:
            return f"up {hours}h {minutes}m"
        return f"up {minutes}m"

    @staticmethod
    def _find_font(configured: str) -> str:
        candidates = [
            configured,
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
        ]
        return next((path for path in candidates if path and Path(path).exists()), "")
