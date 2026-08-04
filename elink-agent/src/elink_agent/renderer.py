from __future__ import annotations

from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from . import __version__
from .models import ProviderStatus, RecentEvent, SessionSummary, StatusSnapshot


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

    _MODEL_ROWS = 4
    _MODEL_ROW_HEIGHT = 15
    _MODEL_FONT_SIZE = 11

    def __init__(self, font_path: str = ""):
        self.font_path = self._find_font(font_path)

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
        draw.text((18, 12), "AI USAGE", font=self._font(34, bold=True), fill=0)
        state = "STALE / MAC OFFLINE" if stale else "LIVE"
        state_font = self._font(18, bold=True)
        state_width = draw.textbbox((0, 0), state, font=state_font)[2]
        draw.text((630 - state_width, 14), state, font=state_font, fill=0)
        stamp = updated_at.strftime("Updated %H:%M")
        stamp_font = self._font(14)
        stamp_width = draw.textbbox((0, 0), stamp, font=stamp_font)[2]
        draw.text((630 - stamp_width, 42), stamp, font=stamp_font, fill=0)
        draw.line((18, 64, 630, 64), fill=0, width=2)

    def _footer(self, draw: ImageDraw.ImageDraw) -> None:
        draw.text((18, 461), f"elink-agent v{__version__}", font=self._font(12, bold=False), fill=0)

    def _provider_panel(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                        name: str, provider: ProviderStatus, *,
                        sessions: list[SessionSummary], events: list[RecentEvent],
                        updated_at: datetime, large: bool = False) -> None:
        x0, y0, x1, y1 = box
        draw.rounded_rectangle(box, radius=10, outline=0, width=2)
        title_size = 34 if large else 27
        draw.text((x0 + 16, y0 + 12), name, font=self._font(title_size, bold=True), fill=0)
        self._status_badge(draw, box, provider, large)

        pct = self._percentage(provider.primary_pct)
        label_x = x0 + (250 if large else 168)
        pct_font = self._fit_font(draw, pct, preferred=92 if large else 66,
                                  minimum=54 if large else 42,
                                  max_width=label_x - (x0 + 16) - 12, bold=True)
        draw.text((x0 + 16, y0 + 58), pct, font=pct_font, fill=0)
        draw.text((label_x, y0 + 75), "5 HOUR", font=self._font(18, bold=True), fill=0)
        draw.text((label_x, y0 + 102), self._reset(provider.primary_reset_min),
                  font=self._font(15), fill=0)

        bar_y = y0 + 156
        self._progress(draw, x0 + 16, bar_y, x1 - 16, provider.primary_pct)

        weekly_y = bar_y + 48
        draw.text((x0 + 16, weekly_y), "WEEK", font=self._font(17, bold=True), fill=0)
        weekly = self._percentage(provider.weekly_pct)
        wf = self._font(25, bold=True)
        ww = draw.textbbox((0, 0), weekly, font=wf)[2]
        draw.text((x1 - 16 - ww, weekly_y - 5), weekly, font=wf, fill=0)
        self._progress(draw, x0 + 16, weekly_y + 31, x1 - 16, provider.weekly_pct, height=12)
        draw.text((x0 + 16, weekly_y + 52), self._reset(provider.weekly_reset_min),
                  font=self._font(14), fill=0)

        token_y = y1 - 108
        draw.line((x0 + 16, token_y, x1 - 16, token_y), fill=0, width=1)
        draw.text((x0 + 16, token_y + 8), "TODAY", font=self._font(15, bold=True), fill=0)
        token = self._compact(provider.tokens_today)
        tf = self._font(22, bold=True)
        tw = draw.textbbox((0, 0), token, font=tf)[2]
        draw.text((x1 - 16 - tw, token_y + 3), token, font=tf, fill=0)
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
        return (x1 - 16 - width, y0 + 16, x1 - 16, y0 + 16 + height)

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
        if attention:
            draw.rectangle((bx0, by0, bx1, by1), fill=0)
        bounds = draw.textbbox((0, 0), text, font=font)
        y = by0 + (by1 - by0 - bounds[3]) // 2
        # 只有反白时才留内边距，否则状态文字的右边缘会比同栏的百分比和 token 内缩
        padding = 8 if attention else 0
        draw.text((bx1 - padding - bounds[2], y), text, font=font, fill=255 if attention else 0)

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
        draw.rectangle((x0, y0, x1, y0 + height), outline=0, width=2)
        if value is None:
            for x in range(x0 + 3, x1 - 2, 9):
                draw.line((x, y0 + height - 3, min(x + 6, x1 - 2), y0 + 3), fill=0, width=1)
            return
        fill_width = int((x1 - x0 - 6) * min(100, max(0, value)) / 100)
        if fill_width:
            draw.rectangle((x0 + 3, y0 + 3, x0 + 3 + fill_width, y0 + height - 3), fill=0)

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
        path = self.font_path
        if bold and path.endswith("DejaVuSans.ttf"):
            bold_path = path.replace("DejaVuSans.ttf", "DejaVuSans-Bold.ttf")
            if Path(bold_path).exists():
                path = bold_path
        try:
            return ImageFont.truetype(path, size=size)
        except (OSError, ValueError):
            return ImageFont.load_default(size=size)

    def _fit_font(self, draw: ImageDraw.ImageDraw, text: str, *, preferred: int,
                  minimum: int, max_width: int,
                  bold: bool = True) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
        for size in range(preferred, minimum - 1, -2):
            font = self._font(size, bold=bold)
            if draw.textbbox((0, 0), text, font=font)[2] <= max_width:
                return font
        return self._font(minimum, bold=bold)

    @staticmethod
    def _find_font(configured: str) -> str:
        candidates = [
            configured,
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
        ]
        return next((path for path in candidates if path and Path(path).exists()), "")
