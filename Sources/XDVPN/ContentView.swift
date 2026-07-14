import AppKit
import SwiftUI
import XDVPNCore

// MARK: - Design tokens

enum Design {
    /// 低饱和淡绿 —— Sonoma/Sequoia 系自然感主色
    static let accent = Color(red: 0.42, green: 0.74, blue: 0.55)
    /// 文字/icon 用的深色版本（可读性）
    static let accentDeep = Color(red: 0.24, green: 0.52, blue: 0.36)
    static let cardRadius: CGFloat = 14
    static let fieldRadius: CGFloat = 8
    static let chipRadius: CGFloat = 7

    static let menuBarWidth: CGFloat = 280
    static let mainWindowWidth: CGFloat = 480
}

// MARK: - Card container

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var padding: CGFloat = 14
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// =====================================================================
// MARK: - Main Window
//
// 一个真正的 NSWindow 内容视图。所有表单类操作都在这里完成，
// 不会因为失焦而消失。
// =====================================================================

struct MainWindowView: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var updater: UpdateChecker

    @State private var diagExpanded = false
    @State private var splitDetailsExpanded = false
    @State private var showWiFiSettings = false
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 顶部状态英雄区
                StatusHero(compact: false)
                    .padding(.bottom, 2)

                AccountSection()

                ModeSection()

                WiFiOnDemandSection(showSettings: $showWiFiSettings)

                if vpn.runningMode == .split {
                    SplitTunnelSection(detailsExpanded: $splitDetailsExpanded)
                }

                // 只有纯代理模式才展示 SOCKS5 配置 —— 别的模式 kernel 自动路由，
                // 不需要 SOCKS5 这个出口（之前展示是设计错误，会让人以为
                // 三种模式是叠加关系而不是互斥）
                if vpn.runningMode == .proxy {
                    ProxySection()
                }

                if vpn.isConnected {
                    DiagnosticsSection(isExpanded: $diagExpanded)
                }

                PrimaryActionButton()
                    .padding(.top, 2)

                FooterRow(showLogs: $showLogs)
            }
            .padding(18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(width: Design.mainWindowWidth)
        .background(WindowBackground())
        .sheet(isPresented: $showWiFiSettings) {
            WiFiOnDemandSettingsView()
        }
        .sheet(isPresented: $showLogs) {
            LogPanelView()
        }
    }
}

/// 让窗口背景使用 macOS 默认的窗口色（避免出现纯白卡卡的感觉）
private struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .windowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// =====================================================================
// MARK: - Shared components
// =====================================================================

// MARK: Status hero

private struct StatusHero: View {
    @EnvironmentObject var vpn: VPNController
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.20))
                    .frame(width: compact ? 30 : 44, height: compact ? 30 : 44)
                Circle()
                    .fill(dotColor)
                    .frame(width: compact ? 10 : 14, height: compact ? 10 : 14)
                    .shadow(color: dotColor.opacity(vpn.isConnected ? 0.5 : 0), radius: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                if showSubtitle {
                    Text(subtitle)
                        .font(.system(size: compact ? 10 : 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            rightAccessory
        }
        .padding(.horizontal, compact ? 2 : 4)
    }

    @ViewBuilder
    private var rightAccessory: some View {
        if vpn.isConnected, let t = vpn.connectedAt {
            VStack(alignment: .trailing, spacing: 2) {
                ConnectionDurationText(connectedAt: t, compact: compact)
                    .fixedSize()
                if !compact {
                    Text("时长")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        } else if vpn.isBusy {
            ProgressView().controlSize(.small)
        }
    }

    private var dotColor: Color {
        if vpn.isConnected { return Design.accent }
        if vpn.isBusy { return .orange }
        return .secondary
    }
    private var headline: String {
        if vpn.isConnected { return "已连接" }
        if vpn.isBusy { return "处理中" }
        return "未连接"
    }
    private var subtitle: String {
        // 优先 statusText；如果它和 headline 重复，回退到展示服务器名
        let s = vpn.statusText.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty && s != headline { return s }
        if vpn.isConnected { return vpn.server }
        if !vpn.server.isEmpty { return "\(vpn.user.isEmpty ? "?" : vpn.user)@\(vpn.server)" }
        return "尚未配置账户"
    }
    private var showSubtitle: Bool {
        !subtitle.isEmpty
    }
}

/// The elapsed time changes every second, but it does not need to invalidate the
/// surrounding SwiftUI hierarchy. Keep that clock inside a small AppKit view.
private struct ConnectionDurationText: NSViewRepresentable {
    let connectedAt: Date
    let compact: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: compact ? 12 : 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        context.coordinator.start(label: label, connectedAt: connectedAt)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.font = .monospacedSystemFont(ofSize: compact ? 12 : 14, weight: .regular)
        context.coordinator.update(label: label, connectedAt: connectedAt)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var label: NSTextField?
        private var connectedAt: Date?
        private var timer: Timer?

        func start(label: NSTextField, connectedAt: Date) {
            self.label = label
            self.connectedAt = connectedAt
            refresh()

            let timer = Timer(
                timeInterval: 1,
                target: self,
                selector: #selector(timerFired),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func update(label: NSTextField, connectedAt: Date) {
            self.label = label
            guard self.connectedAt != connectedAt else { return }
            self.connectedAt = connectedAt
            refresh()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func refresh() {
            guard let connectedAt else { return }
            let seconds = max(0, Int(Date().timeIntervalSince(connectedAt)))
            label?.stringValue = VPNController.formatDuration(seconds)
        }

        @objc private func timerFired() {
            refresh()
        }
    }
}

// MARK: Account section (main window) ─────────────────────────────────

private struct AccountSection: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "person.crop.circle", title: "账户")

                VStack(spacing: 8) {
                    FieldRow(icon: "network", placeholder: "服务器地址（如 vpn.example.com）", text: $vpn.server)
                    FieldRow(icon: "person", placeholder: "用户名", text: $vpn.user)
                    FieldRow(icon: "key", placeholder: "密码", text: $vpn.password, secure: true)
                }
                .disabled(vpn.isConnected || vpn.isBusy)

                HStack(spacing: 10) {
                    Toggle("记住密码", isOn: $vpn.rememberPassword)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 12))
                        .disabled(vpn.isConnected || vpn.isBusy)
                    Spacer()
                    Text("协议")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $vpn.protocolName) {
                        ForEach(OpenConnectRunner.protocols, id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 130)
                    .disabled(vpn.isConnected || vpn.isBusy)
                }

                // 启动时自动连接 —— 远程维护机器（SSH 上去开机）的常见诉求。
                // 必须配合"记住密码"才有意义（否则启动时密码栏为空，canConnect=false 静默跳过）。
                HStack(spacing: 6) {
                    Toggle("启动时自动连接", isOn: $vpn.autoConnectOnLaunch)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 12))
                        .disabled(!vpn.rememberPassword)
                    if !vpn.rememberPassword {
                        Text("需先开启「记住密码」")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: Mode section (3-way: proxy / split / full) ───────────────────

private struct ModeSection: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("运行模式")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }

                Picker("", selection: modeSelection) {
                    ForEach(VPNController.RunningMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(vpn.isBusy)

                Text(currentSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if vpn.isConnected {
                    Text("切换模式会断开当前 VPN 并自动重连")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var modeSelection: Binding<VPNController.RunningMode> {
        Binding(
            get: { vpn.runningMode },
            set: { vpn.selectMode($0, presentingWindow: NSApp.keyWindow) }
        )
    }

    private var iconName: String {
        switch vpn.runningMode {
        case .proxy: return "shippingbox"
        case .split: return "arrow.triangle.branch"
        case .full:  return "network"
        }
    }

    private var currentSummary: String {
        switch vpn.runningMode {
        case .proxy:
            return "纯代理：ocproxy 在用户态终结 VPN，不动系统路由 / DNS，不需要 sudo。所有流量必须经 SOCKS5 才走 VPN —— 配 Surge / curl --socks5 等客户端来用。"
        case .split:
            return "VPN 分流：创建 utun 接口，仅勾选的网段走 VPN，其它流量走本机默认网络。浏览器可直接访问内网域名。需要 sudo 配置。"
        case .full:
            return "VPN 全局：创建 utun，所有外网流量都走 VPN 隧道（def1）。本地 LAN 仍可用，但任何上网请求都从公司出口出。需要 sudo 配置。"
        }
    }
}

// MARK: Wi-Fi on-demand section ─────────────────────────────────────

private struct WiFiOnDemandSection: View {
    @EnvironmentObject var vpn: VPNController
    @Binding var showSettings: Bool

    var body: some View {
        Card(content: {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Design.accentDeep)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi 按需连接")
                        .font(.system(size: 13, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(vpn.pausedByWiFiPolicy ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("配置 Wi-Fi 规则")

                Toggle("", isOn: $vpn.wifiOnDemandEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }, padding: 12)
    }

    private var summary: String {
        guard vpn.wifiOnDemandEnabled else { return "未启用" }
        if vpn.wifiOnDemandRules.isEmpty { return "已启用 · 暂无规则" }
        return "\(vpn.wifiOnDemandRules.count) 条规则 · \(vpn.wifiOnDemandStatusText)"
    }
}

private struct WiFiOnDemandSettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @Environment(\.dismiss) private var dismiss
    @State private var currentAction: WiFiOnDemandAction = .disconnectVPN
    @State private var manualSSID = ""
    @State private var manualAction: WiFiOnDemandAction = .disconnectVPN

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "wifi")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Design.accentDeep)
                Text("Wi-Fi 按需连接设置")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: $vpn.wifiOnDemandEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    currentWiFiSection
                    manualRuleSection
                    ruleListSection
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 500, height: 480)
        .background(WindowBackground())
        .onAppear {
            vpn.refreshWiFiSSID(requestPermissionIfNeeded: false)
        }
    }

    private var currentWiFiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前 Wi-Fi")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                Text(vpn.currentWiFiSSID ?? "未读取到 Wi-Fi")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(vpn.currentWiFiSSID == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    vpn.refreshWiFiSSID(requestPermissionIfNeeded: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("刷新当前 Wi-Fi")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Design.fieldRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            HStack(spacing: 8) {
                ActionPicker(selection: $currentAction)
                    .frame(width: 112)
                Button {
                    vpn.addCurrentWiFiRule(action: currentAction)
                } label: {
                    Label("添加当前 Wi-Fi", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vpn.currentWiFiSSID == nil)
                Spacer()
            }
        }
    }

    private var manualRuleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动添加")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                TextField("SSID", text: $manualSSID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                ActionPicker(selection: $manualAction)
                    .frame(width: 112)
                Button {
                    vpn.addWiFiRule(ssid: manualSSID, action: manualAction)
                    manualSSID = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manualSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("添加规则")
            }
        }
    }

    @ViewBuilder
    private var ruleListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("规则")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(vpn.wifiOnDemandRules.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if vpn.wifiOnDemandRules.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无规则")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 14)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(vpn.wifiOnDemandRules) { rule in
                        WiFiRuleRow(rule: rule)
                    }
                }
            }

            if !vpn.wifiOnDemandStatusText.isEmpty {
                Text(vpn.wifiOnDemandStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(vpn.pausedByWiFiPolicy ? .orange : .secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct WiFiRuleRow: View {
    @EnvironmentObject var vpn: VPNController
    let rule: WiFiOnDemandRule

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rule.action.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rule.action.tint)
                .frame(width: 16)
            Text(rule.ssid)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ActionPicker(selection: Binding(
                get: { rule.action },
                set: { vpn.updateWiFiRule(id: rule.id, action: $0) }
            ))
            .frame(width: 112)
            Button {
                vpn.removeWiFiRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除规则")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Design.fieldRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }
}

private struct ActionPicker: View {
    @Binding var selection: WiFiOnDemandAction

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(WiFiOnDemandAction.allCases) { action in
                Text(action.label).tag(action)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }
}

private extension WiFiOnDemandAction {
    var label: String {
        switch self {
        case .connectVPN: return "连接 VPN"
        case .disconnectVPN: return "断开 VPN"
        }
    }

    var iconName: String {
        switch self {
        case .connectVPN: return "link"
        case .disconnectVPN: return "power"
        }
    }

    var tint: Color {
        switch self {
        case .connectVPN: return Design.accentDeep
        case .disconnectVPN: return .orange
        }
    }
}

// MARK: Split CIDR section ─────────────────────────────────────────
//
// 仅在 runningMode == .split 时显示。配置哪些网段 / 域名走 VPN。

private struct SplitTunnelSection: View {
    @EnvironmentObject var vpn: VPNController
    @Binding var detailsExpanded: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Design.accentDeep)
                    Text("分流网段 & 域名")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if vpn.isConnected {
                        Text("修改后需重连才生效")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("内网网段")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)

                HStack(spacing: 8) {
                    CIDRChip(label: "10.0.0.0/8", isOn: $vpn.splitPreset10)
                    CIDRChip(label: "172.16.0.0/12", isOn: $vpn.splitPreset172)
                    CIDRChip(label: "192.168.0.0/16", isOn: $vpn.splitPreset192)
                    Spacer()
                }
                .disabled(vpn.isBusy)

                Button {
                    withAnimation(.smooth(duration: 0.18)) { detailsExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(detailsExpanded ? "收起自定义规则" : "自定义 CIDR / 域名")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                if detailsExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自定义 CIDR")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        EditorBox(text: $vpn.splitCustom, height: 64,
                                  placeholder: "一行一个或逗号分隔，如 172.20.0.0/16")

                        Text("域名后缀（自动匹配所有子域）")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        EditorBox(text: $vpn.splitDomains, height: 64,
                                  placeholder: "一行一个，如 yourcompany.com")
                    }
                    .disabled(vpn.isBusy)
                }
            }
        }
    }

    private var subtitle: String {
        let c = vpn.collectSplitCIDRs().count
        let d = vpn.collectDomainSuffixes().count
        if c == 0 && d == 0 { return "尚未选择任何规则" }
        var parts: [String] = []
        // 注：这里返回 String 而非 Text，Swift 字符串插值不会按 locale 千位分隔，所以安全
        if c > 0 { parts.append("\(c) 个网段") }
        if d > 0 { parts.append("\(d) 个域名") }
        return parts.joined(separator: " · ") + " 走 VPN"
    }
}

// MARK: Proxy section (SOCKS5 for Surge / other clients) ─────────────

private struct ProxySection: View {
    @EnvironmentObject var vpn: VPNController
    @State private var portText: String = ""
    @State private var portFocused: Bool = false

    var body: some View {
        // 这个 section 只会在 runningMode == .proxy 时由 MainWindowView 渲染，
        // 所以内部不再判断模式。SOCKS5 是纯代理模式的本质，没有开/关，只有端口配置。
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "personalhotspot")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Design.accentDeep)
                    Text("SOCKS5 出口（ocproxy）")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    statusBadge
                }

                HStack(spacing: 10) {
                    Text("端口")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("5180", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80)
                        .onSubmit { commitPort() }
                        .disabled(vpn.isConnected || vpn.isBusy)
                    Spacer()
                }

                Text(verbatim: "客户端连接地址：127.0.0.1:\(vpn.socks5Port)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                if !vpn.isConnected {
                    Text("VPN 连接后 ocproxy 自动启动")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if vpn.socks5Active {
                    copyConfigButton
                }
            }
        }
        .onAppear { portText = String(vpn.socks5Port) }
        .onChange(of: vpn.socks5Port) { _, new in portText = String(new) }
    }

    private func commitPort() {
        if let p = Int(portText.trimmingCharacters(in: .whitespaces)),
           (1024...65535).contains(p) {
            vpn.socks5Port = p
        }
        // 不管成功失败，UI 都回到当前真实端口值
        portText = String(vpn.socks5Port)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if vpn.socks5Active {
            HStack(spacing: 4) {
                Circle()
                    .fill(Design.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: Design.accent.opacity(0.5), radius: 2)
                Text("运行中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else if vpn.socks5Error != nil {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("出错").font(.system(size: 10)).foregroundStyle(.red)
            }
        } else if !vpn.isConnected {
            Text("待 VPN 连接")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var copyConfigButton: some View {
        let snippet = """
        [Proxy]
        XDVPN = socks5, 127.0.0.1, \(vpn.socks5Port)

        [Rule]
        # 让你想走公司出口的域名 / IP 段走 XDVPN
        DOMAIN-SUFFIX,xindong.com,XDVPN
        DOMAIN-SUFFIX,tapsvc.com,XDVPN
        """
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10))
                Text("复制 Surge 配置片段")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Diagnostics section ─────────────────────────────────────────

private struct DiagnosticsSection: View {
    @EnvironmentObject var vpn: VPNController
    @Binding var isExpanded: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("诊断")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    // 纯代理模式没 utun，拿不到流量；其它两种模式才展示
                    if !vpn.useProxyMode {
                        StatChip(icon: "arrow.up.right", value: VPNController.formatBytes(vpn.trafficOut))
                        StatChip(icon: "arrow.down.left", value: VPNController.formatBytes(vpn.trafficIn))
                    }
                    Button {
                        withAnimation(.smooth(duration: 0.18)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        DiagRow("模式", vpn.runningMode.label)
                        DiagRow("协议", vpn.protocolName)
                        DiagRow("服务器", vpn.server)
                        if let gw = vpn.vpnGateway { DiagRow("网关", gw) }
                        if let iface = vpn.tunnelInterface { DiagRow("接口", iface) }
                        if let ip = vpn.tunnelIP { DiagRow("地址", ip) }
                        if !vpn.activeRoutes.isEmpty {
                            DiagRow("路由", vpn.activeRoutes.joined(separator: ", "))
                        }
                        if vpn.useProxyMode {
                            DiagRow("SOCKS5", "127.0.0.1:\(vpn.socks5Port)")
                            DiagRow("流量统计", "—（用户态模式不可用）")
                        }
                        if vpn.dnsProxyActive { DiagRow("DNS 代理", "活跃") }
                    }
                }
            }
        }
    }
}

// MARK: Footer (main window) ─────────────────────────────────

private struct FooterRow: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var updater: UpdateChecker
    @Binding var showLogs: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("v\(versionString)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if updater.hasUpdate {
                Button("有新版本…") { updater.showUpdateWindow() }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("运行日志") { showLogs = true }
                .font(.system(size: 11))
                .buttonStyle(.link)
            Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
            Button("GitHub") {
                if let u = URL(string: "https://github.com/kafeifei/XDVPN") {
                    NSWorkspace.shared.open(u)
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.link)
            if vpn.sudoConfigured {
                Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("卸载 sudo") { vpn.uninstallSudoers() }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

// =====================================================================
// MARK: - Reusable atoms
// =====================================================================

private struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }
}

private struct FieldRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Design.fieldRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct CIDRChip: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Design.chipRadius, style: .continuous)
                    .fill(isOn ? Design.accent.opacity(0.22) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.chipRadius, style: .continuous)
                    .stroke(isOn ? Design.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isOn ? Design.accentDeep : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct EditorBox: View {
    @Binding var text: String
    let height: CGFloat
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Design.fieldRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
    }
}

private struct StatChip: View {
    let icon: String
    let value: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

private struct DiagRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

// MARK: Primary action button ─────────────────────────────────────

private struct PrimaryActionButton: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if vpn.isBusy && !vpn.isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(buttonBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(vpn.isConnected ? Color.primary.opacity(0.10) : Color.clear, lineWidth: 0.5)
            )
            .foregroundStyle(buttonFg)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }

    /// 纯代理模式不依赖 sudo（openconnect 以用户身份跑），不应被 sudo install 流程拦住
    private var needsSudoBootstrap: Bool {
        !vpn.useProxyMode && !vpn.sudoConfigured
    }

    private func tap() {
        if vpn.isConnecting { vpn.cancelConnection() }
        else if vpn.isConnected { vpn.disconnect() }
        else if needsSudoBootstrap { vpn.installSudoers(thenConnect: true) }
        else { vpn.connect() }
    }

    private var iconName: String {
        if vpn.isConnecting { return "xmark.circle.fill" }
        if vpn.isConnected { return "power.circle.fill" }
        if needsSudoBootstrap { return "wand.and.stars" }
        return "link"
    }
    private var label: String {
        if vpn.isConnecting { return "取消连接" }
        if vpn.isBusy { return "请稍候…" }
        if vpn.isConnected { return "断开连接" }
        if needsSudoBootstrap { return "首次配置并连接" }
        return "连接"
    }
    private var buttonBg: Color {
        if vpn.isConnected || vpn.isConnecting { return Color.secondary.opacity(0.12) }
        if disabled { return Design.accent.opacity(0.30) }
        return Design.accent
    }
    private var buttonFg: Color {
        vpn.isConnected || vpn.isConnecting ? .primary : .white
    }
    private var disabled: Bool {
        if vpn.isConnecting { return false }
        if vpn.isBusy { return true }
        if vpn.isConnected { return false }
        if needsSudoBootstrap { return false }
        return !vpn.canConnect
    }
}

// =====================================================================
// MARK: - 运行日志面板（release 可见）
//
// 观察自动重连行为用。最新在底部 + 自动滚到底，符合「跟踪实时日志」直觉。
// 接 LogStore.shared，@ObservedObject 自动刷新。复制全部 / 清空。
// =====================================================================

struct LogPanelView: View {
    @ObservedObject private var store = LogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Design.accentDeep)
                Text("运行日志")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.entries.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.plainText(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 10))
                        Text(copied ? "已复制" : "复制全部")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.entries.isEmpty)

                Button {
                    store.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("清空").font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.entries.isEmpty)

                Button("关闭") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 日志列表
            if store.entries.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("暂无日志")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("连接 VPN 后，自动重连等运行事件会显示在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.entries) { entry in
                                LogRow(entry: entry, timeFmt: Self.timeFmt)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { scrollToBottom(proxy) }
                    .onChange(of: store.entries.count) { _, _ in scrollToBottom(proxy) }
                }
            }
        }
        .frame(width: 520, height: 420)
        .background(WindowBackgroundColor())
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.entries.last else { return }
        // 等一帧让新行先布局，再滚到底
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let timeFmt: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeFmt.string(from: entry.time))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(entry.level.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(levelColor)
                .frame(width: 30, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 12))
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:  return .secondary
        case .warn:  return .orange
        case .error: return .red
        }
    }
    private var messageColor: Color {
        switch entry.level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

/// sheet 背景使用窗口色，避免纯白
private struct WindowBackgroundColor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .windowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
