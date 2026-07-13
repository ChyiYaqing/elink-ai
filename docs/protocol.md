# HTTP protocol v1

The Mac bridge listens on TCP 8765 and the Raspberry Pi agent listens on TCP
8766. Both are plain HTTP services intended for a trusted LAN.

## Bridge

`GET /v1/status` returns `schema_version`, epoch timestamps, and `claude` and
`codex` objects. Unknown percentages and reset times are JSON `null`, never
zero. Each provider may also include `model_usage_today`, sorted by descending
token count, as objects containing `model` and `tokens`. See
`fixtures/status-v1.json` for the complete shape.

`POST /v1/event` accepts:

```json
{"agent":"claude","event":"PreToolUse"}
```

Supported lifecycle events update working/idle state. `PermissionRequest` and
`Elicitation` set the attention flag for five minutes or until another concrete
lifecycle event arrives.

## Device

- `GET /v1/device`
- `GET /v1/preview.png`
- `POST /v1/display/mode` with `{"mode":"dashboard|claude|codex"}`
- `POST /v1/display/refresh` with `{"kind":"smart|partial|full"}`
- `PUT /v1/config/bridge` with `{"bridge_url":"http://host:8765"}`

No endpoint accepts or returns OAuth tokens or raw session logs.
