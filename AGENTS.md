# XDVPN Agent 工作规范

本文件适用于整个仓库。修改代码或运行应用前，必须先阅读并遵守。

## 项目概览

XDVPN 是一个面向 macOS 14+ 的菜单栏 VPN 客户端，使用 Swift 5.9、
Swift Package Manager、SwiftUI 和 AppKit 开发。项目包含两个可执行目标：

- `XDVPN`：主应用。
- `xdvpn-dns-proxy`：域名分流使用的特权 DNS 辅助程序。

重要入口：

- `Sources/XDVPN/main.swift`：真正的进程入口和防双开检查。
- `Sources/XDVPN/XDVPNApp.swift`：应用生命周期、状态栏菜单和主窗口。
- `Sources/XDVPN/ContentView.swift`：主窗口 UI。
- `Sources/XDVPN/VPNController.swift`：偏好设置和 VPN 生命周期。
- `Sources/XDVPN/SudoersInstaller.swift`：root 所有的 helper 和 sudoers 安装逻辑。
- `Sources/XDVPN/DebugServer.swift`：本地 UI／状态调试接口。
- `build.sh`：组装 Release App、内置依赖、签名和可选的 zip 打包。

## 工作约束

- 修改前先检查 `git status` 和相关 diff。保留用户已有改动，不得顺手格式化、
  覆盖或重写无关代码。
- 只做完成任务所需的最小、完整改动。沿用现有 Swift／AppKit／SwiftUI
  结构，不要引入第二套生命周期或状态模型。
- 不得给 `XDVPNApp` 添加 `@main`。必须先由 `main.swift` 执行防双开检查，
  然后才能初始化 SwiftUI。
- 保留 `Package.swift` 中显式定义的 `DEBUG`。SwiftPM 不会像 Xcode 工程一样
  隐式提供同等的条件编译标记。
- Release App 必须使用 App 内置的 OpenConnect 和 ocproxy。不得让用户运行时
  依赖其机器上的 Homebrew 安装。
- 修改 `SudoersInstaller.swift` 中任何生成出来的特权 helper 脚本后，必须递增
  `SudoersInstaller.helperVersion`，确保已安装的旧 helper 会被替换。
- 路由、DNS、sudoers、helper 安装、Keychain 数据、VPN 凭据和更新器替换逻辑
  都属于安全敏感代码。不得记录、输出、提交或返回凭据及未脱敏的敏感状态。
- 除非任务明确要求，否则不得 commit、push、打 tag、发布版本、修改 App／Build
  版本号或更新 `Vendor/openconnect.lock`。

## 本地 UI 调试——必须优先使用此入口

UI 改动不能以“编译成功”作为完成标准。XDVPN 在
`Sources/XDVPN/DebugServer.swift` 中内置了仅 Debug 构建启用的 HTTP 调试接口，
端口为 `19876`；Release 构建不包含该服务。

先构建 Debug 目标：

```bash
swift build -c debug
```

运行前，必须同时检查正在运行的 XDVPN 进程和调试端口的实际占用者：

```bash
ps -axo pid=,command= | rg '[/]XDVPN( |$)'
lsof -nP -iTCP:19876 -sTCP:LISTEN
```

不得因为 `19876` 有响应就认定它属于当前仓库。XDial 也使用这个端口。未经用户
允许，不得为了释放端口而结束 XDial、正式版 XDVPN 或任何其他进程。启动后必须
把 `/health` 返回的 PID 与自己启动的进程进行核对。

只有确认不会影响当前 VPN 会话时，才能启动本地 Debug 程序：

```bash
swift run -c debug XDVPN
```

启动 XDVPN 不是无副作用的 UI 预览。`VPNController` 会在启动时执行清理；如果
机器已安装特权 helper，它可能断开真实存在的 XDVPN／OpenConnect 会话。当用户
依赖当前 VPN 连接时，或正式版 XDVPN 仍在运行时，未经明确许可不得再启动 Debug
实例。

确认监听者确实是本次启动的 Debug 进程后，应优先通过本地接口观察和操作 UI，
不要直接进行盲目的屏幕坐标点击：

```bash
curl --fail --silent http://127.0.0.1:19876/health
curl --fail --silent http://127.0.0.1:19876/state
curl --fail --silent 'http://127.0.0.1:19876/ax?depth=12'
```

可用接口：

- `GET /health`：返回服务健康状态和 PID。
- `GET /state`：返回连接、配置和可见窗口状态。
- `GET /ax?depth=N`：返回应用的 Accessibility 树。
- `POST /action`：支持 `ax-press`、`ax-set-value`、`fake-update`、
  `clear-update`、`connect` 和 `disconnect`。

操作控件前先读取 `/ax`，确认真实存在的 title／id，并尽量同时指定 role。例如：

```bash
curl --fail --silent \
  -H 'Content-Type: application/json' \
  -d '{"action":"ax-press","title":"显示主窗口…","role":"AXMenuItem"}' \
  http://127.0.0.1:19876/action

curl --fail --silent \
  -H 'Content-Type: application/json' \
  -d '{"action":"fake-update","version":"99.0.0"}' \
  http://127.0.0.1:19876/action
```

修改状态时使用 `POST /action`，避免把参数写进 URL 或 shell 历史。
`connect` 和 `disconnect` 是真实 VPN 操作，不是模拟接口。UI 任务不得调用它们；
没有用户明确许可和真实网络测试方案时也不得调用。`ax-set-value` 会修改当前表单
状态，可能暴露或覆盖用户配置；只能使用非敏感测试值，并在测试后恢复受影响状态。
测试假更新后必须执行 `clear-update`。

该调试接口没有鉴权。只能通过 `127.0.0.1` 使用，不得暴露或转发端口；实现必须
保持在 `#if DEBUG` 内，并把 `/state` 和 `/ax` 的输出视为可能包含敏感信息。

SwiftPM 直接生成的 Debug 可执行文件适合迭代 UI 和状态，但不等同于 Release
安装包。它不能证明 App Bundle 资源、内置二进制、签名、sudoers 安装或更新器
替换流程正确。

## 验证要求

普通 Swift／UI 改动至少应完成：

1. 运行 `swift build -c debug`。
2. 运行 `swift build -c release`，检查条件编译差异。
3. 在允许安全启动的前提下，通过 `/health`、`/state` 和 `/ax` 核对目标 UI
   状态，并实际操作本次修改涉及的控件。
4. 观察真实窗口，覆盖窄屏／矮屏、滚动、禁用／处理中状态，以及相关 sheet 或
   更新窗口。
5. 明确报告编译了什么、实际操作验证了什么，以及哪些内容没有验证。

只有任务需要 `.app` 安装包时才运行 `./build.sh`。该脚本依赖预期版本的 Homebrew
构建输入，会内置依赖、签名 App，并替换 `build/` 下的生成物。只有明确需要
Release zip 时才运行 `./build.sh release`。

对于 VPN、helper、路由或 DNS 改动，编译成功和 UI 自动化都不能作为验收证据。
只有在用户明确允许中断性测试后，才能：

- 记录测试前的接口、路由、DNS、进程和 helper 状态；
- 实际运行涉及的连接模式；
- 验证真实数据链路以及预期的分流路由／DNS 行为；
- 断开后确认清理完成，并恢复测试前的基线状态。

不得仅仅为了让测试通过而断开或重连用户正在使用的 VPN。
