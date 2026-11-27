# Changelog

All notable changes to elink-ai are documented in this file.
The sections should follow the order `Packaging`, `Added`, `Changed`, `Fixed`,
and `Removed`.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## 0.1.23

### Changed

- The e-paper `dashboard` layout now displays Claude, Codex, and Gemini
  together as three equal horizontal telemetry strips, with fixed status badges
  and session/event rows on the left, primary and weekly quota bars in the
  center, and today's tokens with a fixed 4-row model breakdown on the right.
  Gemini labels its primary quota as `PRIMARY WINDOW` rather than hardcoding
  5 hours, and single-provider modes keep their full-card layout.
- The e-paper `dashboard` mode now includes Gemini in active-provider wakeups,
  approval attention interrupts, and refresh signatures; the Mac app's mode
  selector and device summary rename `Dual` to `Overview` while preserving
  `dashboard` on the wire.

### Fixed

- Switching between single-provider e-paper modes with identical idle status
  now refreshes immediately instead of waiting out the throttle interval,
  transitions between `ERROR` and cached `STALE` states are detected in the
  refresh signature, and session age suffixes are preserved when long project
  or model names are truncated on the strip.

## 0.1.22

### Added

- Agent Sessions in the Mac app now displays per-session live metrics (latest
  context tokens, context window utilization, cache hit rate, and estimated API
  cost) for Claude Code, Codex, Gemini CLI, and Antigravity sessions, and opens
  an interactive Session Detail inspector with a 2×2 metric matrix, context
  progress bar, and scrollable latest-80 By Step call table with anomaly badges
  (`Low Cache`, `Slow`, and `Compaction`).
- Usage Statistics in the Mac app now shows host-filtered cache hit rate and
  net API cache savings (deducting cache-write premiums), plus a 366-day
  calendar heatmap in the Year view.
- Added `mcp/elink-mcp.py`, a zero-dependency stdio MCP server exposing the
  `get_usage_limits` tool so Claude Code, Codex, and the Antigravity CLI can
  query current provider quotas, reset times, scoped limits, and extra usage
  from the elink-ai bridge.

### Fixed

- Cluster aggregation in the Mac app now recomputes reset countdowns for remote
  nodes' model-scoped quota limits and drops expired entries instead of keeping
  stale minutes from the previous sync.

## 0.1.21

### Added

- Agent Sessions now shows recent output speed (`tok/s`) for Gemini CLI and
  Antigravity (`agy`) sessions alongside Claude Code and Codex. Gemini CLI
  counts both output and thinking tokens across tool-call turns, and
  Antigravity retains per-turn completion timestamps so multi-turn text
  conversations keep showing output speed.
- First stable release promoting the `0.1.21-rc1` through `0.1.21-rc19`
  milestones, including Gemini CLI and Antigravity provider tracking across the
  Mac app, Linux TUI, e-paper display, and cluster sync, signed in-app macOS
  updates, self-updating Raspberry Pi agent packages, and editable VPS server
  monitoring.

## 0.1.21-rc19

### Added

- Gemini is now a third provider next to Claude and Codex. The Mac app shows
  today's Gemini tokens and API cost, and lists running Gemini CLI and
  Antigravity (`agy`) sessions. It also shows Gemini's 5-hour and weekly
  limits when a source provides them: either the quota API, using your
  Gemini CLI login, or the Antigravity CLI's statusLine cache, written by
  `hooks/antigravity-statusline.sh`. Use the cache if the quota API rejects
  your account, as it can for personal accounts. Each refresh uses one
  source, so a window it does not report stays empty rather than being
  filled from the other. The menu bar's weekly figure includes Gemini.
- The Linux TUI gains a Gemini card, shown only when there is Gemini
  activity, so 80×24 terminals keep the two-column layout otherwise.
- The e-paper device has a new `gemini` display mode.
- Cluster sync carries Gemini usage between nodes on this version. Older nodes
  keep syncing Claude and Codex as before.

### Changed

- The e-paper device only wakes for approvals and activity from the providers
  its current mode shows: Claude and Codex on the dashboard, or the one
  provider in a single-provider mode. A waiting approval it cannot display no
  longer pulls the panel off the monitor page.

## 0.1.21-rc18

### Packaging

- Each release now includes the device agent package
  `elink-agent-vX.Y.Z.tar.gz` and its Ed25519 signature
  `elink-agent-vX.Y.Z.tar.gz.sig`. The agent version now follows the release
  version, so the e-paper footer shows the same version as the Mac app.

### Added

- The Raspberry Pi agent can update itself: `elink-agent-update.timer` checks
  GitHub Releases 10 minutes after boot and every 6 hours, installs a newer
  signed agent, restarts it, and rolls back if the new version does not come
  up. A rolled-back version is not retried automatically, and no update runs
  while the agent is stopped. To enable it, re-run
  `sudo sh install/install-pi.sh` from this version once, then
  `sudo systemctl restart elink-agent`. While the repository is private, put
  `GITHUB_TOKEN=<read-only token>` in `/etc/elink-ai/update.env`, owned by
  root with mode 0600.

## 0.1.21-rc17

### Packaging

- Each release now includes `elink-ai-vX.Y.Z.zip` and its Ed25519 signature
  `elink-ai-vX.Y.Z.zip.sig` for in-app updates. The DMG is still provided
  for manual installation, and `elink-ai-vX.Y.Z.dmg.sig` is no longer
  published.

### Fixed

- “Update and Relaunch” no longer fails with a permission error on the
  `mount` folder. macOS does not let the app read a mounted disk image, so
  updates are now installed from the signed zip. In-app updates did not work
  in 0.1.21-rc16: install this version manually once, and later versions can
  update from within the app.

## 0.1.21-rc16

### Packaging

- Each release now includes `elink-ai-vX.Y.Z.dmg.sig`, an Ed25519 signature
  of the DMG used by in-app updates.

### Added

- Software Update can now install a new version in place: click
  “Update to vX and Relaunch” and Elink AI downloads the release, verifies its
  signature, replaces the app and reopens it. If the update cannot be installed
  automatically, the reason is shown and the DMG download remains available.
  This version must be installed manually once; later versions can update
  from within the app.

## 0.1.21-rc15

### Fixed

- In single-provider mode, the e-paper dashboard's large five-hour usage
  percentage now stays fully above its progress bar instead of having its
  lower edge covered by the bar.

## 0.1.21-rc14

### Fixed

- Codex quota windows that have not started now show “No active window”
  instead of a reset countdown that returns to nearly seven days on every
  refresh. Active windows still show their reset time when usage rounds to 0%.
- Reset countdowns from cached usage and other hosts now decrease with time,
  even between quota refreshes.

## 0.1.21-rc13

### Added

- Servers can be edited after they are added. Rename a server from the pencil
  next to its name on the Servers page or in VPS Monitoring settings, and
  replace its API key in settings; a new key is validated with KiwiVM before
  it is saved. Renaming never calls KiwiVM.

### Changed

- The receipt's top edge now tears like real paper, with an irregular edge
  that matches the stub left in the printer. A torn-off receipt stays inside
  the panel while you hold it and when you let go.

### Fixed

- Printing a receipt is smooth instead of feeding out in jerky steps, and
  dragging to tear it no longer stutters.

## 0.1.21-rc12

### Added

- After tearing off a usage receipt, a share page shows the receipt image
  with buttons to share it through the system share sheet, copy it again,
  show it in Finder, or print another.

### Changed

- Tearing the receipt now looks like tearing real paper: pull down and to one
  side and the tear runs along the cutter from the opposite edge, leaving a
  jagged stub in the printer. Once it comes loose the receipt follows the
  pointer and flies off when released, and it is no longer clipped while it
  tilts.

## 0.1.21-rc11

### Added

- The menu-bar panel can print a combined Claude and Codex usage receipt for
  today, the last 7 or 30 days, or the last 12 months. It lists the
  API-equivalent cost per client and model, token totals, cache hit rate and
  session count. The receipt feeds out of a printer slot; pull it down to tear
  it off, and it is copied to the clipboard and saved to Downloads as an image.

### Fixed

- Usage costs now price Claude Opus 5.5, GPT-6 Sol, GPT-6 Astra and GPT-5.6
  Luna, which were previously left out of the totals, and use the current
  published rates for Claude Sonnet 5 and GPT-5.6 Sol.

## 0.1.21-rc10

### Added

- Each agent session and subagent row in the menu-bar panel shows the output
  rate of its recent model responses (for example `62 tok/s`), so slow models
  are easy to spot.
- The e-paper device can show an instant feedback toast in its top-right
  corner through `POST /v1/display/toast`, so input no longer looks ignored
  while a multi-second full refresh is pending.

### Fixed

- The menu-bar app no longer uses sustained CPU in the background. Session
  scans skip transcripts that are too old to show and reuse parsed results
  for files that have not changed, and Codex usage rereads only the log files
  that actually changed instead of every file written that day.
- Status requests and hook events no longer stall behind usage-log parsing.

## 0.1.21-rc8

### Changed

- The e-paper AI dashboard and device-monitor page now share a PocketJS-inspired
  mission-control design, with stronger numeric hierarchy, compact telemetry
  modules, pill-shaped status and progress treatments, and solid 1-bit depth.
  Every dynamic element remains inside its existing fixed refresh region.

### Fixed

- The device-monitor address line wraps whole interface/address pairs onto its
  reserved second line instead of clipping the final interface when a device
  has several LAN, overlay, or container-network addresses.

## 0.1.21-rc7

### Added

- The device-monitor page lists every network interface the device has an
  address on, so a machine that is also on an overlay network shows both its
  LAN and overlay addresses instead of only the one its default route uses.
  The device API reports the same list.
- The monitor page's timestamp carries seconds, so a page that updates every
  few seconds no longer looks frozen between minute boundaries.
- The menu-bar panel says which page the e-paper is actually showing. While
  the panel sits on the device monitor the card reports that instead of the
  usage layout, which is what the picture beside it was already showing.

### Changed

- Once the monitor page reaches the panel it stays for a minimum dwell, so
  intermittent AI activity no longer flips the screen back and forth, at two
  full refreshes a time. A pending permission request still switches back
  immediately.
- An optional `[display] keep_awake_s` lets the panel stay initialised between
  dense refreshes, taking a region refresh from about 1.25s to about 0.47s.
  It defaults to off, and the window is bounded so the panel is never left
  powered indefinitely.

### Fixed

- A monitor update repainted the whole screen once a minute. The change was
  2.6% of the pixels; the frame differ collapsed every scattered edit into one
  bounding box and crossed its escalation threshold. Nearby edits now merge
  pairwise, and when that would still cross the threshold the update spends a
  few more windows rather than repainting everything.
- Only one region of a partial refresh ever reached the panel: each window
  overwrote the previous one's coordinates before a single refresh command.
  Every window now gets its own refresh cycle, which is what made the seconds
  on the monitor page stand still until a full refresh.
- The monitor page no longer waits out a coalescing window meant for pages
  that repaint on data changes, and the main loop wakes often enough for the
  configured cadence to mean what it says.

## 0.1.21-rc6

### Added

- When AI usage goes idle, the e-paper panel now flips to a device-monitor
  page and flips back the moment a session starts. It leads with CPU load,
  usage, and a trend of the last 30 samples, then memory, disk, temperature,
  and network rates, and closes with the panel's own refresh health, the
  hostname, and the device's IP address.
- The device API reports the device's IPv4 address on its default route in
  `ip_address`, so a client can find the panel without reading the screen.

### Changed

- The monitor page is grouped by hairlines drawn between its boxes instead of
  a border around each card, which keeps a steady-state tick to a region
  refresh of well under 1% of the screen rather than repainting a whole card.
- The CPU trend scales to its own peak, so an idle device shows a readable
  chart instead of a flat line at the bottom of the axis.

## 0.1.21-rc5

### Added

- The macOS panel can monitor Bandwagon VPS instances through KiwiVM. The main
  page shows state, memory, disk, and monthly traffic at a glance, while a
  read-only detail page includes load, addresses, SSH port, OS, and the traffic
  reset date. API credentials are validated before being stored locally.
- An optional LaunchAgent helper can anchor Claude's rolling five-hour window
  to chosen workday boundaries by sending a minimal Haiku message only when no
  window is active.

### Fixed

- Expired Claude credentials are now renewed by delegating to the installed
  Claude CLI, avoiding stale usage data while an otherwise idle Claude session
  is open and leaving refresh-token rotation to its owner.
- Copy, cut, paste, and select-all keyboard shortcuts work again in the
  menu-bar panel's token, pairing, cluster, and lighthouse text fields.

## 0.1.21-rc4

### Packaging

- The installer is built with `hdiutil create` instead of a makehybrid and
  convert pair, and extended attributes are stripped before imaging. The
  previous route produced a disk image whose signature no longer verified.

### Added

- The Claude and Codex cards show the pay-as-you-go pool that sits on top of
  the subscription: a bar, the month's spend against the cap, and the percent
  used. Codex spend limits are counted in credits and are never shown with a
  currency symbol, and the Codex credit balance appears when the account has
  one.
- Limits that apply to a single model now get their own bar under the
  account-wide weekly one — Claude's per-model weekly allowances and Codex's
  additional rate limits such as Codex Spark. A model can be exhausted while
  the account total still has room, and that is now visible at a glance.
- Each card carries a cost line for today and the trailing 30 days. This is
  what the same usage would have cost at list API rates, not a bill: the usage
  runs on a subscription. Models with no published price are flagged rather
  than counted as zero.
- The bridge publishes the new figures, so the terminal dashboard and the
  e-paper agent read the same numbers. All fields are additive and older
  clients are unaffected.

### Fixed

- An expired Codex login is now recognised from the credential itself instead
  of being spent on a request that can only fail. The card falls back to the
  windows recorded in session logs and says the login expired, rather than
  reporting a usage endpoint error every two minutes.
- Claude usage requests identify themselves as Claude Code, which is the
  client that endpoint serves.
- Claude's extra-usage amounts are scaled by the precision the API reports.
  Read verbatim, a $100 cap would have been displayed as $10000.

## 0.1.21-rc3

### Added

- Elink can validate and store a dedicated long-lived token generated by
  `claude setup-token` in the macOS login Keychain. The settings panel uses a
  secure field and can replace, repair, or remove only Elink's own credential.

### Fixed

- Claude usage updates no longer depend on credentials inherited by a terminal
  process. Elink's credential takes priority while the existing Claude Code
  file, Keychain, environment, and login-shell discovery remain as fallbacks.
- Replacing a credential validates it against the Claude usage endpoint before
  overwriting the old Keychain item, rebuilds the item's access control, and
  can recover from a malformed stored value.
- A forced refresh requested while an older credential request is in flight
  now schedules a second fetch before completing, so stale 401 or 429 results
  cannot overwrite a newly validated credential.

## 0.1.21-rc2

### Fixed

- The Claude usage card now skips expired or malformed file credentials and
  falls through to the refreshed Keychain or login-shell token. If every
  source is exhausted, it reports the confirmed expiry instead of hiding it
  behind a Keychain error or repeatedly triggering API rate limits.

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
