from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


@dataclass(slots=True)
class ProviderStatus:
    status: str = "offline"
    tokens_today: int = 0
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
        return cls(
            status=status,
            tokens_today=_int(obj.get("tokens_today"), 0) or 0,
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
        return min(100.0, max(0.0, float(value)))
    except (TypeError, ValueError):
        return None
