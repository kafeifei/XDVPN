import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("XDVPN")
                .font(.headline)

            Picker("协议", selection: $vpn.protocolName) {
                ForEach(OpenConnectRunner.protocols, id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .pickerStyle(.menu)
            .disabled(vpn.isConnected || vpn.isBusy)

            LabeledField(label: "服务器") {
                TextField("vpn.example.com:8443", text: $vpn.server)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
            }

            LabeledField(label: "用户名") {
                TextField("username", text: $vpn.user)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
            }

            LabeledField(label: "密码") {
                SecureField("password", text: $vpn.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vpn.isConnected || vpn.isBusy)
            }

            Toggle("记住密码（存入 Keychain）", isOn: $vpn.rememberPassword)
                .disabled(vpn.isConnected || vpn.isBusy)

            Divider()

            // 单行状态：[圆点] [文案] [内联修复/配置按钮]
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(vpn.statusColor))
                    .frame(width: 8, height: 8)
                Text(vpn.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !vpn.sudoConfigured {
                    Button("一键配置") { vpn.installSudoers() }
                        .controlSize(.small)
                        .disabled(vpn.isBusy)
                } else if vpn.needsRepair {
                    Button("修复路由") { vpn.repairRoutes() }
                        .controlSize(.small)
                        .disabled(vpn.isBusy)
                }
            }

            HStack {
                if vpn.isConnected {
                    Button("断开") { vpn.disconnect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(vpn.isBusy)
                } else {
                    Button("连接") { vpn.connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!vpn.canConnect)
                }
                Spacer()
                Menu {
                    if vpn.sudoConfigured {
                        Button("卸载免密 sudo 配置") { vpn.uninstallSudoers() }
                    }
                    Button("手动修复路由") { vpn.repairRoutes() }
                        .disabled(vpn.isBusy || !vpn.sudoConfigured)
                    Divider()
                    Button("退出 XDVPN") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func dotColor(_ d: StatusDot) -> Color {
        switch d {
        case .green: return .green
        case .yellow: return .orange
        case .red: return .red
        case .gray: return .secondary
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}
