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

            // 单行状态：[圆点] [文案] [内联配置按钮，仅未配置时显示]
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
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

    /// 状态点颜色：连上=绿、过渡中=橙、未连=灰。
    private var dotColor: Color {
        if vpn.isConnected { return .green }
        if vpn.isBusy { return .orange }
        return .secondary
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
