import AppKit
import SwiftUI

struct XDVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = VPNController()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(controller)
        } label: {
            // 注意：在 MenuBarExtra 的 label 槽里塞 SwiftUI 滤镜链（.saturation /
            // .frame / .aspectRatio 这类）菜单栏渲染出来常常是 0×0 空白。
            // 正确姿势：预先把 NSImage 调好尺寸和 isTemplate，直接交给 Image(nsImage:)。
            //
            // - 连上 = isTemplate=false，原始橙色 logo 原样上
            // - 未连 = isTemplate=true，系统按菜单栏的明暗自动染色（亮菜单变黑、暗菜单变白），
            //   天然达到"灰度/单色"效果，不会因色彩碰撞而隐形
            Image(nsImage: menuBarImage(connected: controller.isConnected))
        }
        .menuBarExtraStyle(.window)
    }
}

/// 返回一个预先调好 size 和 isTemplate 的 NSImage，供 MenuBarExtra 使用。
/// 1000×1000 的源图缩到 18×18 逻辑点，菜单栏高度 22pt 合适。
/// 找不到 Icon.png 时回退到 SF Symbol lock.shield 保底可见。
/// 拦截退出，先清理 VPN 残留再真正退出。
/// 用 .terminateLater + reply 的标准 Cocoa 模式，不阻塞 RunLoop。
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 如果 sudoers 没配或 openconnect 没在跑，直接退出（cleanup helper 不存在或无事可做）
        guard SudoersInstaller.isInstalled,
              OpenConnectRunner.isRunning else {
            return .terminateNow
        }
        // 后台跑 cleanup，完成后再回来退出
        DispatchQueue.global(qos: .userInitiated).async {
            try? OpenConnectRunner.cleanup()
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

private func menuBarImage(connected: Bool) -> NSImage {
    // 先 copy 再改属性，避免污染 Bundle 缓存的单例 NSImage —— 否则
    // 一个状态改了 size/isTemplate，下次用另一种状态读回来就错了。
    if let original = NSImage(named: "Icon"),
       let img = original.copy() as? NSImage {
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = !connected
        return img
    }
    // 保底：SF Symbol 锁盾，绝对会渲染
    let symbol = connected ? "lock.shield.fill" : "lock.shield"
    if let sys = NSImage(systemSymbolName: symbol, accessibilityDescription: "XDVPN") {
        sys.isTemplate = true
        return sys
    }
    return NSImage()  // 理论上不会到这里
}
