# XDVPN

一个极简的 macOS 菜单栏 VPN 客户端，openconnect 的 GUI 包装。

为什么自己做：不信任闭源 VPN 客户端（如 Hillstone、AnyConnect Secure Client），但又烦每次手动敲 `sudo openconnect ...` 命令和输密码。

## 特性

- **菜单栏常驻**：锁盾图标点开即弹窗，无 Dock 图标
- **一次配置，长期免密**：首次授权写入 `/etc/sudoers.d/xdvpn`（白名单仅 `openconnect` + 一个固定 helper），之后连接/断开零弹窗
- **密码存 Keychain**：勾选"记住密码"即自动填充
- **7 天 Touch ID 滚动窗口**：连接成功自动刷新；超过 7 天无连接则下次连接前弹一次 Touch ID
- **安全断开**：断开时等待 vpnc-script 回收路由（最多 12 秒），绝不 `SIGKILL` 避免路由残留
- **协议支持**：openconnect 原生全支持 —— anyconnect / nc / gp / pulse / f5 / fortinet / array

## 依赖

- macOS 14+（Sonoma 起）
- Apple Silicon 或 Intel
- [openconnect](https://www.infradead.org/openconnect/)（`brew install openconnect`）

## 构建

```bash
./build.sh
open build/XDVPN.app
```

`build.sh` 仅用 Swift Package Manager，无需 Xcode IDE。产物是 ad-hoc 签名的 `.app`，首次启动若被 Gatekeeper 拦：右键 → 打开 一次即可。

## 使用

1. 打开 App，菜单栏出现锁盾图标
2. 点开，顶部黄条点"一键配置"免密 sudo（唯一一次管理员授权）
3. 选协议、填服务器（如 `vpn.example.com:8443`）、用户名、密码
4. 勾"记住密码"，点连接
5. 之后每次连接零弹窗

## 安全设计

### sudoers 规则
```
your_user ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect
your_user ALL=(root) NOPASSWD: /usr/local/libexec/xdvpn-stop
```

仅授权**两个固定二进制路径**免密 sudo，不开放通配。

### helper 脚本 `/usr/local/libexec/xdvpn-stop`
- root:wheel 0755，用户不可写 → 不能被篡改后滥用 sudo 权限
- 功能固化：只读 `/tmp/xdvpn.pid` → SIGTERM openconnect → 等 12 秒 → 不做 SIGKILL
- 退出前用 `ps -o comm=` 校验目标进程是 openconnect 才发信号

### 无 `--setuid`
早期版本加了 `--setuid` 想让 kill 免 sudo，但 openconnect 降权后无权执行 vpnc-script 回收路由，断开时路由表会崩。现在 openconnect 全程 root，退出时能完整 teardown。

### 凭据存储
- 密码：macOS Keychain，`kSecAttrAccessibleWhenUnlocked`
- 其他字段：UserDefaults
- 7 天活动窗口在 App 层用 Touch ID 把关

## 目录结构

```
XDVPN/
├── Package.swift
├── build.sh
├── Resources/
│   └── Info.plist
└── Sources/XDVPN/
    ├── XDVPNApp.swift          # @main + MenuBarExtra
    ├── ContentView.swift       # 弹窗 UI
    ├── VPNController.swift     # 状态机 + 轮询
    ├── OpenConnectRunner.swift # Process + stdin 管道启动 openconnect
    ├── SudoersInstaller.swift  # 安装/卸载 sudoers + helper
    ├── KeychainStore.swift     # Security.framework 包装
    └── BiometricGate.swift     # LAContext 7 天门槛
```

## 卸载

在菜单栏图标 → ⋯ → "卸载免密 sudo 配置" 删除 sudoers 和 helper。
删 App 本体：`rm -rf build/XDVPN.app /Applications/XDVPN.app`。
清 Keychain：钥匙串访问 → 搜 `com.kafeifei.xdvpn` 删除。

## License

MIT
