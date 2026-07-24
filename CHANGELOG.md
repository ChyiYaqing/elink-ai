# Changelog

All notable changes to elink-ai are documented in this file.
The sections should follow the order `Packaging`, `Added`, `Changed`, `Fixed`,
and `Removed`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
