# HTTP protocol v1

The host bridge listens on TCP 8765 and the Raspberry Pi agent listens on TCP
8766. Both are plain HTTP services intended for a trusted LAN.

## Bridge

`GET /v1/status` returns `schema_version`, epoch timestamps, and `claude` and
`codex` objects. Unknown percentages and reset times are JSON `null`, never
zero. Each provider may also include `model_usage_today`, sorted by descending
token count, as objects containing `model` and `tokens`. See
`fixtures/status-v1.json` for the complete shape.

Each provider may also carry five additive fields. `scoped_limits` lists limits
that apply to a single model (`id`, `title`, `pct`, `reset_min`) — these sit
*inside* the account-wide window rather than replacing it, so a model can be
exhausted while the account total still has room. `extra_usage` describes the
pay-as-you-go pool on top of the subscription (`used`, `limit`, `pct`, `unit`);
it is `null` when the account has no such pool, which is different from a pool
that is merely unused. `unit` is either an ISO currency code or the literal
`credits`: Claude's pool is money, Codex's spend-control limit is counted in
credits, and rendering credits with a currency symbol calls them money. Amounts
are already converted — the producer does the minor-unit shift once so every
client agrees on the decimal point. `credit_balance` is the credits still on the
account; `null` means no credit pool at all, which is not the same as a balance
of zero. `cost_today` and `unpriced_models` report today's usage priced at list API
rates; this is not a bill, since the usage runs on a subscription, and clients
must word it as a conversion. Models with no published price are named in
`unpriced_models` rather than counted as zero, so a partial total is never read
as the whole. Older producers omit all five, and clients must treat that as
"no scoped limits", "no pool", "no credits", and "no cost figure" respectively.

The optional additive `current_sessions` array contains at most three display
summaries with `id`, `provider`, `project`, `model`, `state`, and `updated_at`.
The optional `recent_events` array contains at most three state transitions
with `id`, `provider`, `kind`, and `occurred_at`; `kind` is `working`, `idle`,
or `needs_input`. Session IDs are opaque, projects are basename-only, and
neither array carries prompts, transcript text, full paths, credentials, or
tool output. Older producers may omit both arrays and clients must treat that
as an empty list.

When Multi-Host Sync is enabled, token/model fields contain the sum of all known
node snapshots. The additive `cluster` object reports `enabled`, `node_count`,
`online_count`, and `last_synced_at`. Existing v1 clients may ignore it.

The `cluster` object describes usage synchronization only. It carries no network
quality, and deliberately so: its members are the few hosts that run this app and
have paired, which is a different and much smaller set than the devices on the
nebula overlay. A `link` field once reported a round trip measured on the
15-second peer sync; it was removed because that figure included peer processing
time and, for Bonjour-discovered peers, travelled the LAN rather than the tunnel
it appeared to describe. Overlay reachability and latency now come from ICMP
against overlay addresses — see `elink-tui --headless` and the mesh view.

Node names are the only identifier published here. Overlay addresses and ports
stay on the observing host, because port 8765 is unauthenticated: exposing them
would publish internal network topology to anything that can reach the bridge.

`POST /v1/event` accepts:

```json
{"agent":"claude","event":"PreToolUse"}
```

Supported lifecycle events update working/idle state. `PermissionRequest` and
`Elicitation` set the attention flag for five minutes or until another concrete
lifecycle event arrives. Repeated hook events in the same state do not append
new recent-event entries.

## Device

- `GET /v1/device`
- `GET /v1/preview.png`
- `POST /v1/display/mode` with `{"mode":"dashboard|claude|codex"}`
- `POST /v1/display/refresh` with `{"kind":"smart|partial|full"}`
- `PUT /v1/config/bridge` with `{"bridge_url":"http://host:8765"}`

`GET /v1/device` reports the operation that actually reached the panel in
`last_refresh_kind` (`full`, `fast-full`, or `region`), rather than echoing the
requested kind. `last_refresh_region_count`, `last_refresh_area`, and
`last_refresh_reason` describe the selected frame-diff plan. `partial_count`
counts successful non-full operations. A `smart` request may perform no panel
operation when the rendered frame is unchanged; `partial` may safely fall back
to a full operation when there is no trusted displayed-frame baseline.

When the optional `[monitor]` idle screen is enabled, `content` is `"monitor"`
while the panel shows the device-monitor page and `"ai"` while it shows the
AI dashboard; `monitor.enabled`, `monitor.idle_after_s`, and `monitor.idle`
report whether the feature is on, the idle threshold, and whether the panel
currently sits on the monitor page. The monitor page is an idle fill-in, not a
new selectable `mode` — `mode` stays `dashboard|claude|codex`.

No endpoint accepts or returns OAuth tokens or raw session logs.

## Host peer sync protocol v2

Host bridges advertise `_elink-ai._tcp` over Bonjour. TXT records contain only
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
support individual-node revocation. To exclude a previously trusted host,
create a new cluster and pair the remaining hosts again.

Snapshots are absolute, not deltas. Receivers replace a source/day/provider
only when its revision increases, so retries, relay through another host, and
out-of-order delivery are idempotent. Offline nodes' last synchronized values
remain part of aggregate history.

Besides the required `models` map, a snapshot may carry two optional
breakdowns: `hours` (`"0"`…`"23"` → model → tokens) and `categories` (model →
`input`/`output`/`cache_read`/`cache_write`/`reasoning` → tokens). The latter
is what lets a receiver price another node's usage, since a rate depends on
both the model and the category. For both, a missing field and an empty object
mean different things: missing is "the sender did not say" and must leave any
previously stored breakdown intact, while an empty object means "there was
none that day". Conflating the two lets one sync from an older node erase a
breakdown that had already been received.

Monetary amounts are never transmitted. Each node converts usage with its own
price table, so hosts need not agree on prices — and a node that cannot price
a model reports it as unpriced rather than counting it as zero.

The content hash covers `models` only. Folding either breakdown into it would
make different versions compute different hashes for identical usage, so they
would never agree on what to pull. Receivers must also ignore snapshot fields
they do not recognize, which is what keeps a mixed-version cluster in sync when
one host upgrades first. `elink-tui` currently sends and consumes neither
breakdown; it stays interoperable by ignoring both.
