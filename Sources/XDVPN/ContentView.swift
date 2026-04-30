import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpn: VPNController
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(vpn.isConnected ? .green : .secondary)
                Text("XDVPN")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 6) {
                TextField("服务器地址", text: $vpn.server)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
                TextField("用户名", text: $vpn.user)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
                SecureField("密码", text: $vpn.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
            }

            Toggle("记住密码", isOn: $vpn.rememberPassword)
                .font(.caption)
                .disabled(vpn.isConnected || vpn.isBusy)

            Divider()

            // 状态行
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(vpn.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }

            // 按钮行
            HStack(spacing: 8) {
                if vpn.isConnected {
                    Button("断开") { vpn.disconnect() }
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vpn.isBusy)

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if let t = vpn.connectedAt {
                            Text(VPNController.formatDuration(Int(Date().timeIntervalSince(t))))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !vpn.sudoConfigured {
                    Button("一键配置") { vpn.installSudoers(thenConnect: true) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .disabled(vpn.isBusy)
                } else {
                    Button("连接") { vpn.connect() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .disabled(!vpn.canConnect)
                }

                Spacer()

                // 高级设置齿轮
                Button {
                    showAdvanced.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showAdvanced, arrowEdge: .leading) {
                    AdvancedSettingsPopover(vpn: vpn)
                }
                .disabled(vpn.isConnected || vpn.isBusy)

                // 更多菜单
                Menu {
                    if vpn.sudoConfigured {
                        Button("卸载免密 sudo 配置") { vpn.uninstallSudoers() }
                    }
                    Divider()
                    Button("退出 XDVPN") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }

            // 连接详情（连接后直接显示）
            if vpn.isConnected {
                VStack(alignment: .leading, spacing: 0) {
                    DiagRow("协议", vpn.protocolName)
                    DiagRow("服务器", vpn.server)
                    if let gw = vpn.vpnGateway { DiagRow("网关", gw) }
                    if let iface = vpn.tunnelInterface { DiagRow("接口", iface) }
                    if let ip = vpn.tunnelIP { DiagRow("地址", ip) }

                    DiagRow("流量",
                            "↑ \(VPNController.formatBytes(vpn.trafficOut))  ↓ \(VPNController.formatBytes(vpn.trafficIn))")

                    if !vpn.activeRoutes.isEmpty {
                        DiagRow("路由", vpn.activeRoutes.joined(separator: ", "))
                    }
                    DiagRow("分流", vpn.splitEnabled ? "启用" : "关闭")
                    if vpn.dnsProxyActive { DiagRow("DNS 代理", "活跃") }
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var dotColor: Color {
        if vpn.isConnected { return .green }
        if vpn.isBusy { return .orange }
        return .secondary
    }
}

// MARK: - 高级设置 Popover

private struct AdvancedSettingsPopover: View {
    @ObservedObject var vpn: VPNController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级设置").font(.headline)

            Picker("协议", selection: $vpn.protocolName) {
                ForEach(OpenConnectRunner.protocols, id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .pickerStyle(.menu)

            Divider()

            Toggle("分流模式（仅指定子网走 VPN）", isOn: $vpn.splitEnabled)

            if vpn.splitEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("常见内网段").font(.caption).foregroundStyle(.secondary)
                    Toggle("10.0.0.0/8", isOn: $vpn.splitPreset10)
                    Toggle("172.16.0.0/12", isOn: $vpn.splitPreset172)
                    Toggle("192.168.0.0/16（可能覆盖本地网络）", isOn: $vpn.splitPreset192)

                    Text("自定义 CIDR（逗号或换行分隔）")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    TextEditor(text: $vpn.splitCustom)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    Text("域名分流（一行一个域名后缀）")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    TextEditor(text: $vpn.splitDomains)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Diagnostics Row

private struct DiagRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text("  ")
            Text(value)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 1)
    }
}
