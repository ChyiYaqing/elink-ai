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
        if not session_id or provider not in {"claude", "codex"}:
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
        if (not event_id or provider not in {"claude", "codex"}
                or kind not in {"working", "idle", "needs_input"}):
            return None
        occurred_at = max(0, _int(value.get("occurred_at"), 0) or 0)
        return cls(event_id, provider, kind, occurred_at)


@dataclass(slots=True)
class ProviderStatus:
    status: str = "offline"
    tokens_today: int = 0
    model_usage_today: list[ModelUsage] = field(default_factory=list)
    primary_pct: float | None = None
    primary_reset_min: int | None = None
    weekly_pct: float | None = None
    weekly_reset_min: int | None = None
    needs_input: bool = False
    error: str | None = None

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
            needs_input=bool(obj.get("needs_input", False)),
            error=obj.get("error") if isinstance(obj.get("error"), str) else None,
        )


@dataclass(slots=True)
class StatusSnapshot:
    schema_version: int = 1
    generated_at: int = 0
    usage_fetched_at: int | None = None
    claude: ProviderStatus = field(default_factory=ProviderStatus)
    codex: ProviderStatus = field(default_factory=ProviderStatus)
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
