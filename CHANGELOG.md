# Changelog

All notable changes to elink-ai are documented in this file.
The sections should follow the order `Packaging`, `Added`, `Changed`, `Fixed`,
and `Removed`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 0.1.21-rc1

### Added

- The panel now has a theme you can switch in settings. The new default,
  `washi`, is a warm paper-and-ink palette; the previous purple scheme is kept
  as `violet` and reproduces its old colours exactly. The choice is remembered
  across restarts.

### Changed

- The mesh detail page draws latency and reachability as a single chart instead
  of a strip above a line. Each five-minute bucket gets its own min–max bar, so
  a one-off spike stays inside the five minutes it happened in instead of
  smearing into a hill across neighbouring buckets.
- The latency axis is logarithmic. A single 481ms spike used to squash the
  everyday 10–35ms range into the bottom twentieth of the plot, which is
  precisely where the jitter you are looking for lives.
- Packet loss is drawn along the baseline at a height that follows how much was
  lost, so a node that drops one probe every five minutes no longer looks as
  serious as one that is genuinely down.
- The lighthouse-side latency is collapsed by default behind a toggle. The
  local view answers "can I reach it and how fast", which is the question you
  ask first; the far side is a follow-up and used to cost a second full-height
  chart per node.

### Fixed

- Warning and error colours in light mode sat at 2.2:1 against the panel
  background, below any readable threshold. Every status colour now clears
  4.2:1 in both light and dark mode.
- Buttons drew white text on hover regardless of the hover fill, so a light
  theme produced light-on-light text.
- The segmented control kept the system blue and stayed visually detached from
  the rest of the panel.
- The 7-day progress bars on the Claude and Codex cards were misaligned by
  10pt whenever one provider had no active 5-hour window.

## 0.1.20

### Changed

- The e-paper screen now marks usage as `STALE` rather than `ERROR` when the
  quota API is unreachable but the cached percentages are still trustworthy, and
  reserves the inverted badge for things that actually need attention. An error
  with no usable figures behind it still reads `ERROR`.
- The Raspberry Pi agent versions independently of the macOS app, starting at
  0.1.13, so the version shown on screen and by `/v1/device` identifies the code
  actually deployed.

### Fixed

- The menu bar stopped responding after a couple of hours while the HTTP service
  kept answering normally. Each timed-out `ps`/`lsof` probe stranded a dispatch
  thread for good; once 64 were gone, everything scheduled on a global queue
  starved and the app could not recover without a restart.
- Update checks could hang permanently. The GitHub CLI fallback waited for the
  process to exit before reading its output, so enough output on either pipe
  deadlocked both sides — and because the in-flight guard never cleared,
  every later check was refused for the life of the process.
- Claude usage could stay rate limited indefinitely. The response headers were
  discarded, so a `Retry-After` of 414 seconds went unseen and the fixed backoff
  retried every 360 seconds — always inside the window the server had asked us
  to wait out. Backoff now follows what the server asks for.

## 0.1.20-rc4

### Added

- E-ink dashboard updates now support bounded dynamic session and event rows,
  region refresh telemetry, and Linux TUI release artifacts for arm64 and
  amd64.

### Changed

- The display agent exposes refresh duration, BUSY wait, refresh counters, and
  planned area to support hardware soak validation.

### Fixed

- Dynamic provider status and session content stays inside fixed dashboard
  regions, preserving the full-frame fallback and privacy bounds.

## 0.1.20-rc3

### Fixed

- Codex showed no cost in any range, despite months of recorded usage. The
  history backfill wrote only this Mac's own table, while a paired Mac reads the
  cluster one — so a provider that happened to be idle today never landed there
  at all. The backfill now fills both, and databases from the previous build are
  rebuilt once on launch to pick up what they are missing.

## 0.1.20-rc2

### Fixed

- The week, month, and year cost no longer stops at today. The breakdown behind
  it was only recorded going forward while token totals were backfilled, so a
  wider range showed the same figure as Day — reported from a build where both
  read $41.97 against token counts that differed ninefold. History is now
  backfilled from the session logs alongside the totals.
- In a cluster the cost covered only this Mac while the tokens above it covered
  every host. Both now read the same set of machines.
- The cost says how much of the range it actually covers whenever some usage has
  no breakdown behind it — a host still on an older build sends none, and its
  usage would otherwise go missing from the total without a word.

## 0.1.20-rc1

### Added

- Usage now shows what it would have cost at list API prices, both in the
  macOS stats panel and in the terminal dashboard. The figure is a conversion,
  not a bill — subscription usage is not charged per token — and models with no
  published price are named rather than counted as zero.
- Prices are built in for the current Claude and Codex models and can be
  overridden with a `pricing.json` next to the usage database, so a rate change
  or a new model does not have to wait for a release.

### Changed

- Daily usage is now also recorded per model *and* category, which is what makes
  a cost possible: the rate depends on both, and output runs five times input
  while a cache read costs a tenth of it.
- Cluster snapshots carry that breakdown so each host can price the others'
  usage. Amounts never cross the network — every node converts with its own
  price table — and snapshots from older hosts no longer look like empty ones.

## 0.1.19

### Fixed

- The app no longer crashes after a few minutes of running. The NAT probe
  contacted each STUN server twice per round and aborted the whole app when
  the second attempt lost a packet, which it eventually always did.

## 0.1.18

### Added

- Each host in a sync cluster now has its own colour in the usage device
  share, kept consistent across ranges and across machines

### Changed

- The usage statistics `Day` range now splits by host like the other ranges:
  snapshots carry the day's hour-by-hour distribution between hosts. A host
  still on an older version keeps syncing and simply contributes no hourly
  detail, reported as unknown rather than as zero
- The device share now appears whenever the cluster has more than one host,
  even when a single machine did all the work, instead of disappearing and
  leaving the host filter above it unexplained

### Fixed

- The bridge no longer re-reads the whole day's Claude transcripts every five
  seconds. It used around 14% of a CPU core continuously with nothing to
  report, climbing through the day as transcripts grew; a pass now costs
  whatever was appended since the last one
- A host that upgrades and then stays idle now still publishes the hourly
  distribution it had already collected that day

## 0.1.17-rc9

### Added

- The Nebula overlay page opens with a summary of what broke and when, sorts
  nodes by severity so a down host is never buried below healthy ones, and
  prints outage spans as clock times next to each node
- The usage statistics `Day` range now shows the host filter and the per-device
  share, matching the other ranges

### Changed

- Nebula overlay nodes collapse to a summary row by default; expanding one
  shows its latency charts, which now label their own axis range
- Occasional single-packet loss is drawn as a thin mark instead of filling its
  cell, so a real outage stands out against normal background loss

### Fixed

- A lighthouse serving implausible values can no longer crash the app: roster
  and history documents are now bounded where they are parsed
- The Raspberry Pi agent no longer accepts an arbitrary bridge address from the
  network, rejects redirects to other hosts, applies the minimum refresh
  interval to manual refreshes, and bounds concurrent connections
- A lighthouse with no configured listen address now binds its own overlay
  address instead of every interface; the roster names every node and its WAN
  mapping and is served without authentication
- The example LaunchAgent writes its log under `~/Library/Logs` instead of a
  fixed name in the shared `/tmp`

## 0.1.17-rc7

### Changed

- Nebula overlay history now includes a one-hour range and opens with that
  range selected by default

### Fixed

- Nebula overlay history now refreshes while its page remains open
- The two Agent Sessions summary cards now keep matching heights when
  collapsed

## 0.1.17-rc6

### Packaging

- Linux releases now include an `amd64` `elink-tui` archive alongside the
  existing `arm64` archive

### Changed

- Nebula overlay history now opens inside the menu-bar panel instead of a
  separate window

## 0.1.17-rc5

### Added

- macOS now opens a dedicated Nebula history window with 6-hour, 24-hour, and
  7-day views of latency, packet loss, and missing probe intervals
- `elink-tui --headless` now retains five-minute lighthouse probe history so
  macOS can compare local and lighthouse views of past tunnel outages

## 0.1.17-rc4

### Added

- macOS and `elink-tui` now show the Nebula overlay with per-host reachability,
  latency history, outage markers, and lighthouse-assisted tunnel diagnosis
- STUN checks now report the current external endpoint and whether NAT preserves
  or rewrites the local source port
- `elink-tui --headless` can expose Nebula lighthouse observations so clients
  can compare remote activity with their own overlay reachability

## 0.1.17-rc3

### Added

- Multi-Host Sync nodes in the macOS settings can now be expanded to show
  their connection address, node ID, and recent connection timestamps

### Changed

- Multi-Host Sync and related documentation now consistently use host
  terminology for both macOS and Linux machines

## 0.1.17-rc2

### Fixed

- macOS launch-at-login now follows the currently installed application after
  upgrades, preventing an older copy from starting after reboot
- Agent Sessions now recognizes running Claude Code processes for project
  paths containing dots, underscores, or other punctuation, so their pet and
  live state display correctly

## 0.1.17-rc1

### Changed

- The macOS Agent Sessions card now starts collapsed and can be expanded or
  collapsed from its header

### Fixed

- The menu-bar panel now stays anchored below its status item and keeps its
  header and footer visible when dashboard content exceeds the screen height
- Usage-statistics range controls now remain inside the card at narrow widths
  and with English labels

## 0.1.16

### Added

- The macOS panel now lists live Claude Code and Codex terminal sessions with
  working, idle, and finished states plus collapsible subagents
- Usage statistics now include an hourly day view and token category breakdown
- The macOS interface can switch between Chinese and English
- The macOS cluster panel can copy a generated pairing code with one click

### Changed

- Cluster UI text now refers to hosts instead of Macs so Linux TUI peers are
  represented accurately

### Fixed

- `elink-tui` cluster JSON now uses the Swift protocol's `ID` field spelling,
  restoring pairing and synchronization with the macOS app while accepting
  the previous TUI spelling when reading data

## 0.1.16-rc2

### Added

- The macOS panel now lists live Claude Code and Codex terminal sessions with
  working, idle, and finished states plus collapsible subagents

## 0.1.16-rc1

### Added

- The macOS cluster panel can copy a generated pairing code with one click

### Changed

- Cluster UI text now refers to hosts instead of Macs so Linux TUI peers are
  represented accurately

### Fixed

- `elink-tui` cluster JSON now uses the Swift protocol's `ID` field spelling,
  restoring pairing and synchronization with the macOS app while accepting
  the previous TUI spelling when reading data

## 0.1.15

### Packaging

- GitHub Releases now include an `elink-tui` Linux binary for `arm64`

### Added

- `elink-tui`: a keyboard-driven Linux terminal dashboard (Rust) mirroring the
  macOS cards — working/idle/offline state, today's per-model tokens, and
  5-hour/weekly quota bars with reset countdowns. It reads `~/.claude` and
  `~/.codex` locally (with statusline-cache and session-log quota fallbacks)
  or polls a mac-app bridge remotely, switchable at runtime
- `elink-tui` local mode accepts the bridge's `POST /v1/event` hook requests,
  enabling live working/idle transitions and permission-request alerts from
  the existing hook scripts
- `elink-tui` caches the last fetched quota in its private SQLite usage store
  so usage bars appear immediately after
  a restart, and quota fetches run off the poll loop so the dashboard stays
  live during slow networks
- `elink-tui` usage-history page (`s`): daily token charts and per-model
  totals over week/month/year ranges, backfilled from existing session logs
  and persisted to `~/.local/state/elink-ai/usage.db`
- `elink-tui` serves its local snapshot on `GET /v1/status` in the bridge
  wire format, so a Raspberry Pi agent can use a Linux machine as its data
  bridge
- `elink-tui` device page (`d`): live e-paper preview rendered in the
  terminal, display-mode switching, smart/full refresh, and one-key
  "use this machine as the data bridge"
- `elink-tui` update check (`u`) against GitHub Releases with a `gh` CLI
  fallback for private repositories, a `--compact` one-line output for
  tmux/waybar status bars, and a terminal title showing the worse weekly
  quota percentage
- `elink-tui` cluster statistics can cycle between all nodes and a single
  node, with per-node token shares in the aggregate view
- `elink-tui` advertises and discovers same-cluster mac-app/TUI peers over the
  shared `_elink-ai._tcp` mDNS service when its bridge listens on the LAN

### Changed

- `elink-tui` quota, history, timezone metadata, and encrypted cluster state
  now share `~/.local/state/elink-ai/usage.db`; previous JSON stores are
  imported once without deleting the recoverable source files
- Usage-history timezone changes now rebucket data and advance the timezone
  marker atomically while conserving usage no longer reconstructable from logs

### Fixed

- macOS cluster discovery now ignores co-located bridges to prevent the same
  machine's usage from being counted twice

## 0.1.15-rc1

### Packaging

- Release candidates are published through GitHub's prerelease channel while stable tags remain regular releases

### Fixed

- Codex subagent token counts logged before model metadata were attributed to `unknown`; existing usage history is rebuilt once to correct the model attribution

## 0.1.14

### Changed

- Multi-Mac pairing now uses high-entropy 16-character codes and authenticated key exchange, with explicit errors for clients using the retired pairing protocol

### Fixed

- Raspberry Pi refresh failures stopping polling, dropping queued refreshes, or reporting successful panel updates as failed when only preview or state persistence failed
- Multi-Mac synchronization races leaving stale credentials or usage data, recording failed pulls as successful, and requiring the statistics view to be reopened before changes appeared
- Usage history and cluster snapshot writes partially committing or crashing the app on database errors, plus time-zone migrations mishandling equivalent zone aliases and deleted-log residue
- Claude Code hook settings being written with permissions that were broader than owner-only access
- Claude and Codex provider cards having uneven heights in the usage panel

## 0.1.13

### Added

- Per-Mac token shares and model usage in cluster statistics, including breakdowns for the hovered day or month

## 0.1.12

### Packaging

- macOS app and Raspberry Pi agent versions are aligned at 0.1.12 for clearer deployment identification

### Added

- Running Raspberry Pi agent version in the e-paper footer and macOS device status

## 0.1.11

### Fixed

- E-paper refreshes staying unchanged indefinitely, blocking local APIs while the panel was busy, or dropping refresh and display-mode requests that arrived during an in-progress update
- Multi-Mac daily usage and chart labels drifting across time zones, and statistics remaining filtered to a Mac after that node left the cluster
- Transient empty log or quota responses clearing previously recorded usage, along with cluster synchronization races and acceptance of remote snapshots claiming the local Mac's identity
- Malformed or slow HTTP clients crashing or holding bridge and agent connections open indefinitely
- Claude Code hooks missing permission and elicitation events, and hook installation failing on empty, null, malformed, or non-object settings and event payloads

## 0.1.10

### Packaging

- CI and Universal macOS releases now run on the project's self-hosted Mac mini, with explicit `arm64` and `x86_64` architecture verification

### Fixed

- Menu-bar weekly usage not reflecting the combined usage from paired Macs
- Claude HTTP 429 responses appearing as a persistent update failure instead of showing cached status or the quota reset time
- E-paper usage percentages above 100% being capped at 100% even though the macOS app showed the exact value

## 0.1.9

### Changed

- Settings cards now left-align consistently, with expand chevrons moved to the trailing edge of the header row

### Fixed

- Claude usage never updating when Claude Code authenticates via the CLAUDE_CODE_OAUTH_TOKEN environment variable instead of a credentials file or the Keychain
- The bridge silently running without its HTTP server when port 8765 was still held by an old instance during a restart; the listener now logs the failure and retries

## 0.1.8

### Added

- Setting to disable the e-paper device connection entirely

### Fixed

- Multi-Mac Sync feedback keeping a stale "sync failed" message after the underlying error had actually recovered

## 0.1.7

### Fixed

- Single-node Multi-Mac Sync settings hiding the address and pairing-code fields needed to join an existing cluster

## 0.1.6

### Packaging

- Distribute the macOS app as a Universal Binary for Apple Silicon and Intel Macs

### Fixed

- Application failing to launch on Intel Macs because the release binary only supported `arm64`

## 0.1.5

### Added

- Encrypted peer-to-peer usage aggregation across paired Macs on the same LAN or VPN

### Fixed

- Multi-Mac pairing and persisted sync state handling
- Software update card only responding to clicks on part of its surface
