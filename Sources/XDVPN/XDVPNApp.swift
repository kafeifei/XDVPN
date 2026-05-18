import AppKit
import Combine
import SwiftUI

// MARK: - Open main window action
//
// 提供给主窗口里的子视图用来召唤主窗口（虽然现在主窗口已自管理，留作扩展点）
struct OpenMainWindowAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

private struct OpenMainWindowKey: EnvironmentKey {
    static let defaultValue = OpenMainWindowAction(perform: {})
}

extension EnvironmentValues {
    var openMainWindow: OpenMainWindowAction {
        get { self[OpenMainWindowKey.self] }
        set { self[OpenMainWindowKey.self] = newValue }
    }
}

// MARK: - App
//
// 注意：不要加 @main —— main.swift 已经做了防双开检查后手动调 XDVPNApp.main()
// 整个菜单栏和主窗口都由 AppDelegate 用 AppKit 原生方式管理，
// 这里只提供一个空 Settings scene 作为 SwiftUI App 协议的最低占位。
struct XDVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Menu bar icon
//
// 始终 template image：
//   - 白底（RGB ≥ 245）alpha 置 0，让 macOS template 渲染只看到 blob 轮廓
//   - 裁掉透明边距，输出 16pt 高的 NSImage，和 Surge 这类原生菜单栏图标对齐
//
// 颜色逻辑放在 NSStatusBarButton.contentTintColor：
//   - 未连接：tertiaryLabelColor → 淡化
//   - 已连接：nil → 系统默认 label 色（亮菜单黑、暗菜单白）
//   完全不再加任何品牌色。
enum MenuBarIcon {
    private static let cached: NSImage? = makeImage()

    static func template() -> NSImage {
        if let img = cached?.copy() as? NSImage {
            img.isTemplate = true
            return img
        }
        // 兜底：SF Symbol（Icon.png 缺失的极端情况）
        let sym = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "XDVPN") ?? NSImage()
        sym.isTemplate = true
        return sym
    }

    private static func makeImage() -> NSImage? {
        guard let source = NSImage(named: "Icon"),
              let cgSrc = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let workSize = 256        // 处理用大尺寸，保证降采样质量
        let bytesPerRow = workSize * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(data: nil, width: workSize, height: workSize,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: workSize, height: workSize))
        ctx.interpolationQuality = .high
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: workSize, height: workSize))

        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: bytesPerRow * workSize)

        // 白底打透明 + 统计 bbox（CGImage top-left 坐标）
        let threshold: UInt8 = 245
        var minX = workSize, minY = workSize, maxX = -1, maxY = -1
        for y in 0..<workSize {
            for x in 0..<workSize {
                let i = y * bytesPerRow + x * 4
                let r = buf[i], g = buf[i + 1], b = buf[i + 2]
                if r >= threshold && g >= threshold && b >= threshold {
                    buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0
                } else {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        guard let fullCG = ctx.makeImage() else { return nil }
        let cropRect = CGRect(x: minX, y: minY,
                              width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = fullCG.cropping(to: cropRect) else { return nil }

        // 输出：18pt 容器，内容 13pt 居中。背后 4x 像素 backing 保证 Retina 清晰
        let containerPt: CGFloat = 18
        let contentPt: CGFloat = 13
        let aspect = CGFloat(cropped.width) / CGFloat(cropped.height)
        let contentWPt = contentPt * aspect
        let containerWPt = max(containerPt, ceil(contentWPt + 4))

        // 用 drawingHandler 让系统在任意 backing scale 下都调用我们重绘 → 永远锐利
        let img = NSImage(size: NSSize(width: containerWPt, height: containerPt),
                          flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .high
            let drawRect = CGRect(
                x: (containerWPt - contentWPt) / 2,
                y: (containerPt - contentPt) / 2,
                width: contentWPt, height: contentPt
            )
            ctx.draw(cropped, in: drawRect)
            return true
        }
        return img
    }
}

// MARK: - Main window
//
// 自定义 NSWindow：强制 sharingType = .readOnly。
// 原因：SwiftUI 的 SecureField 会让 AppKit 自动把 window.sharingType 改成
// .none（防截屏偷密码），副作用是用户截不了图。我们手动覆盖回 .readOnly，
// 让用户能正常 cmd+shift+4 截屏。
//   - getter 永远返回 .readOnly
//   - setter 直接吞掉外部赋值，AppKit 改不动
final class MainWindow: NSWindow {
    override var sharingType: NSWindow.SharingType {
        get { .readOnly }
        set { /* swallow */ }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: VPNController!
    var updater: UpdateChecker!
    #if DEBUG
    private var debugServer: DebugServer?
    #endif

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = VPNController()
        controller = c
        updater = UpdateChecker()
        updater.startPolling()
        #if DEBUG
        debugServer = DebugServer(vpn: c)
        debugServer?.start()
        #endif

        setupStatusItem()
        observeState()
    }

    // MARK: status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        // 所有内容（图标 + 速度文字）都画到一张 NSImage 里，自己控制布局
        button.imagePosition = .imageOnly
        button.title = ""

        // NSMenu 自带左右键支持，挂上 delegate 在弹出前实时重建
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshStatusItem()
    }

    /// 监听 VPN 状态、速率、显示开关，任何变化都立刻刷新菜单栏图标/标题
    private func observeState() {
        controller.$isConnected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        controller.$showSpeedInMenuBar
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        // 直接订阅速率发布者 —— 每次 pollTimer 刷新速率（1Hz）都重画
        Publishers.CombineLatest(controller.$trafficInRate, controller.$trafficOutRate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if self.controller.isConnected, self.controller.showSpeedInMenuBar {
                    self.refreshStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = composeStatusImage()
        // 整体淡化：未连接时半透明（不变黑，跟随明暗模式自动适配）
        button.alphaValue = controller.isConnected ? 1.0 : 0.4
    }

    /// 把图标 + （可选）两行速度文字合成成一张 template NSImage，
    /// 自己负责在 22pt 高度内 vertical center，避免 NSButton 多行文字默认顶对齐的坑。
    private func composeStatusImage() -> NSImage {
        let icon = MenuBarIcon.template()
        // 纯代理模式下没有 utun 接口，拿不到流量数据 —— 强制不显示，避免一直显示 0
        let showSpeed = controller.isConnected
            && controller.showSpeedInMenuBar
            && !controller.useProxyMode
        if !showSpeed { return icon }

        let downStr = VPNController.formatRate(controller.trafficInRate)
        let upStr = VPNController.formatRate(controller.trafficOutRate)

        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        // template image：颜色用 .black，最终由系统按菜单栏明暗自动反色
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let downSize = (downStr as NSString).size(withAttributes: textAttrs)
        let upSize = (upStr as NSString).size(withAttributes: textAttrs)
        let textW = max(downSize.width, upSize.width)

        let iconW = icon.size.width
        let iconH = icon.size.height
        let iconGap: CGFloat = 4
        let trailing: CGFloat = 2
        let totalW = ceil(iconW + iconGap + textW + trailing)
        let totalH: CGFloat = 22       // 菜单栏标准高度

        let image = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
            // 图标：vertical center
            icon.draw(
                in: NSRect(x: 0, y: (totalH - iconH) / 2, width: iconW, height: iconH),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
            // 两行文字：vertical center in totalH
            // 单行 9pt 视觉高 ~9pt，两行共 18pt，22pt 容器 → 上下各 2pt 间距
            let lineH: CGFloat = 9
            let blockH: CGFloat = lineH * 2
            let blockBottom = (totalH - blockH) / 2     // ≈ 2
            let textX = iconW + iconGap
            // NSString.draw(at:) 把 y 当 bounding box 底部（unflipped 坐标，Y 向上）
            (upStr as NSString).draw(
                at: NSPoint(x: textX, y: blockBottom - 1),
                withAttributes: textAttrs
            )
            (downStr as NSString).draw(
                at: NSPoint(x: textX, y: blockBottom + lineH - 1),
                withAttributes: textAttrs
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: window

    func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView()
                    .environmentObject(controller)
                    .environmentObject(updater)
                    .environment(\.openMainWindow, OpenMainWindowAction { [weak self] in
                        self?.showMainWindow()
                    })
            )
            hosting.sizingOptions = .preferredContentSize

            let window = MainWindow(contentViewController: hosting)
            window.title = "XDVPN"
            window.titleVisibility = .visible
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false

            let screenH = NSScreen.main?.visibleFrame.height ?? 800
            window.contentMinSize = NSSize(width: Design.mainWindowWidth, height: 300)
            window.contentMaxSize = NSSize(width: Design.mainWindowWidth, height: screenH - 40)

            window.setFrameAutosaveName("com.kafeifei.xdvpn.MainWindow")
            window.center()
            window.delegate = self
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let proxyRunning = OpenConnectRunner.isProxyModeRunning
        let kernelRunning = SudoersInstaller.isInstalled && OpenConnectRunner.isRunning

        guard proxyRunning || kernelRunning else { return .terminateNow }

        DispatchQueue.global(qos: .userInitiated).async {
            if proxyRunning { OpenConnectRunner.disconnectProxyMode() }
            if kernelRunning { try? OpenConnectRunner.cleanup() }
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - NSMenuDelegate
//
// 每次菜单弹出前重建：把当前 VPN 状态、协议、分流配置、速率全部反映到菜单项里。
// 这样不用维护一堆增量更新逻辑，开销 < 1ms。
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(into: menu)
    }

    private func buildMenu(into menu: NSMenu) {
        // 1. 状态行
        menu.addItem(makeStatusHeaderItem())
        menu.addItem(makeServerInfoItem())

        if controller.isConnected, let t = controller.connectedAt {
            menu.addItem(NSMenuItem.separator())
            let dur = Int(Date().timeIntervalSince(t))
            menu.addItem(makeDisabledItem("时长  \(VPNController.formatDuration(dur))"))
            // 纯代理模式拿不到流量数据（ocproxy 在用户态，没在 utun 接口上）
            if !controller.useProxyMode {
                let up = VPNController.formatRate(controller.trafficOutRate)
                let down = VPNController.formatRate(controller.trafficInRate)
                menu.addItem(makeDisabledItem("↑ \(up)   ↓ \(down)"))
                menu.addItem(makeDisabledItem("累计  ↑ \(VPNController.formatBytes(controller.trafficOut))   ↓ \(VPNController.formatBytes(controller.trafficIn))"))
            } else {
                menu.addItem(makeDisabledItem("SOCKS5  127.0.0.1:\(controller.socks5Port)"))
            }
        }

        // 2. 连接/断开
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeConnectActionItem())

        // 3. 显示主窗口
        menu.addItem(NSMenuItem.separator())
        let showWin = NSMenuItem(title: "显示主窗口…", action: #selector(menuShowMainWindow), keyEquivalent: "m")
        showWin.target = self
        menu.addItem(showWin)

        // 4. 协议子菜单
        menu.addItem(makeProtocolSubmenu())

        // 5. 运行模式子菜单（三选一；split 模式下额外显示 CIDR 配置）
        menu.addItem(makeModeSubmenu())

        // 6. 速度外显开关 —— 仅在能拿到流量数据时（即非纯代理模式）才展示
        if !controller.useProxyMode {
            menu.addItem(NSMenuItem.separator())
            let speedToggle = NSMenuItem(title: "在状态栏显示速度", action: #selector(toggleShowSpeed), keyEquivalent: "")
            speedToggle.target = self
            speedToggle.state = controller.showSpeedInMenuBar ? .on : .off
            menu.addItem(speedToggle)
        }

        // 7. 帮助 / 高级 子菜单
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeHelpSubmenu())
        if controller.sudoConfigured {
            menu.addItem(makeAdvancedSubmenu())
        }

        // 8. 更新提示（第一层可见）
        if updater.hasUpdate {
            menu.addItem(NSMenuItem.separator())
            let update = NSMenuItem(
                title: "新版本 v\(updater.latestVersion ?? "") 可用",
                action: #selector(menuShowUpdate),
                keyEquivalent: "u")
            update.target = self
            if let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
                update.image = dot.withSymbolConfiguration(cfg)
            }
            menu.addItem(update)
        }

        // 9. 退出
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出 XDVPN", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: 菜单项构造

    private func makeDisabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeStatusHeaderItem() -> NSMenuItem {
        let title: String
        let symbolName: String
        let color: NSColor
        if controller.isConnected {
            title = "已连接"
            symbolName = "circle.fill"
            color = NSColor(red: 0.42, green: 0.74, blue: 0.55, alpha: 1)
        } else if controller.isBusy {
            title = controller.statusText.isEmpty ? "处理中" : controller.statusText
            symbolName = "circle.dotted"
            color = .systemOrange
        } else {
            title = "未连接"
            symbolName = "circle"
            color = .secondaryLabelColor
        }
        let item = makeDisabledItem(title)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            item.image = symbol.withSymbolConfiguration(cfg)
        }
        return item
    }

    private func makeServerInfoItem() -> NSMenuItem {
        let text: String
        if controller.server.isEmpty {
            text = "尚未配置账户"
        } else {
            let user = controller.user.isEmpty ? "?" : controller.user
            text = "\(user)@\(controller.server)"
        }
        let item = makeDisabledItem(text)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return item
    }

    /// 纯代理模式不依赖 sudo
    private var needsSudoBootstrap: Bool {
        !controller.useProxyMode && !controller.sudoConfigured
    }

    private func makeConnectActionItem() -> NSMenuItem {
        let title: String
        if controller.isBusy { title = "请稍候…" }
        else if controller.isConnected { title = "断开连接" }
        else if needsSudoBootstrap { title = "首次配置并连接" }
        else { title = "连接" }

        let item = NSMenuItem(title: title, action: #selector(menuToggleConnection), keyEquivalent: "k")
        item.target = self
        item.isEnabled = !controller.isBusy &&
            (controller.isConnected || needsSudoBootstrap || controller.canConnect)
        return item
    }

    private func makeProtocolSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "协议", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "协议")
        for p in OpenConnectRunner.protocols {
            let item = NSMenuItem(title: p, action: #selector(menuSelectProtocol(_:)), keyEquivalent: "")
            item.target = self
            item.state = (p == controller.protocolName) ? .on : .off
            item.representedObject = p
            item.isEnabled = !controller.isConnected && !controller.isBusy
            sub.addItem(item)
        }
        parent.submenu = sub
        parent.isEnabled = !controller.isConnected && !controller.isBusy
        return parent
    }

    private func makeModeSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "运行模式", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "运行模式")

        let modeChangeAllowed = !controller.isConnected && !controller.isBusy

        // 三选一（互斥）
        for mode in VPNController.RunningMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(menuSelectMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = (controller.runningMode == mode) ? .on : .off
            item.representedObject = mode.rawValue
            item.isEnabled = modeChangeAllowed
            sub.addItem(item)
        }

        // 分流模式专属：CIDR 子配置
        if controller.runningMode == .split {
            sub.addItem(NSMenuItem.separator())
            let header = makeDisabledItem("分流网段")
            header.attributedTitle = NSAttributedString(
                string: header.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
            sub.addItem(header)

            let preset10 = NSMenuItem(title: "10.0.0.0/8", action: #selector(toggleSplit10), keyEquivalent: "")
            preset10.target = self
            preset10.state = controller.splitPreset10 ? .on : .off
            preset10.isEnabled = !controller.isConnected && !controller.isBusy
            sub.addItem(preset10)

            let preset172 = NSMenuItem(title: "172.16.0.0/12", action: #selector(toggleSplit172), keyEquivalent: "")
            preset172.target = self
            preset172.state = controller.splitPreset172 ? .on : .off
            preset172.isEnabled = !controller.isConnected && !controller.isBusy
            sub.addItem(preset172)

            let preset192 = NSMenuItem(title: "192.168.0.0/16  (可能与本地 LAN 冲突)", action: #selector(toggleSplit192), keyEquivalent: "")
            preset192.target = self
            preset192.state = controller.splitPreset192 ? .on : .off
            preset192.isEnabled = !controller.isConnected && !controller.isBusy
            sub.addItem(preset192)

            sub.addItem(NSMenuItem.separator())
            let hint = makeDisabledItem("自定义 CIDR / 域名规则请在主窗口设置")
            hint.attributedTitle = NSAttributedString(
                string: hint.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
            sub.addItem(hint)
        }

        parent.submenu = sub
        return parent
    }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = VPNController.RunningMode(rawValue: raw) else { return }
        controller.runningMode = mode
        controller.savePrefs()
    }

    private func makeHelpSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "帮助")

        let github = NSMenuItem(title: "打开 GitHub 仓库", action: #selector(menuOpenGitHub), keyEquivalent: "")
        github.target = self
        sub.addItem(github)

        let update = NSMenuItem(
            title: updater.hasUpdate ? "有新版本可用…" : "检查更新…",
            action: #selector(menuCheckUpdate),
            keyEquivalent: "")
        update.target = self
        if updater.hasUpdate, let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            update.image = dot.withSymbolConfiguration(cfg)
        }
        sub.addItem(update)

        let version = makeDisabledItem("版本  v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        version.attributedTitle = NSAttributedString(
            string: version.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        sub.addItem(NSMenuItem.separator())
        sub.addItem(version)

        parent.submenu = sub
        return parent
    }

    private func makeAdvancedSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "高级", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "高级")
        let uninstall = NSMenuItem(title: "卸载免密 sudo 配置", action: #selector(menuUninstallSudo), keyEquivalent: "")
        uninstall.target = self
        sub.addItem(uninstall)
        parent.submenu = sub
        return parent
    }

    // MARK: 菜单项动作

    @objc private func menuToggleConnection() {
        if controller.isConnected { controller.disconnect() }
        else if needsSudoBootstrap { controller.installSudoers(thenConnect: true) }
        else if controller.canConnect { controller.connect() }
        else { showMainWindow() }
    }
    @objc private func menuShowMainWindow() { showMainWindow() }
    @objc private func menuOpenGitHub() {
        if let url = URL(string: "https://github.com/kafeifei/XDVPN") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuCheckUpdate() {
        if updater.hasUpdate { updater.showUpdateWindow() }
        else { updater.check() }
    }
    @objc private func menuShowUpdate() { updater.showUpdateWindow() }
    @objc private func menuUninstallSudo() { controller.uninstallSudoers() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuSelectProtocol(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        controller.protocolName = p
        controller.savePrefs()
    }

    @objc private func toggleSplitEnabled() {
        controller.splitEnabled.toggle()
        controller.savePrefs()
    }
    @objc private func toggleSplit10() { controller.splitPreset10.toggle(); controller.savePrefs() }
    @objc private func toggleSplit172() { controller.splitPreset172.toggle(); controller.savePrefs() }
    @objc private func toggleSplit192() { controller.splitPreset192.toggle(); controller.savePrefs() }

    @objc private func toggleShowSpeed() {
        controller.showSpeedInMenuBar.toggle()
    }
}
