import SwiftUI

// 面板里的 Agent 会话卡片：每行一个会话（标题为最近的用户 prompt），
// 运行中显示浮动的像素宠物，完成显示绿色对勾，子代理折叠在下拉里。
struct AgentSessionsCard: View {
    let sessions: [AgentSession]
    let theme: PanelTheme
    @State private var isExpanded = false
    @State private var expandedIDs = Set<String>()

    private static let busyColor = Color(red: 0.32, green: 0.58, blue: 0.96)

    init(sessions: [AgentSession], theme: PanelTheme, initiallyExpanded: Bool = false) {
        self.sessions = sessions
        self.theme = theme
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let running = sessions.filter { $0.anyBusy }.count
        VStack(spacing: 10) {
            Button {
                Log.user("\(isExpanded ? "collapse" : "expand") agent sessions")
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(tr("Agent 会话", "Agent Sessions"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    StateBadge(text: running > 0 ? tr("\(running) 运行中", "\(running) working")
                                                 : tr("空闲", "Idle"),
                               color: running > 0 ? theme.statusHealthy : theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Agent 会话", "Agent Sessions"))
            .accessibilityValue(isExpanded ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))
            if isExpanded {
                ForEach(sessions.prefix(4)) { session in
                    sessionRow(session)
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .glassCard(theme)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SessionStatusIcon(kind: session.kind, busy: session.isBusy,
                                  live: session.isLive, theme: theme)
                Text(session.kind.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(tagText(session))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(tagColor(busy: session.isBusy, live: session.isLive))
                    .lineLimit(1)
            }
            if !detailText(session).isEmpty {
                Text(detailText(session))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 30)
            }
            if !session.children.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if expandedIDs.contains(session.id) {
                            expandedIDs.remove(session.id)
                        } else {
                            expandedIDs.insert(session.id)
                        }
                    }
                } label: {
                    Text(tr("\(expandedIDs.contains(session.id) ? "▾" : "▸") \(session.children.count) 个子任务",
                            "\(expandedIDs.contains(session.id) ? "▾" : "▸") \(session.children.count) subtasks"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
                if expandedIDs.contains(session.id) {
                    ForEach(session.children.prefix(6)) { child in
                        childRow(child)
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func childRow(_ child: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SessionStatusIcon(kind: child.kind, busy: child.isBusy,
                                  live: child.isLive, theme: theme, small: true)
                Text(child.nickname ?? "subagent")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(tagText(child))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(tagColor(busy: child.isBusy, live: child.isLive))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailText(_ session: AgentSession) -> String {
        session.prompt.isEmpty ? session.snippet : "You: \(session.prompt)"
    }

    private func tagText(_ session: AgentSession) -> String {
        let name = session.model.isEmpty ? session.title : session.model
        return "\(name) · \(Self.relativeTime(session.lastActivity ?? session.lastModified))"
    }

    private func tagColor(busy: Bool, live: Bool) -> Color {
        if busy { return Self.busyColor }
        if live { return theme.textTertiary }
        return theme.statusHealthy
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

private struct SessionStatusIcon: View {
    let kind: AgentKind
    let busy: Bool
    let live: Bool
    let theme: PanelTheme
    var small = false
    @State private var bob = false

    var body: some View {
        let art = kind == .claude ? PixelPet.claude : PixelPet.codex
        let accent = kind == .claude ? PanelTheme.claudeColor(dark: theme.dark)
                                     : PanelTheme.codexColor(dark: theme.dark)
        Group {
            if busy {
                PixelPetView(art: art, color: accent)
                    .offset(y: bob ? -1.5 : 1.5)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                            bob = true
                        }
                    }
            } else if live {
                // 存活但安静：静止且变暗，表示空闲而非完成
                PixelPetView(art: art, color: accent)
                    .opacity(0.4)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: small ? 10 : 13, weight: .semibold))
                    .foregroundStyle(theme.statusHealthy)
            }
        }
        .frame(width: small ? 16 : 22, height: small ? 12 : 16)
    }
}
