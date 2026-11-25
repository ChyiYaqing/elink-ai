from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from math import isfinite
from typing import Any


@dataclass(slots=True)
class ModelUsage:
    model: str
    tokens: int


@dataclass(slots=True)
class SessionSummary:
    id: str
    provider: str
    project: str
    model: str
    state: str
    updated_at: int

    @classmethod
    def from_dict(cls, value: Any) -> "SessionSummary | None":
        if not isinstance(value, dict):
            return None
        session_id = _text(value.get("id"), 128)
        provider = _text(value.get("provider"), 16)
        if not session_id or provider not in {"claude", "codex", "gemini"}:
            return None
        state = _text(value.get("state"), 16)
        if state not in {"working", "idle"}:
            state = "idle"
        return cls(
            id=session_id,
            provider=provider,
            project=_text(value.get("project"), 80),
            model=_text(value.get("model"), 80),
            state=state,
            updated_at=max(0, _int(value.get("updated_at"), 0) or 0),
        )


@dataclass(slots=True)
class RecentEvent:
    id: str
    provider: str
    kind: str
    occurred_at: int

    @classmethod
    def from_dict(cls, value: Any) -> "RecentEvent | None":
        if not isinstance(value, dict):
            return None
        event_id = _text(value.get("id"), 128)
        provider = _text(value.get("provider"), 16)
        kind = _text(value.get("kind"), 32)
        if (not event_id or provider not in {"claude", "codex", "gemini"}
                or kind not in {"working", "idle", "needs_input"}):
            return None
        occurred_at = max(0, _int(value.get("occurred_at"), 0) or 0)
        return cls(event_id, provider, kind, occurred_at)


@dataclass(slots=True)
class ScopedLimit:
    """只对某个模型生效的周额度，例如 Max 账号单独计的 Opus 周限额。

    与 `weekly_pct` 分开：那是整个账号的总周限额，这些是套在它里面的子限额。
    """

    id: str
    title: str
    pct: float | None = None
    reset_min: int | None = None

    @classmethod
    def from_dict(cls, value: Any) -> "ScopedLimit | None":
        if not isinstance(value, dict):
            return None
        title = _text(value.get("title"), 32)
        if not title:
            return None
        return cls(
            id=_text(value.get("id"), 64) or title,
            title=title,
            pct=_pct(value.get("pct")),
            reset_min=_int(value.get("reset_min")),
        )


CREDITS_UNIT = "credits"


@dataclass(slots=True)
class ExtraUsage:
    """订阅额度之外、按量计费的池子。

    数是换算好的，最小单位的缩位由 bridge 完成：只在一处换算，所有读者才不会
    各自缩错位数。上限缺席或非正数时整块不成立，`from_dict` 返回 None。

    `unit` 要么是 ISO 货币代码，要么是 `credits`——Codex 的额度按积分计，给它
    加个货币符号就是把积分说成钱。
    """

    used: float
    limit: float
    pct: float
    unit: str = "USD"

    @property
    def is_credits(self) -> bool:
        return self.unit == CREDITS_UNIT

    @classmethod
    def from_dict(cls, value: Any) -> "ExtraUsage | None":
        if not isinstance(value, dict):
            return None
        limit = _amount(value.get("limit"))
        used = _amount(value.get("used"))
        if limit is None or limit <= 0 or used is None:
            return None
        pct = _pct(value.get("pct"))
        if pct is None:
            pct = used / limit * 100
        # 老 bridge 发的是 currency；两个名字指的是同一件事
        raw = _text(value.get("unit") or value.get("currency"), 16)
        unit = CREDITS_UNIT if raw.lower() == CREDITS_UNIT else (raw.upper() or "USD")
        return cls(used=used, limit=limit, pct=min(100.0, pct), unit=unit)


@dataclass(slots=True)
class ProviderStatus:
    status: str = "offline"
    tokens_today: int = 0
    model_usage_today: list[ModelUsage] = field(default_factory=list)
    primary_pct: float | None = None
    primary_reset_min: int | None = None
    weekly_pct: float | None = None
    weekly_reset_min: int | None = None
    scoped_limits: list[ScopedLimit] = field(default_factory=list)
    extra_usage: ExtraUsage | None = None
    #: 账号上还剩多少积分（Codex）。None 表示这个账号根本没有积分池，
    #: 与「余额是零」不是一回事。
    credit_balance: float | None = None
    needs_input: bool = False
    error: str | None = None
    usage_cached: bool = False

    @property
    def usage_is_stale(self) -> bool:
        """取数失败，但手上仍有可信的缓存额度。

        额度接口被限流时 bridge 会回退到状态栏缓存，百分比照样是准的，只是
        停止了实时刷新。这种情况按第 6 节的约定属于陈旧而非错误 —— 画 ERROR
        会让人以为屏幕上的数字不能信，而它们其实可信。
        """
        if not self.error or not self.usage_cached:
            return False
        return self.primary_pct is not None or self.weekly_pct is not None

    @classmethod
    def from_dict(cls, value: Any, *, provider: str) -> "ProviderStatus":
        obj = value if isinstance(value, dict) else {}
        status = obj.get("status", "offline")
        if status not in {"working", "idle", "offline"}:
            status = "offline"
        primary_prefix = "five_hour" if provider == "claude" else "primary"
        weekly_prefix = "seven_day" if provider == "claude" else "weekly"
        raw_model_usage = obj.get("model_usage_today", [])
        model_totals: dict[str, int] = {}
        for item in raw_model_usage if isinstance(raw_model_usage, list) else []:
            if not isinstance(item, dict) or not isinstance(item.get("model"), str):
                continue
            model = item["model"].strip()
            tokens = _int(item.get("tokens"), 0) or 0
            if model and tokens > 0:
                model_totals[model] = model_totals.get(model, 0) + tokens
        model_usage = [ModelUsage(model=model, tokens=tokens)
                       for model, tokens in model_totals.items()]
        model_usage.sort(key=lambda item: (-item.tokens, item.model))
        return cls(
            status=status,
            tokens_today=_int(obj.get("tokens_today"), 0) or 0,
            model_usage_today=model_usage,
            primary_pct=_pct(obj.get(f"{primary_prefix}_pct")),
            primary_reset_min=_int(obj.get(f"{primary_prefix}_reset_min")),
            weekly_pct=_pct(obj.get(f"{weekly_prefix}_pct")),
            weekly_reset_min=_int(obj.get(f"{weekly_prefix}_reset_min")),
            # 老 bridge 不发这两个字段，缺席即「没有子限额 / 没有额度池」
            scoped_limits=[
                limit
                for item in (obj.get("scoped_limits") or [])[:8]
                if (limit := ScopedLimit.from_dict(item)) is not None
            ],
            extra_usage=ExtraUsage.from_dict(obj.get("extra_usage")),
            credit_balance=_amount(obj.get("credit_balance")),
            needs_input=bool(obj.get("needs_input", False)),
            error=obj.get("error") if isinstance(obj.get("error"), str) else None,
            usage_cached=bool(obj.get("provider_usage_cached", False)),
        )


@dataclass(slots=True)
class StatusSnapshot:
    schema_version: int = 1
    generated_at: int = 0
    usage_fetched_at: int | None = None
    claude: ProviderStatus = field(default_factory=ProviderStatus)
    codex: ProviderStatus = field(default_factory=ProviderStatus)
    gemini: ProviderStatus = field(default_factory=ProviderStatus)
    current_sessions: list[SessionSummary] = field(default_factory=list)
    recent_events: list[RecentEvent] = field(default_factory=list)

    @classmethod
    def from_dict(cls, obj: Any) -> "StatusSnapshot":
        if not isinstance(obj, dict):
            raise ValueError("status response must be a JSON object")
        version = _int(obj.get("schema_version"), 1)
        if version != 1:
            raise ValueError(f"unsupported schema_version: {version}")
        generated = _int(obj.get("generated_at"), _int(obj.get("ts"), 0)) or 0
        return cls(
            schema_version=1,
            generated_at=generated,
            usage_fetched_at=_int(obj.get("usage_fetched_at")),
            claude=ProviderStatus.from_dict(obj.get("claude"), provider="claude"),
            codex=ProviderStatus.from_dict(obj.get("codex"), provider="codex"),
            gemini=ProviderStatus.from_dict(obj.get("gemini"), provider="gemini"),
            current_sessions=_parse_items(obj.get("current_sessions"), SessionSummary.from_dict),
            recent_events=_parse_items(obj.get("recent_events"), RecentEvent.from_dict),
        )

    @classmethod
    def offline(cls) -> "StatusSnapshot":
        return cls(generated_at=int(datetime.now(timezone.utc).timestamp()))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _int(value: Any, default: int | None = None) -> int | None:
    if isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _pct(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        percent = float(value)
        return max(0.0, percent) if isfinite(percent) else None
    except (TypeError, ValueError):
        return None


def _amount(value: Any) -> float | None:
    """金额。负数和非有限值一律当作没有：一个负的额度上限没有意义。"""
    if value is None or isinstance(value, bool):
        return None
    try:
        amount = float(value)
    except (TypeError, ValueError):
        return None
    return amount if isfinite(amount) and amount >= 0 else None


def _text(value: Any, limit: int) -> str:
    return value.strip()[:limit] if isinstance(value, str) else ""


def _parse_items(value: Any, parser) -> list:
    if not isinstance(value, list):
        return []
    parsed = []
    for item in value[:64]:
        if result := parser(item):
            parsed.append(result)
            if len(parsed) == 3:
                break
    return parsed
