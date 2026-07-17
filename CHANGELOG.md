# Changelog

All notable changes to elink-ai are documented in this file.
The sections should follow the order `Packaging`, `Added`, `Changed`, `Fixed`,
and `Removed`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
