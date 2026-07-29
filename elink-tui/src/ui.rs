use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Bar, BarChart, BarGroup, Block, Clear, Paragraph, Sparkline};
use ratatui::Frame;

use crate::app::{App, View};
use crate::cluster::LinkSummary;
use crate::device::Preview;
use crate::model::{ProviderStatus, Snapshot};
use crate::source::local::history::{range_stats, RangeStats, StatsRange};
use crate::source::local::stun::StunObservation;
use crate::util::{epoch_now, format_age, format_minutes, format_tokens};

const STACK_BELOW_WIDTH: u16 = 70;

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let mut constraints = vec![Constraint::Length(1)];
    let show_banner = app.error.is_some();
    if show_banner {
        constraints.push(Constraint::Length(1));
    }
    constraints.push(Constraint::Min(0));
    constraints.push(Constraint::Length(1));
    let rows = Layout::vertical(constraints).split(area);

    frame.render_widget(header(app), rows[0]);
    let mut next = 1;
    if show_banner {
        frame.render_widget(banner(app), rows[next]);
        next += 1;
    }
    match app.view {
        View::Dashboard => draw_cards(frame, rows[next], app),
        View::Stats => draw_stats(frame, rows[next], app),
        View::Device => draw_device(frame, rows[next], app),
        View::Cluster => draw_cluster(frame, rows[next], app),
    }
    frame.render_widget(footer(app), rows[next + 1]);

    if app.show_help {
        draw_help(frame, area);
    }
}

fn header(app: &App) -> Paragraph<'static> {
    let updated = app
        .received_at
        .map(|at| format!("updated {} ago", format_age(at.elapsed().as_secs() as i64)))
        .unwrap_or_else(|| "waiting for data…".to_string());
    let quota = app
        .snapshot
        .as_ref()
        .and_then(|snapshot| snapshot.usage_fetched_at)
        .map(|at| format!("quota fetched {} ago", format_age(epoch_now() - at)))
        .unwrap_or_else(|| "quota —".to_string());
    let mut spans = vec![
        Span::styled(" elink-ai ", Style::new().bold()),
        Span::raw("─ "),
        Span::styled(app.kind.label().to_string(), Style::new().cyan()),
        Span::raw(format!(" ─ {updated} ─ {quota}")),
    ];
    if let Some(snapshot) = &app.snapshot {
        if let Some(cluster) = &snapshot.cluster {
            if cluster.enabled {
                spans.push(Span::raw(format!(
                    " ─ cluster {}/{}",
                    cluster.online_count, cluster.node_count
                )));
            }
        }
    }
    if let Some(update) = &app.update_available {
        spans.push(Span::styled(
            format!(" ─ ⬆ {} available", update.tag),
            Style::new().fg(Color::Yellow).bold(),
        ));
    }
    Paragraph::new(Line::from(spans))
}

/// One-line summary for `--compact` (tmux status line / waybar): state symbol
/// plus primary/weekly percentages per provider, `-` for unknown.
pub fn compact_line(snapshot: &Snapshot) -> String {
    fn part(tag: &str, provider: &ProviderStatus) -> String {
        let symbol = match provider.status.as_str() {
            "working" => "●",
            "idle" => "○",
            _ => "·",
        };
        let pct = |value: Option<f64>| {
            value
                .map(|value| format!("{value:.0}%"))
                .unwrap_or_else(|| "-".to_string())
        };
        let mut text = format!(
            "{tag}{symbol} {}/{}",
            pct(provider.primary_pct),
            pct(provider.weekly_pct)
        );
        if provider.needs_input {
            text.push_str(" ⚠");
        }
        text
    }
    format!(
        "{} | {}",
        part("C", &snapshot.claude),
        part("X", &snapshot.codex)
    )
}

/// Terminal-title equivalent of the menu-bar label: the worse weekly
/// percentage across providers.
pub fn terminal_title(snapshot: Option<&Snapshot>) -> String {
    let weekly = snapshot
        .into_iter()
        .flat_map(|snapshot| [snapshot.claude.weekly_pct, snapshot.codex.weekly_pct])
        .flatten()
        .fold(None::<f64>, |best, value| {
            Some(best.map_or(value, |best| best.max(value)))
        });
    match weekly {
        Some(percent) => format!("elink-ai {percent:.0}%"),
        None => "elink-ai".to_string(),
    }
}

fn banner(app: &App) -> Paragraph<'static> {
    let error = app.error.clone().unwrap_or_default();
    let suffix = if app.snapshot.is_some() {
        " — showing last data"
    } else {
        ""
    };
    Paragraph::new(format!(" ⚠ {error}{suffix}"))
        .style(Style::new().fg(Color::Red).add_modifier(Modifier::BOLD))
}

fn footer(app: &App) -> Paragraph<'static> {
    let keybar = match app.view {
        View::Dashboard => {
            " q quit  r refresh  ⇥ focus  s stats  c cluster  d device  u update  m mode  ? help"
        }
        View::Stats => " s back  w/m/y range  n source  ⇥ focus  q quit  ? help",
        View::Device => " d back  1/2/3 mode  p smart  f full  b bridge→here  q quit",
        View::Cluster => " c back  p pair  r sync  q quit  ? help",
    };
    let mut spans = vec![Span::styled(keybar, Style::new().dim())];
    if let Some(hint) = app.hint() {
        spans.push(Span::styled(
            format!("  ·  {hint}"),
            Style::new().fg(Color::Yellow),
        ));
    }
    Paragraph::new(Line::from(spans))
}

fn draw_cards(frame: &mut Frame, area: Rect, app: &App) {
    let stacked = area.width < STACK_BELOW_WIDTH;
    let areas = if stacked {
        Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)]).split(area)
    } else {
        Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(area)
    };
    let dimmed = app.error.is_some();
    for (index, name) in ["Claude", "Codex"].into_iter().enumerate() {
        draw_card(frame, areas[index], app, index, name, dimmed);
    }
}

fn draw_card(frame: &mut Frame, area: Rect, app: &App, index: usize, name: &str, dimmed: bool) {
    let provider = app.snapshot.as_ref().map(|snapshot| match index {
        0 => &snapshot.claude,
        _ => &snapshot.codex,
    });
    let focused = app.focus == index;
    let border_style = if focused {
        Style::new().fg(Color::Cyan)
    } else {
        Style::new().dim()
    };
    let mut title = vec![Span::styled(format!(" {name} "), Style::new().bold())];
    if let Some(provider) = provider {
        title.push(state_badge(&provider.status));
        if provider.needs_input {
            title.push(Span::styled(
                " ⚠ input ",
                Style::new().fg(Color::Black).bg(Color::Yellow).bold(),
            ));
        }
    }
    let block = Block::bordered()
        .border_style(border_style)
        .title(Line::from(title));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let Some(provider) = provider else {
        frame.render_widget(Paragraph::new(" …"), inner);
        return;
    };
    let mut lines = provider_lines(provider, index, inner, app.scroll[index]);
    if dimmed {
        for line in &mut lines {
            *line = line.clone().style(Style::new().dim());
        }
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

fn state_badge(status: &str) -> Span<'static> {
    match status {
        "working" => Span::styled("● working", Style::new().fg(Color::Green).bold()),
        "idle" => Span::styled("○ idle", Style::new().fg(Color::Yellow)),
        _ => Span::styled("○ offline", Style::new().dim()),
    }
}

fn provider_lines(
    provider: &ProviderStatus,
    index: usize,
    inner: Rect,
    scroll: usize,
) -> Vec<Line<'static>> {
    let width = inner.width as usize;
    let mut lines = vec![
        two_column(
            "Tokens today",
            &format_tokens(provider.tokens_today),
            width,
            Style::new().bold(),
        ),
        Line::raw(""),
    ];

    // Quota, error, and the separating blank line occupy the bottom; the
    // model list gets the rest. Reserve another row for the overflow marker
    // when the list does not fit.
    let quota_lines = 4;
    let error_lines = usize::from(provider.error.is_some());
    let reserved = lines.len() + 1 + quota_lines + error_lines;
    let model_rows = (inner.height as usize)
        .saturating_sub(reserved)
        .min(provider.model_usage_today.len());
    let overflow_rows =
        usize::from(provider.model_usage_today.len() > model_rows && model_rows > 1);
    let visible = model_rows.saturating_sub(overflow_rows);
    let scroll = scroll.min(
        provider
            .model_usage_today
            .len()
            .saturating_sub(visible.max(1)),
    );
    for usage in provider.model_usage_today.iter().skip(scroll).take(visible) {
        lines.push(two_column(
            &format!("  {}", truncated(&usage.model, width.saturating_sub(14))),
            &format_tokens(usage.tokens),
            width,
            Style::new(),
        ));
    }
    if overflow_rows > 0 && provider.model_usage_today.len() > scroll + visible {
        lines.push(Line::styled("  …", Style::new().dim()));
    }
    lines.push(Line::raw(""));

    let weekly_label = if index == 0 { "7d" } else { "Week" };
    let cached = provider.provider_usage_cached;
    lines.extend(quota_pair(
        "5h",
        provider.primary_pct,
        provider.primary_reset_min,
        width,
        cached,
    ));
    lines.extend(quota_pair(
        weekly_label,
        provider.weekly_pct,
        provider.weekly_reset_min,
        width,
        cached,
    ));

    if let Some(error) = &provider.error {
        lines.push(Line::styled(
            truncated(&format!(" {error}"), width),
            Style::new().fg(Color::Red),
        ));
    }
    lines
}

/// "5h    [██████░░░░░░]  43%" plus a "resets in …" line. Unknown quota
/// renders "—", never 0 (protocol.md).
fn quota_pair(
    label: &str,
    percent: Option<f64>,
    reset_minutes: Option<i64>,
    width: usize,
    cached: bool,
) -> Vec<Line<'static>> {
    let bar_width = width.saturating_sub(6 + 2 + 6).max(4);
    let mut lines = Vec::with_capacity(2);
    match percent {
        Some(percent) => {
            let clamped = percent.clamp(0.0, 100.0);
            let filled = ((clamped / 100.0) * bar_width as f64).round() as usize;
            let bar: String =
                "█".repeat(filled.min(bar_width)) + &"░".repeat(bar_width.saturating_sub(filled));
            let color = if clamped >= 85.0 {
                Color::Red
            } else if clamped >= 60.0 {
                Color::Yellow
            } else {
                Color::Green
            };
            lines.push(Line::from(vec![
                Span::raw(format!("{label:<6}[")),
                Span::styled(bar, Style::new().fg(color)),
                Span::raw(format!("] {:>3.0}%", clamped)),
            ]));
            let mut reset = vec![Span::styled(
                match reset_minutes {
                    Some(minutes) => format!("      resets in {}", format_minutes(minutes)),
                    None => "      resets —".to_string(),
                },
                Style::new().dim(),
            )];
            if cached {
                reset.push(Span::styled(" (cached)", Style::new().dim().italic()));
            }
            lines.push(Line::from(reset));
        }
        None => {
            lines.push(Line::from(vec![
                Span::raw(format!("{label:<6}")),
                Span::styled("—", Style::new().dim()),
            ]));
            lines.push(Line::raw(""));
        }
    }
    lines
}

fn two_column(left: &str, right: &str, width: usize, style: Style) -> Line<'static> {
    let left_width = left.chars().count();
    let right_width = right.chars().count();
    let padding = width.saturating_sub(left_width + right_width + 1).max(1);
    Line::styled(format!("{left}{}{right}", " ".repeat(padding)), style)
}

fn truncated(value: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let count = value.chars().count();
    if count <= max {
        value.to_string()
    } else {
        let kept: String = value.chars().take(max.saturating_sub(1)).collect();
        format!("{kept}…")
    }
}

/// Two provider cards with a token-history chart: bars per day for 7d, a
/// sparkline for 30d, bars per month for 12mo, plus range totals and the
/// per-model breakdown aggregated over the range.
fn draw_stats(frame: &mut Frame, area: Rect, app: &App) {
    let stacked = area.width < STACK_BELOW_WIDTH;
    let areas = if stacked {
        Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)]).split(area)
    } else {
        Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(area)
    };
    let today = app.cluster.today();
    let nodes = app.cluster.stats_nodes();
    let source_name = app
        .stats_node_id
        .as_ref()
        .and_then(|selected| nodes.iter().find(|node| &node.node_id == selected))
        .map(|node| node.name.as_str())
        .unwrap_or("all");
    for (index, (name, provider)) in [("Claude", "claude"), ("Codex", "codex")]
        .into_iter()
        .enumerate()
    {
        let days = match app.stats_node_id.as_deref() {
            Some(node_id) => app
                .cluster
                .provider_days_for_node(provider, node_id, &app.history),
            None => app.cluster.provider_days(provider, &app.history),
        };
        let stats = range_stats(&days, app.stats_range, today);
        let node_totals: Vec<(String, u64)> = if app.stats_node_id.is_none() && nodes.len() > 1 {
            app.cluster
                .provider_node_days(provider, &app.history)
                .into_iter()
                .map(|(node, days)| {
                    let total = range_stats(&days, app.stats_range, today).total;
                    (node.name, total)
                })
                .filter(|(_, total)| *total > 0)
                .collect()
        } else {
            Vec::new()
        };
        let content = StatsCardContent {
            source_name,
            stats: &stats,
            node_totals: &node_totals,
        };
        draw_stats_card(frame, areas[index], app, index, name, content);
    }
}

struct StatsCardContent<'a> {
    source_name: &'a str,
    stats: &'a RangeStats,
    node_totals: &'a [(String, u64)],
}

fn draw_cluster(frame: &mut Frame, area: Rect, app: &App) {
    let view = app.cluster.view();
    let block = Block::bordered()
        .title(" Encrypted cluster sync ")
        .border_style(Style::new().fg(Color::Cyan));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let mut lines = vec![
        two_column(
            "State",
            if view.enabled { "joined" } else { "standalone" },
            inner.width as usize,
            Style::new().bold(),
        ),
        Line::raw(format!(" Node      {} ({})", view.node_name, view.node_id)),
        Line::raw(format!(
            " Cluster   {}",
            view.cluster_id.as_deref().unwrap_or("—")
        )),
        Line::raw(format!(
            " Timezone  {}",
            view.timezone.as_deref().unwrap_or("—")
        )),
        Line::raw(format!(" Egress    {}", {
            let (observation, unavailable) = app.cluster.nat_observation();
            format_nat(observation, unavailable)
        })),
        Line::raw(""),
    ];
    if let Some(code) = &view.pairing_code {
        lines.push(Line::styled(
            format!(
                " Pairing code  {code}  ({}s)",
                view.pairing_seconds.unwrap_or_default()
            ),
            Style::new().fg(Color::Yellow).bold(),
        ));
        lines.push(Line::raw(
            " Give this code and the listener address to the joining node.",
        ));
        lines.push(Line::raw(""));
    } else if view.enabled {
        lines.push(Line::styled(
            " Press p to open a two-minute pairing window.",
            Style::new().dim(),
        ));
        lines.push(Line::raw(""));
    } else {
        lines.push(Line::styled(
            " Run `elink-tui cluster create`, then restart the TUI.",
            Style::new().fg(Color::Yellow),
        ));
        lines.push(Line::styled(
            " To join: `elink-tui cluster join --endpoint URL --code CODE`.",
            Style::new().dim(),
        ));
        lines.push(Line::raw(""));
    }
    lines.push(Line::styled(" Nodes", Style::new().bold()));
    // Labelled as a sync round trip on purpose: the figure includes peer
    // processing time and must not be read as link latency.
    lines.push(Line::styled(
        "  sync round-trip min/avg/max over the last hour",
        Style::new().dim(),
    ));
    if view.nodes.is_empty() {
        lines.push(Line::styled("  no known nodes", Style::new().dim()));
    } else {
        let summaries = app.cluster.link_summaries(3_600);
        for node in view
            .nodes
            .iter()
            .take(inner.height.saturating_sub(lines.len() as u16) as usize)
        {
            let seen = node
                .last_seen_at
                .map(|seen| format!("{} ago", format_age(epoch_now() - seen as i64)))
                .unwrap_or_else(|| "never seen".to_string());
            let link = summaries
                .get(&node.node_id)
                .map(format_link_summary)
                .unwrap_or_else(|| "—".to_string());
            lines.push(two_column(
                &format!("  {}", node.name),
                &format!("{link}  {seen}"),
                inner.width as usize,
                Style::new(),
            ));
        }
    }
    if let Some(error) = view.last_error {
        lines.push(Line::styled(
            truncated(&format!(" ⚠ {error}"), inner.width as usize),
            Style::new().fg(Color::Red),
        ));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

/// States the fact rather than a verdict: port preservation is the precondition
/// for port contention, while a rewritten port keeps the host out of it. Neither
/// deserves a warning marker — only losing the test itself does.
fn format_nat(observation: Option<StunObservation>, unavailable: bool) -> String {
    match observation {
        Some(value) if value.port_preserved() => {
            format!(
                "{} · port-preserving, in contention",
                value.external_endpoint()
            )
        }
        Some(value) => format!(
            "{} · port rewritten, not in contention",
            value.external_endpoint()
        ),
        None if unavailable => "STUN unreachable, port test unavailable".to_string(),
        None => "—".to_string(),
    }
}

/// Renders as `min/avg/max ms`, with a lost-sample count appended only when
/// samples were actually lost, so a healthy row stays quiet.
fn format_link_summary(summary: &LinkSummary) -> String {
    let lost = summary.lost_samples();
    let latency = match (summary.rtt_min_ms, summary.rtt_avg_ms(), summary.rtt_max_ms) {
        (Some(min), Some(avg), Some(max)) => format!("{min}/{avg}/{max}ms"),
        // Every sample in the window failed: no latency exists to report.
        _ if summary.samples > 0 => "no reply".to_string(),
        _ => "—".to_string(),
    };
    if lost > 0 {
        format!("{latency} ⚠{lost}/{} lost", summary.samples)
    } else {
        latency
    }
}

fn draw_stats_card(
    frame: &mut Frame,
    area: Rect,
    app: &App,
    index: usize,
    name: &str,
    content: StatsCardContent<'_>,
) {
    let StatsCardContent {
        source_name,
        stats,
        node_totals,
    } = content;
    let border_style = if app.focus == index {
        Style::new().fg(Color::Cyan)
    } else {
        Style::new().dim()
    };
    let block = Block::bordered()
        .border_style(border_style)
        .title(Line::from(vec![
            Span::styled(format!(" {name} "), Style::new().bold()),
            Span::styled(
                format!("history · {} · {source_name}", app.stats_range.label()),
                Style::new().dim(),
            ),
        ]));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.height < 4 || inner.width < 10 {
        return;
    }

    let chart_height = inner.height.saturating_sub(2).min(6);
    let rows = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(chart_height),
        Constraint::Min(0),
    ])
    .split(inner);

    let total_line = two_column(
        &format!("Total ({})", app.stats_range.label()),
        &format_tokens(stats.total),
        inner.width as usize,
        Style::new().bold(),
    );
    frame.render_widget(Paragraph::new(total_line), rows[0]);

    if stats.total == 0 {
        let note = if app.history.backfilled() {
            " no history in this range"
        } else {
            " backfilling history from session logs…"
        };
        frame.render_widget(
            Paragraph::new(Line::styled(note, Style::new().dim())),
            rows[1],
        );
    } else {
        draw_range_chart(frame, rows[1], app.stats_range, stats);
    }

    let width = inner.width as usize;
    let mut lines: Vec<Line> = Vec::new();
    let available = rows[2].height as usize;
    let node_rows = if node_totals.is_empty() {
        0
    } else {
        node_totals.len() + 2
    };
    let visible = available
        .saturating_sub(node_rows.min(available))
        .min(stats.models.len());
    for usage in stats.models.iter().take(visible) {
        lines.push(two_column(
            &format!("  {}", truncated(&usage.model, width.saturating_sub(14))),
            &format_tokens(usage.tokens),
            width,
            Style::new(),
        ));
    }
    if !node_totals.is_empty() && lines.len() + 2 <= available {
        lines.push(Line::raw(""));
        lines.push(Line::styled(" Nodes", Style::new().bold()));
        let cluster_total = node_totals
            .iter()
            .fold(0u64, |sum, (_, total)| sum.saturating_add(*total));
        for (node, total) in node_totals
            .iter()
            .take(available.saturating_sub(lines.len()))
        {
            let percent = if cluster_total == 0 {
                0.0
            } else {
                *total as f64 * 100.0 / cluster_total as f64
            };
            lines.push(two_column(
                &format!("  {}", truncated(node, width.saturating_sub(20))),
                &format!("{}  {percent:.0}%", format_tokens(*total)),
                width,
                Style::new().dim(),
            ));
        }
    }
    frame.render_widget(Paragraph::new(lines), rows[2]);
}

fn draw_range_chart(frame: &mut Frame, area: Rect, range: StatsRange, stats: &RangeStats) {
    match range {
        StatsRange::Week | StatsRange::Year => {
            let count = stats.series.len().max(1) as u16;
            let bar_width = ((area.width + 1) / count).saturating_sub(1).max(1);
            let bars: Vec<Bar> = stats
                .series
                .iter()
                .map(|(label, value)| {
                    Bar::default()
                        .value(*value)
                        .label(Line::from(label.clone()))
                        .text_value(String::new())
                })
                .collect();
            frame.render_widget(
                BarChart::default()
                    .data(BarGroup::default().bars(&bars))
                    .bar_width(bar_width)
                    .bar_gap(1)
                    .bar_style(Style::new().fg(Color::Cyan)),
                area,
            );
        }
        StatsRange::Month => {
            let values: Vec<u64> = stats.series.iter().map(|(_, value)| *value).collect();
            let rows = Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(area);
            frame.render_widget(
                Sparkline::default()
                    .data(&values)
                    .style(Style::new().fg(Color::Cyan)),
                rows[0],
            );
            let first = stats.series.first().map(|(label, _)| label.as_str());
            let last = stats.series.last().map(|(label, _)| label.as_str());
            let peak = values.iter().max().copied().unwrap_or(0);
            frame.render_widget(
                Paragraph::new(Line::styled(
                    format!(
                        "{} → {}  ·  peak {}",
                        first.unwrap_or("—"),
                        last.unwrap_or("—"),
                        format_tokens(peak)
                    ),
                    Style::new().dim(),
                )),
                rows[1],
            );
        }
    }
}

/// Device page: agent status and controls on the left, the exact e-paper
/// frame (fetched as PNG, rendered with half-block characters) on the right.
fn draw_device(frame: &mut Frame, area: Rect, app: &App) {
    let Some(link) = &app.device else {
        frame.render_widget(Paragraph::new(" no device configured"), area);
        return;
    };
    let state = link.state();
    let columns = Layout::horizontal([Constraint::Length(40), Constraint::Min(10)]).split(area);

    let block = Block::bordered()
        .title(Line::from(Span::styled(" Device ", Style::new().bold())))
        .border_style(Style::new().fg(Color::Cyan));
    let inner = block.inner(columns[0]);
    frame.render_widget(block, columns[0]);
    let width = inner.width as usize;
    let mut lines: Vec<Line> = Vec::new();
    match &state.info {
        Some(info) => {
            let version = info
                .version
                .as_deref()
                .map(|value| format!(" v{value}"))
                .unwrap_or_default();
            lines.push(Line::styled(
                format!(" elink-agent{version}"),
                Style::new().bold(),
            ));
            let (health, style) = if state.error.is_some() {
                ("unreachable", Style::new().fg(Color::Red))
            } else if info.stale {
                ("stale", Style::new().fg(Color::Yellow))
            } else {
                ("online", Style::new().fg(Color::Green))
            };
            lines.push(Line::from(vec![
                Span::raw(" state    "),
                Span::styled(health.to_string(), style),
            ]));
            lines.push(Line::raw(format!(" mode     {}", info.mode)));
            lines.push(Line::raw(truncated(
                &format!(" bridge   {}", info.bridge_url),
                width,
            )));
            lines.push(Line::raw(format!(
                " fetch    {}",
                info.last_fetch_age_s
                    .map(|age| format!("{} ago", format_age(age)))
                    .unwrap_or_else(|| "—".to_string())
            )));
            lines.push(Line::raw(format!(
                " refresh  {} ({})",
                info.last_refresh_age_s
                    .map(|age| format!("{} ago", format_age(age)))
                    .unwrap_or_else(|| "—".to_string()),
                info.last_refresh_kind
            )));
            if let Some(partials) = info.partial_count {
                lines.push(Line::raw(format!(" partials {partials}")));
            }
            if let Some(error) = &info.error {
                lines.push(Line::styled(
                    truncated(&format!(" {error}"), width),
                    Style::new().fg(Color::Red),
                ));
            }
        }
        None => lines.push(Line::styled(" connecting…", Style::new().dim())),
    }
    if let Some(error) = &state.error {
        lines.push(Line::styled(
            truncated(&format!(" {error}"), width),
            Style::new().fg(Color::Red),
        ));
    }
    if let Some(action) = &state.last_action {
        lines.push(Line::styled(
            truncated(&format!(" {action}"), width),
            Style::new().fg(Color::Yellow),
        ));
    }
    lines.push(Line::raw(""));
    for (keys, action) in [
        ("1/2/3", "mode dashboard/claude/codex"),
        ("p", "smart refresh"),
        ("f", "full refresh"),
        ("b", "point device at this machine"),
        ("d/Esc", "back to dashboard"),
    ] {
        lines.push(Line::from(vec![
            Span::styled(format!(" {keys:<7}"), Style::new().bold()),
            Span::styled(action.to_string(), Style::new().dim()),
        ]));
    }
    frame.render_widget(Paragraph::new(lines), inner);

    let title = state
        .info
        .as_ref()
        .and_then(|info| info.resolution)
        .map(|(width, height)| format!(" e-paper {width}×{height} "))
        .unwrap_or_else(|| " e-paper ".to_string());
    let block = Block::bordered()
        .title(title)
        .border_style(Style::new().dim());
    let inner = block.inner(columns[1]);
    frame.render_widget(block, columns[1]);
    match &state.preview {
        Some(preview) => {
            let lines = preview_lines(preview, inner.width, inner.height);
            frame.render_widget(Paragraph::new(lines), inner);
        }
        None => frame.render_widget(
            Paragraph::new(Line::styled(" no preview yet", Style::new().dim())),
            inner,
        ),
    }
}

/// Scales the 1-bit frame into the cell grid using half-block characters
/// (each cell renders two vertical pixels: fg on top, bg below), preserving
/// the panel's aspect ratio.
pub fn preview_lines(preview: &Preview, cells_wide: u16, cells_high: u16) -> Vec<Line<'static>> {
    if preview.width == 0 || preview.height == 0 || cells_wide == 0 || cells_high == 0 {
        return Vec::new();
    }
    let pixels_wide = u32::from(cells_wide);
    let pixels_high = u32::from(cells_high) * 2;
    let scale = f64::min(
        f64::from(pixels_wide) / f64::from(preview.width),
        f64::from(pixels_high) / f64::from(preview.height),
    );
    let out_width = ((f64::from(preview.width) * scale) as u32).clamp(1, pixels_wide);
    let out_height = ((f64::from(preview.height) * scale) as u32).clamp(1, pixels_high);
    let white = |out_x: u32, out_y: u32| -> bool {
        let x0 = (f64::from(out_x) / scale) as u32;
        let y0 = (f64::from(out_y) / scale) as u32;
        let x1 = ((f64::from(out_x + 1) / scale) as u32).clamp(x0 + 1, preview.width);
        let y1 = ((f64::from(out_y + 1) / scale) as u32).clamp(y0 + 1, preview.height);
        let mut sum = 0u64;
        let mut count = 0u64;
        for y in y0..y1 {
            for x in x0..x1 {
                sum += u64::from(preview.luma[(y * preview.width + x) as usize]);
                count += 1;
            }
        }
        count > 0 && sum / count >= 128
    };
    let color = |is_white: bool| if is_white { Color::White } else { Color::Black };
    (0..out_height.div_ceil(2))
        .map(|row| {
            let spans: Vec<Span> = (0..out_width)
                .map(|x| {
                    let top = white(x, row * 2);
                    let bottom = row * 2 + 1 < out_height && white(x, row * 2 + 1);
                    Span::styled("▀", Style::new().fg(color(top)).bg(color(bottom)))
                })
                .collect();
            Line::from(spans)
        })
        .collect()
}

fn draw_help(frame: &mut Frame, area: Rect) {
    let width = 46.min(area.width);
    let height = 18.min(area.height);
    let popup = Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    };
    let lines: Vec<Line> = [
        ("q / Ctrl-C", "quit"),
        ("r", "refresh status and quota now"),
        ("Tab / ← → / h l", "switch focused provider"),
        ("1 / 2", "focus Claude / Codex"),
        ("↑ ↓ / k j", "scroll model list"),
        ("s", "toggle usage history stats"),
        ("w / m / y", "stats range: week / month / year"),
        ("n", "stats source: all / cluster node"),
        ("d", "e-paper device page"),
        ("c", "encrypted cluster sync page"),
        ("u", "check for updates"),
        ("m", "toggle local / remote mode"),
        ("?", "toggle this help"),
        ("Esc", "close this help"),
    ]
    .into_iter()
    .map(|(keys, action)| {
        Line::from(vec![
            Span::styled(format!(" {keys:<16}"), Style::new().bold()),
            Span::raw(action),
        ])
    })
    .collect();
    frame.render_widget(Clear, popup);
    frame.render_widget(
        Paragraph::new(lines).block(
            Block::bordered()
                .title(" Help ")
                .border_style(Style::new().fg(Color::Cyan)),
        ),
        popup,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both NAT outcomes are statements of fact; neither may read as "healthy",
    /// and losing the test itself must be said out loud rather than left blank.
    #[test]
    fn nat_line_states_facts_and_announces_its_own_failure() {
        let preserving = StunObservation {
            local_port: 58682,
            external_address: std::net::Ipv4Addr::new(223, 95, 78, 14),
            external_port: 58682,
        };
        assert_eq!(
            format_nat(Some(preserving), false),
            "223.95.78.14:58682 · port-preserving, in contention"
        );

        let rewriting = StunObservation {
            local_port: 65080,
            external_address: std::net::Ipv4Addr::new(223, 95, 78, 14),
            external_port: 65264,
        };
        assert_eq!(
            format_nat(Some(rewriting), false),
            "223.95.78.14:65264 · port rewritten, not in contention"
        );

        assert_eq!(
            format_nat(None, true),
            "STUN unreachable, port test unavailable"
        );
        assert_eq!(format_nat(None, false), "—");
    }

    #[test]
    fn link_summary_stays_quiet_when_nothing_was_lost() {
        let summary = LinkSummary {
            samples: 240,
            ok_samples: 240,
            rtt_min_ms: Some(203),
            rtt_max_ms: Some(228),
            rtt_sum_ms: 240 * 215,
        };
        assert_eq!(format_link_summary(&summary), "203/215/228ms");
    }

    #[test]
    fn link_summary_reports_lost_samples_and_total_outage() {
        let partial = LinkSummary {
            samples: 240,
            ok_samples: 236,
            rtt_min_ms: Some(203),
            rtt_max_ms: Some(228),
            rtt_sum_ms: 236 * 215,
        };
        assert_eq!(format_link_summary(&partial), "203/215/228ms ⚠4/240 lost");

        // Every sample failed: there is no latency to report, only the outage.
        let dead = LinkSummary {
            samples: 240,
            ok_samples: 0,
            rtt_min_ms: None,
            rtt_max_ms: None,
            rtt_sum_ms: 0,
        };
        assert_eq!(format_link_summary(&dead), "no reply ⚠240/240 lost");

        assert_eq!(format_link_summary(&LinkSummary::default()), "—");
    }

    #[test]
    fn compact_line_formats_states_and_unknowns() {
        let mut snapshot = Snapshot {
            schema_version: 1,
            generated_at: None,
            usage_fetched_at: None,
            cluster: None,
            claude: ProviderStatus::default(),
            codex: ProviderStatus::default(),
        };
        snapshot.claude.status = "working".to_string();
        snapshot.claude.primary_pct = Some(43.0);
        snapshot.claude.weekly_pct = Some(68.4);
        snapshot.codex.status = "idle".to_string();
        snapshot.codex.needs_input = true;

        assert_eq!(compact_line(&snapshot), "C● 43%/68% | X○ -/- ⚠");
    }

    #[test]
    fn terminal_title_uses_worst_weekly_percentage() {
        assert_eq!(terminal_title(None), "elink-ai");
        let mut snapshot = Snapshot {
            schema_version: 1,
            generated_at: None,
            usage_fetched_at: None,
            cluster: None,
            claude: ProviderStatus::default(),
            codex: ProviderStatus::default(),
        };
        assert_eq!(terminal_title(Some(&snapshot)), "elink-ai");
        snapshot.claude.weekly_pct = Some(47.0);
        snapshot.codex.weekly_pct = Some(68.0);
        assert_eq!(terminal_title(Some(&snapshot)), "elink-ai 68%");
    }

    #[test]
    fn preview_lines_render_half_blocks_with_aspect() {
        // 4x4 image: top half white, bottom half black.
        let preview = Preview {
            width: 4,
            height: 4,
            luma: [255u8; 8].into_iter().chain([0u8; 8]).collect(),
        };

        let lines = preview_lines(&preview, 4, 2);

        assert_eq!(lines.len(), 2);
        let top = &lines[0].spans;
        assert_eq!(top.len(), 4);
        assert_eq!(top[0].style.fg, Some(Color::White));
        assert_eq!(top[0].style.bg, Some(Color::White));
        let bottom = &lines[1].spans;
        assert_eq!(bottom[0].style.fg, Some(Color::Black));
        assert_eq!(bottom[0].style.bg, Some(Color::Black));

        assert!(preview_lines(&preview, 0, 0).is_empty());
    }

    #[test]
    fn narrow_card_keeps_content_within_its_height() {
        let provider = ProviderStatus {
            model_usage_today: (0..10)
                .map(|index| crate::model::ModelUsage {
                    model: format!("model-{index}"),
                    tokens: 10,
                })
                .collect(),
            error: Some("quota unavailable".to_string()),
            ..ProviderStatus::default()
        };
        let inner = Rect::new(0, 0, 32, 10);

        let lines = provider_lines(&provider, 0, inner, 0);

        assert!(lines.len() <= inner.height as usize);
        assert!(lines
            .last()
            .expect("error line")
            .spans
            .iter()
            .any(|span| span.content.contains("quota unavailable")));
    }

    #[test]
    fn single_model_row_shows_data_instead_of_only_overflow_marker() {
        let provider = ProviderStatus {
            model_usage_today: (0..10)
                .map(|index| crate::model::ModelUsage {
                    model: format!("model-{index}"),
                    tokens: 10,
                })
                .collect(),
            error: Some("quota unavailable".to_string()),
            ..ProviderStatus::default()
        };
        let inner = Rect::new(0, 0, 32, 9);

        let lines = provider_lines(&provider, 0, inner, 0);

        assert!(lines.len() <= inner.height as usize);
        assert!(lines
            .iter()
            .flat_map(|line| &line.spans)
            .any(|span| span.content.contains("model-0")));
    }
}
