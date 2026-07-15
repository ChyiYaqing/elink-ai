# HTTP protocol v1

The Mac bridge listens on TCP 8765 and the Raspberry Pi agent listens on TCP
8766. Both are plain HTTP services intended for a trusted LAN.

## Bridge

`GET /v1/status` returns `schema_version`, epoch timestamps, and `claude` and
`codex` objects. Unknown percentages and reset times are JSON `null`, never
zero. Each provider may also include `model_usage_today`, sorted by descending
token count, as objects containing `model` and `tokens`. See
`fixtures/status-v1.json` for the complete shape.

When Multi-Mac Sync is enabled, token/model fields contain the sum of all known
node snapshots. The additive `cluster` object reports `enabled`, `node_count`,
`online_count`, and `last_synced_at`. Existing v1 clients may ignore it.

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

## Mac peer sync protocol v2

Mac bridges advertise `_elink-ai._tcp` over Bonjour. TXT records contain only
protocol version, node ID, cluster ID, and whether a two-minute pairing window
is open. VPN deployments may configure a peer address manually.

Pairing uses `POST /v2/cluster/pair/join`. A six-digit code authenticates an
ephemeral Curve25519 key agreement; the responder encrypts the cluster ID,
timezone, and random 256-bit cluster secret with AES-GCM. Pairing attempts are
limited to five per window.

After pairing, peer traffic uses these endpoints:

- `GET /v2/cluster/manifest` returns known `(origin_node_id, day, provider)`
  snapshot revisions and the sender's live provider state.
- `POST /v2/cluster/pull` returns up to 200 requested complete snapshots.
- `POST /v2/cluster/announce` asks a peer to reconcile immediately after local
  data changes; a full manifest comparison still runs every 15 seconds.

Every request carries the node ID, epoch timestamp, random nonce, and an
HMAC-SHA256 signature over method, path, timestamp, nonce, and body hash.
Requests outside a 60-second clock window or with a replayed nonce are rejected.
Sync request and response JSON is encrypted with AES-GCM using purpose-specific
keys derived from the cluster secret.

The node identity and cluster secret are stored in the bridge's local
`usage.db` SQLite database under the user Application Support directory. The
directory uses `0700` permissions and the database uses `0600`. Cluster
credentials are never stored in or read from macOS Keychain.

The first protocol version uses one shared secret for the cluster and does not
support individual-node revocation. To exclude a previously trusted Mac,
create a new cluster and pair the remaining Macs again.

Snapshots are absolute, not deltas. Receivers replace a source/day/provider
only when its revision increases, so retries, relay through another Mac, and
out-of-order delivery are idempotent. Offline nodes' last synchronized values
remain part of aggregate history.
