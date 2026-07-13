from __future__ import annotations

from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .models import ProviderStatus, StatusSnapshot


class DashboardRenderer:
    width = 648
    height = 480

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
            self._provider_panel(draw, (18, 74, 630, 458), mode.capitalize(), provider, large=True)
        else:
            self._provider_panel(draw, (18, 74, 316, 458), "Claude", snapshot.claude)
            self._provider_panel(draw, (332, 74, 630, 458), "Codex", snapshot.codex)
        return image.convert("1", dither=Image.Dither.NONE)

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

    def _provider_panel(self, draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int],
                        name: str, provider: ProviderStatus, large: bool = False) -> None:
        x0, y0, x1, y1 = box
        attention = provider.needs_input
        draw.rounded_rectangle(box, radius=10, outline=0, width=6 if attention else 2)
        title_size = 34 if large else 27
        draw.text((x0 + 16, y0 + 12), name, font=self._font(title_size, bold=True), fill=0)
        status = "ACTION REQUIRED" if attention else provider.status.upper()
        status_font = self._font(18 if large else 15, bold=True)
        sw = draw.textbbox((0, 0), status, font=status_font)[2]
        draw.text((x1 - 16 - sw, y0 + 20), status, font=status_font, fill=0)

        pct = "—" if provider.primary_pct is None else f"{int(provider.primary_pct)}%"
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
        weekly = "—" if provider.weekly_pct is None else f"{int(provider.weekly_pct)}%"
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
        self._model_usage(draw, x0 + 16, token_y + 34, x1 - 16, y1 - 7,
                          provider.model_usage_today, name)

    def _model_usage(self, draw: ImageDraw.ImageDraw, x0: int, y0: int, x1: int, y1: int,
                     usage: list, provider_name: str) -> None:
        if not usage:
            return
        row_height = max(7, min(18, (y1 - y0) // len(usage)))
        font_size = max(7, min(12, row_height - 2))
        font = self._font(font_size, bold=True)
        value_font = self._font(font_size, bold=True)
        for index, item in enumerate(usage):
            y = y0 + index * row_height
            if y >= y1:
                break
            value = self._compact(item.tokens)
            value_width = draw.textbbox((0, 0), value, font=value_font)[2]
            label = self._model_label(item.model, provider_name)
            label = self._truncate(draw, label, font, max(12, x1 - x0 - value_width - 8))
            draw.text((x0, y), label, font=font, fill=0)
            draw.text((x1 - value_width, y), value, font=value_font, fill=0)

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
