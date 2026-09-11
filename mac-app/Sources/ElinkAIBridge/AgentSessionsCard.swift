import SwiftUI

// 面板里的 Agent 会话卡片：每行一个会话（标题为最近的用户 prompt），
// 运行中显示浮动的像素宠物，完成显示绿色对勾，子代理折叠在下拉里。
struct AgentSessionsCard: View {
    let sessions: [AgentSession]
    let theme: PanelTheme
    @State private var isExpanded = false
    @State private var expandedIDs = Set<String>()
    @State private var outputIDs = Set<String>()

    private var busyColor: Color { theme.statusInfo }

    init(sessions: [AgentSession], theme: PanelTheme, initiallyExpanded: Bool = false,
         initiallyOpenOutputs: Set<String> = []) {
        self.sessions = sessions
        self.theme = theme
        _isExpanded = State(initialValue: initiallyExpanded)
        _outputIDs = State(initialValue: initiallyOpenOutputs)
    }

    var body: some View {
        let running = sessions.filter { $0.anyBusy }.count
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Log.user("\(isExpanded ? "collapse" : "expand") agent sessions")
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                // 摘要行的间距（12 / 5 / 12）与 Nebula 卡片一致，两张卡折叠时同高
                VStack(alignment: .leading, spacing: 5) {
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
                    Text(Self.subtitle(sessions: sessions))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
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
                Text(Self.tagText(session))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(tagColor(busy: session.isBusy, live: session.isLive))
                    .lineLimit(1)
            }
            if !detailText(session).isEmpty {
                if Self.hasTranscript(session) {
                    let open = outputIDs.contains(session.id)
                    Button {
                        Log.user("\(open ? "collapse" : "expand") agent session output")
                        withAnimation(.easeOut(duration: 0.2)) {
                            if open { outputIDs.remove(session.id) } else { outputIDs.insert(session.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                            Text(detailText(session))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 30)
                    .accessibilityLabel(tr("会话内容", "Session transcript"))
                    .accessibilityValue(open ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))
                    if open {
                        transcript(session)
                            .transition(.opacity)
                    }
                } else {
                    Text(detailText(session))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .padding(.leading, 30)
                }
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
                Text(Self.tagText(child))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(tagColor(busy: child.isBusy, live: child.isLive))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 展开的会话正文：固定高度的滚动区，每 3 秒随 poll 追加新条目。
    /// 会话还在忙时自动贴底，空闲的会话不抢用户正在读的位置。
    private func transcript(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.transcript) { entry in
                        row(entry, kind: session.kind)
                    }
                    // 贴底锚点：条目 id 会随窗口滑动变化，锚在固定的尾部更稳
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            // 上限而非固定高度：只有一两条时不该留一大片空白
            .frame(maxHeight: Self.transcriptHeight)
            // 展开就停在最新一条
            .onAppear { scrollToBottom(proxy, animated: false) }
            // 会话还在忙才跟着新条目走，空闲的会话不抢用户正在读的位置
            .onChange(of: session.transcript.count) { _ in
                guard session.isBusy else { return }
                scrollToBottom(proxy, animated: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.progressTrack))
        .padding(.leading, 30)
    }

    /// 部署目标是 macOS 13，用不了 `defaultScrollAnchor(.bottom)`。同步调用
    /// scrollTo 在首帧还拿不到内容尺寸会静默失效，因此推迟一次 runloop。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            guard animated else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: TranscriptEntry, kind: AgentKind) -> some View {
        switch entry.role {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("▸")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                Text(entry.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Text(entry.text)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role == .user ? tr("你", "You") : kind.rawValue)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                Text(entry.text)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(entry.role == .user ? theme.textSecondary : theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 只有真的有正文可读时才把摘要行变成可展开的按钮。
    static func hasTranscript(_ session: AgentSession) -> Bool {
        !session.transcript.isEmpty
    }

    private static let bottomAnchor = "transcript-bottom"
    private static let transcriptHeight: CGFloat = 200

    private func detailText(_ session: AgentSession) -> String {
        session.prompt.isEmpty ? session.snippet : "You: \(session.prompt)"
    }

    static func tagText(_ session: AgentSession, now: Date = Date()) -> String {
        let name = session.model.isEmpty ? session.title : session.model
        let rate = session.tokensPerSecond.map { String(format: " · %.0f tok/s", $0) } ?? ""
        return "\(name)\(rate) · \(relativeTime(session.lastActivity ?? session.lastModified, now: now))"
    }

    private func tagColor(busy: Bool, live: Bool) -> Color {
        if busy { return busyColor }
        if live { return theme.textTertiary }
        return theme.statusHealthy
    }

    /// 折叠时也要说清「有几个、多久没动静」。只有一个「空闲」徽章的话，卡片里是一个
    /// 会话还是四个、上次动静是一分钟前还是三天前，都看不出来。
    static func subtitle(sessions: [AgentSession], now: Date = Date()) -> String {
        let count = tr("\(sessions.count) 个会话",
                       sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
        guard let latest = sessions.map({ $0.lastActivity ?? $0.lastModified }).max() else {
            return count
        }
        let ago = relativeTime(latest, now: now)
        return count + tr(" · 最近 \(ago)", " · last active \(ago)")
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
