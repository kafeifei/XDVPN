import AppKit

// 防双开：在 SwiftUI / VPNController 初始化之前检测
let me = NSRunningApplication.current
let others = NSRunningApplication.runningApplications(
    withBundleIdentifier: me.bundleIdentifier ?? ""
).filter { $0 != me }

if !others.isEmpty {
    _ = NSApplication.shared
    let alert = NSAlert()
    alert.messageText = "XDVPN 已在运行"
    alert.informativeText = "请在菜单栏找到 XDVPN 图标。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "确认")
    alert.runModal()
    exit(0)
}

// 正常启动
XDVPNApp.main()
