from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass

from .models import ProviderStatus, StatusSnapshot


@dataclass(frozen=True, slots=True)
class RefreshDecision:
    refresh: bool
    kind: str = "none"
    reason: str = "unchanged"


class RefreshPolicy:
    def __init__(self, *, min_interval_s: float = 30, full_every: int = 20,
                 full_interval_s: float = 21600):
        self.min_interval_s = min_interval_s
        self.full_every = max(1, full_every)
        self.full_interval_s = full_interval_s
        self.last_signature = ""
        self.last_priority_signature = ""
        self.last_refresh_at = 0.0
        self.last_full_at = 0.0
        self.partial_count = 0

    def decide(self, snapshot: StatusSnapshot, *, stale: bool, now: float | None = None,
               force: str | None = None) -> RefreshDecision:
        now = time.monotonic() if now is None else now
        if force in {"full", "partial", "smart"}:
            # 手动刷新同样要过最小间隔。这个端点没有鉴权，局域网上任何人都能调，
            # 而绕过间隔就意味着可以不停地驱动墨水屏硬件。请求不会被丢掉：调用方
            # 保留着 force，窗口一到同一个请求就会执行，最坏情况是慢一个间隔。
            if self.last_refresh_at and now - self.last_refresh_at < self.min_interval_s:
                return RefreshDecision(False, reason="throttled")
            return RefreshDecision(True, force, "manual")
        signature = self._signature(snapshot, stale)
        priority = self._priority_signature(snapshot, stale)
        time_due = bool(self.last_full_at and now - self.last_full_at >= self.full_interval_s)
        if signature == self.last_signature:
            # 未变化分支不能用 partial_count + 1：full 后计数归零会造成无限维护全刷
            if self.partial_count >= self.full_every or time_due:
                return RefreshDecision(True, "full", "maintenance")
            return RefreshDecision(False)
        high_priority = priority != self.last_priority_signature
        if not high_priority and self.last_refresh_at and now - self.last_refresh_at < self.min_interval_s:
            return RefreshDecision(False, reason="throttled")
        # partial_count + 1 即本次刷新的序号：full_every=1 时每次都 full（禁用 partial）
        full_due = (
            not self.last_signature
            or self.partial_count + 1 >= self.full_every
            or time_due
        )
        return RefreshDecision(True, "full" if full_due else "partial",
                               "priority-change" if high_priority else "data-change")

    def record(self, snapshot: StatusSnapshot, *, stale: bool, kind: str,
               now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        self.last_signature = self._signature(snapshot, stale)
        self.last_priority_signature = self._priority_signature(snapshot, stale)
        self.last_refresh_at = now
        if kind == "full":
            self.partial_count = 0
            self.last_full_at = now
        else:
            self.partial_count += 1

    @staticmethod
    def _provider_view(value: ProviderStatus) -> dict[str, object]:
        return {
            "status": value.status,
            "tokens_today": value.tokens_today,
            "model_usage_today": [(item.model, item.tokens) for item in value.model_usage_today],
            "primary_pct": None if value.primary_pct is None else int(value.primary_pct),
            "primary_reset": None if value.primary_reset_min is None else value.primary_reset_min // 5,
            "weekly_pct": None if value.weekly_pct is None else int(value.weekly_pct),
            "weekly_reset": None if value.weekly_reset_min is None else value.weekly_reset_min // 5,
            "needs_input": value.needs_input,
            "error": bool(value.error),
        }

    def _signature(self, snapshot: StatusSnapshot, stale: bool) -> str:
        value = {
            "stale": stale,
            "claude": self._provider_view(snapshot.claude),
            "codex": self._provider_view(snapshot.codex),
        }
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(raw).hexdigest()

    @staticmethod
    def _priority_signature(snapshot: StatusSnapshot, stale: bool) -> str:
        value = (stale, snapshot.claude.status, snapshot.codex.status,
                 snapshot.claude.needs_input, snapshot.codex.needs_input)
        return repr(value)
