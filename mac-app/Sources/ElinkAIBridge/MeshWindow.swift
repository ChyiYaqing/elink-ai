import AppKit
import SwiftUI

/// 历史窗口长度。
///
/// 默认一天而不是几小时：这个窗口是「昨晚是不是断了」才会被打开的，而六小时的窗口在
/// 第二天早上看已经把昨晚整段滑出去了。
enum MeshHistorySpan: String, CaseIterable, Identifiable {
    case sixHours, day, week

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        }
    }

    var label: String {
        switch self {
        case .sixHours: return "6h"
        case .day: return "24h"
        case .week: return "7d"
        }
    }
}

final class MeshWindowModel: ObservableObject {
    @Published var span: MeshHistorySpan = .day
    @Published var localHistory: [String: [MeshBucketPoint]] = [:]
    @Published var lighthouseHistory: [String: [MeshBucketPoint]] = [:]
    @Published var lighthouseError: MeshHistoryError?
    @Published var loading = false
    /// 时间轴的右端。取自加载那一刻并固定下来，否则每次重绘轴都在悄悄右移，
    /// 上下两张图对不齐，读出来的时刻是错的。
    @Published var anchor = Date()

    var window: ClosedRange<Date> { anchor.addingTimeInterval(-span.seconds)...anchor }

    func load(mesh: MeshMonitor) {
        guard !loading else { return }
        loading = true
        let seconds = span.seconds
        let loadedAt = Date()
        let names = mesh.hosts.map(\.name)
        // 七天 × 六台是上万行，主线程读会把窗口卡住
        DispatchQueue.global(qos: .userInitiated).async {
            var local: [String: [MeshBucketPoint]] = [:]
            for name in names { local[name] = mesh.history(for: name, window: seconds) }
            DispatchQueue.main.async {
                self.anchor = loadedAt
                self.localHistory = local
            }
        }
        mesh.fetchLighthouseHistory(window: seconds) { [weak self] result in
            guard let self else { return }
            self.loading = false
            switch result {
            case .success(let history):
                self.lighthouseHistory = history
                self.lighthouseError = nil
            case .failure(let error):
                self.lighthouseHistory = [:]
                self.lighthouseError = error
            }
        }
    }
}

/// Nebula overlay 的完整视图。
///
/// 菜单栏弹窗里那张卡只回答「现在几台通」；这里回答「哪条链路、什么时候断的」。后者
/// 需要的横向像素是前者给不了的——440pt 宽的弹窗里，一天的时间轴上一个五分钟桶不到
/// 半个像素。
struct MeshWindowView: View {
    @ObservedObject var mesh: MeshMonitor
    @ObservedObject var model: MeshWindowModel
    @ObservedObject var panel: PanelModel
    /// 直接观察而不是走 PanelModel：那份拷贝只在弹窗打开时被刷新，窗口开着的时候
    /// 会停在最后一次的值上，而一个不再更新的 NAT 判据比没有更误导。
    @ObservedObject var link: LinkMonitor
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: [String: MeshBucketPoint] = [:]

    var body: some View {
        let theme = PanelTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            header(theme)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    settings(theme)
                    legend(theme)
                    if mesh.hosts.isEmpty {
                        Text(tr("等待第一份名册…", "Waiting for the first roster…"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.vertical, 24)
                    }
                    ForEach(mesh.hosts, id: \.name) { host in
                        hostBlock(host, theme: theme)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(theme.backgroundGradient)
        .onAppear { model.load(mesh: mesh) }
        .onChange(of: model.span) { _ in model.load(mesh: mesh) }
    }

    // MARK: - 顶部

    private func header(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(tr("Nebula 网络", "Nebula Overlay"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Picker("", selection: $model.span) {
                    ForEach(MeshHistorySpan.allCases) { span in
                        Text(span.label).tag(span)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                PillButton(title: model.loading ? tr("加载中…", "Loading…") : tr("刷新", "Refresh"),
                           icon: "arrow.clockwise", theme: theme) {
                    Log.user("refresh nebula overlay history")
                    mesh.refreshIfStale(maxAge: 0)
                    model.load(mesh: mesh)
                }
                .disabled(model.loading)
            }
            Text(UsagePanelView.meshSubtitle(
                total: mesh.hosts.count,
                reachable: mesh.hosts.filter { $0.state == .online }.count,
                updatedAt: mesh.updatedAt
            ))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            if !mesh.icmpAvailable {
                notice(tr("无法打开 ICMP socket，本机可达性暂时测不了",
                          "No ICMP socket: reachability unavailable on this host"), theme)
            }
            if !mesh.lighthouseReachable {
                notice(tr("lighthouse 不可达，显示的是上一次的名册",
                          "Lighthouse unreachable: showing the last known roster"), theme)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private func settings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let nat = UsagePanelView.clusterNatDetail(link.observation,
                                                        unavailable: link.unavailable) {
                HStack(alignment: .top, spacing: 8) {
                    Text(tr("出口 NAT", "Egress NAT"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 62, alignment: .leading)
                    Text(nat)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                TextField(tr("lighthouse 地址，例如 192.168.100.200:8767",
                             "Lighthouse address, e.g. 192.168.100.200:8767"),
                          text: $panel.lighthouseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: 320)
                PillButton(title: tr("保存", "Save"), icon: "checkmark", theme: theme) {
                    panel.onSaveLighthouse?(panel.lighthouseURL)
                    model.load(mesh: mesh)
                }
                Text(tr("设备清单由跑着 elink-tui --headless 的 lighthouse 提供；留空则关闭本视图。",
                        "The roster comes from a lighthouse running elink-tui --headless; empty disables this view."))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func legend(_ theme: PanelTheme) -> some View {
        let strip = MeshAvailabilityStrip(points: [], window: model.window, theme: theme)
        return HStack(spacing: 12) {
            ForEach([(MeshBucketStatus.ok, tr("全部探通", "all through")),
                     (.partial, tr("有丢包", "some lost")),
                     (.lost, tr("全部不通", "nothing through")),
                     (.noData, tr("没有探测", "not probed"))], id: \.0) { status, text in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(strip.color(status))
                        .frame(width: 14, height: 8)
                    Text(text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
        }
    }

    private func notice(_ text: String, _ theme: PanelTheme) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(theme.statusWarning)
    }

    // MARK: - 每台节点

    private func hostBlock(_ host: MeshHostView, theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(UsagePanelView.meshStateColor(host.state, theme: theme))
                    .frame(width: 6, height: 6)
                Text(host.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(host.overlay)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Text(host.latestRttUs.map { UsagePanelView.meshLatency(Int($0)) } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                Text(UsagePanelView.meshStateText(host))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(UsagePanelView.meshStateColor(host.state, theme: theme))
            }

            series(key: "local:\(host.name)",
                   title: tr("本机 → \(host.name)", "this host → \(host.name)"),
                   points: model.localHistory[host.name] ?? [],
                   missing: nil,
                   theme: theme)

            series(key: "lighthouse:\(host.name)",
                   title: tr("lighthouse → \(host.name)", "lighthouse → \(host.name)"),
                   points: model.lighthouseHistory[host.name] ?? [],
                   missing: Self.lighthouseNotice(model.lighthouseError,
                                                  hasSeries: model.lighthouseHistory[host.name] != nil),
                   theme: theme)

            axis(theme)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    /// 一条链路的完整呈现：摘要 + 可达性色带 + 延迟折线。
    ///
    /// 色带在折线上方而不是下方：先答「通不通」，再答「快不快」。事故排查里前者是问题
    /// 本身，后者只是旁证。
    @ViewBuilder
    private func series(key: String, title: String, points: [MeshBucketPoint],
                        missing: String?, theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(UsagePanelView.meshHistorySummary(points: points, hovered: hovered[key]))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
            if let missing {
                Text(missing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.statusWarning)
                    .frame(height: 20, alignment: .leading)
            } else {
                MeshAvailabilityStrip(points: points, window: model.window, theme: theme)
                    .frame(height: 10)
                let chart = MeshLatencyChart(points: points, window: model.window,
                                             theme: theme) { point in
                    hovered[key] = point
                }
                chart.frame(height: chart.hasPlottableData ? 56 : 10)
            }
        }
    }

    /// lighthouse 序列缺席时说清是哪一种缺席。
    static func lighthouseNotice(_ error: MeshHistoryError?, hasSeries: Bool) -> String? {
        switch error {
        case .notConfigured:
            return tr("未配置 lighthouse 地址，看不到对端视角",
                      "No lighthouse address: the far-side view is unavailable")
        case .unreachable:
            return tr("lighthouse 取历史失败，只能看到本机视角",
                      "Could not fetch history from the lighthouse: local view only")
        case .unsupported:
            return tr("lighthouse 版本过旧，尚不提供历史（需 elink-tui 支持 /history）",
                      "This lighthouse is too old to serve history (needs elink-tui with /history)")
        case .none:
            return hasSeries ? nil : tr("lighthouse 没有这台设备的探测记录",
                                        "The lighthouse has no probe record for this node")
        }
    }

    private func axis(_ theme: PanelTheme) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.axisLabels(window: model.window).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity,
                           alignment: item.offset == 0 ? .leading
                               : (item.offset == 4 ? .trailing : .center))
            }
        }
    }

    /// 五个等距刻度。满一天的窗口带上日期。
    ///
    /// 门槛正好压在 24 小时上：一天的窗口分五段，首尾两个刻度的时刻必然相同，只写
    /// 「22:13」会在轴的两端印出同一个标签；七天的窗口更是五个刻度都可能撞上。
    static func axisLabels(window: ClosedRange<Date>, count: Int = 5,
                           locale: Locale = .current) -> [String] {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(span >= 24 * 3600 ? "Mdjmm" : "jmm")
        return (0..<count).map { step in
            let ratio = Double(step) / Double(max(count - 1, 1))
            return formatter.string(from: window.lowerBound.addingTimeInterval(span * ratio))
        }
    }
}

/// 承载 `MeshWindowView` 的普通窗口。
///
/// 应用是 `.accessory`，平时没有窗口；这里显式激活一次，否则窗口会开在别的应用后面，
/// 用户点了「打开」却看不到任何反应。
final class MeshWindowController: NSObject, NSWindowDelegate {
    private let mesh: MeshMonitor
    private let panel: PanelModel
    private let link: LinkMonitor
    private let model = MeshWindowModel()
    private var window: NSWindow?

    init(mesh: MeshMonitor, panel: PanelModel, link: LinkMonitor) {
        self.mesh = mesh
        self.panel = panel
        self.link = link
        super.init()
    }

    func show() {
        // 名册决定窗口里有哪几台，先补一轮，否则刚开机点开是空的
        mesh.refreshIfStale()
        if let window {
            model.load(mesh: mesh)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: MeshWindowView(mesh: mesh, model: model, panel: panel, link: link)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = tr("Nebula 网络", "Nebula Overlay")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.center()
        // 关闭只是收起来：重开时保留窗口位置和已经选好的时间窗口
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Log.user("close nebula overlay window")
    }
}
