import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpn: VPNController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("XDVPN")
                .font(.headline)

            if !vpn.sudoConfigured {
                sudoBanner
            }

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

            HStack {
                Circle()
                    .fill(vpn.isConnected ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(vpn.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
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
        .frame(width: 320)
    }

    private var sudoBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚠️ 未配置免密 sudo")
                .font(.caption.bold())
            Text("配置后连接无弹窗。只允许 openconnect 一个二进制免密。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("一键配置") { vpn.installSudoers() }
                .disabled(vpn.isBusy)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
