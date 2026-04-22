# XDVPN

一个极简的 macOS 菜单栏 VPN 客户端，openconnect 的 GUI 包装。

为什么自己做：不信任闭源 VPN 客户端（如 Hillstone、AnyConnect Secure Client），但又烦每次手动敲 `sudo openconnect ...` 命令和输密码。

## 下载

直接下预编译版本：[Releases](https://github.com/kafeifei/XDVPN/releases/latest)

或自己构建（见[构建](#构建)）。

### 首次打开 Gatekeeper 拦截

App 未经 Apple 公证（个人项目没 $99/年开发者账号），首次打开需要放行一次：

- **方式 A**：系统设置 → 隐私与安全性 → 最下面"仍要打开"
- **方式 B**：Finder 里右键 `XDVPN.app` → 打开 → 再点打开
- **方式 C**：`xattr -d com.apple.quarantine /Applications/XDVPN.app`

想完全规避这一步，就自己 clone 后 `./build.sh`，本地 ad-hoc 签名不会被 quarantine。

## 特性

- **菜单栏常驻**：锁盾图标点开即弹窗，无 Dock 图标
- **一次配置，长期免密**：首次授权写入 `/etc/sudoers.d/xdvpn`（白名单仅 `openconnect` + 一个固定 cleanup helper），之后连接/断开零弹窗
- **密码存 Keychain**：勾选"记住密码"即自动填充
- **7 天 Touch ID 滚动窗口**：连接成功自动刷新；超过 7 天无连接则下次连接前弹一次 Touch ID
- **崩溃不坏路由**：v0.3 用 def1 技巧替代 vpnc-script，从不替换系统默认路由；openconnect 意外死掉后一条 `ifconfig utun destroy` 就恢复（见[路由安全](#路由安全)）
- **启动自愈**：每次 App 启动先扫自己上次留下的残余（pid、utun、DNS 注入、host route），逐项清掉
- **协议支持**：openconnect 原生全支持 —— anyconnect / nc / gp / pulse / f5 / fortinet / array

## 依赖

- macOS 14+（Sonoma 起）
- Apple Silicon 或 Intel
- [openconnect](https://www.infradead.org/openconnect/)（`brew install openconnect`）

## 构建

```bash
./build.sh              # 构建 .app
./build.sh release      # 构建 + 产出 XDVPN-v<version>.zip
open build/XDVPN.app
```

`build.sh` 仅用 Swift Package Manager，无需 Xcode IDE（命令行工具够了）。产物是 ad-hoc 签名的 `.app`。

### 发布新版本

改 `Resources/Info.plist` 里的 `CFBundleShortVersionString`，然后：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

GitHub Actions（`.github/workflows/release.yml`）会在 macOS runner 上自动构建、打包 zip、发 Release。

## 使用

1. 打开 App，菜单栏出现图标（未连=灰度、已连=橙色）
2. 点开，底部状态条右侧点"一键配置"免密 sudo（唯一一次管理员授权）
3. 选协议、填服务器（如 `vpn.example.com:8443`）、用户名、密码
4. 勾"记住密码"，点连接
5. 之后每次连接零弹窗

## 路由安全

**核心原则：只加我们自己的路由，不碰系统原有 default route。**

v0.1 / v0.2 用了 openconnect 默认的 vpnc-script，它 full tunnel 时会 `route delete default; route add default via utun`，即**替换掉**系统的默认路由。openconnect 崩溃 / 合盖换网 / 强杀 → 替换后的恢复路径没跑完 → 路由表残留 utun 指向 → 全局断网 → 必须重启 Mac。

v0.3 改用 OpenVPN 式的 **def1 技巧**，由我们自己装的 `/usr/local/libexec/xdvpn-route-script` 替代 vpnc-script：

```
route add -net 0.0.0.0/1   -interface utun4
route add -net 128.0.0.0/1 -interface utun4
```

两条 /1 前缀比 `default`（0.0.0.0/0）更具体，路由表"longest prefix match"让它俩赢，效果和"改 default 指向 utun"完全一样，但**系统原 default via en0 从未被修改**。

连接时我们加的每一项都被记录到 `/tmp/xdvpn.session`（write-ahead）。崩溃后：
- openconnect 死 → kernel close fd → utun 销毁 → 挂在 utun 上的 /1 路由自动一起消失 → **系统原 default 立刻是唯一 default，网恢复**
- 残留只剩 DNS 注入（scutil）和 VPN 服务器的 host route —— 下次 App 启动时 `xdvpn-cleanup` 按 session 记录逐项删

App 启动做的事 = Shadowsocks 那种"重启一下就好"的自动版本。

## 安全设计

### sudoers 规则（2 条）
```
your_user ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect
your_user ALL=(root) NOPASSWD: /usr/local/libexec/xdvpn-cleanup
```

仅授权两个固定二进制路径免密 sudo，不开放通配。

### helper 脚本（root:wheel 0755，用户不可写）

- **`/usr/local/libexec/xdvpn-route-script`**
  被 openconnect 通过 `--script=` 调用，做 def1 路由 + 注入 DNS + 写 session 文件。固定行为，不接受参数。
- **`/usr/local/libexec/xdvpn-cleanup`**
  App 启动 / 用户断开 / 合盖前调用，读 `/tmp/xdvpn.pid` 精确 SIGTERM 我们的 openconnect（不 `killall`），再按 `/tmp/xdvpn.session` 记录逐项 remove（DNS key、host route、残留 utun）。**幂等**，反复跑只会越跑越干净。

### 无 `--setuid`
早期版本加了 `--setuid` 想让 kill 免 sudo，但 openconnect 降权后无权执行 route script 管路由，断开时路由表会崩。现在 openconnect 全程 root。

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
│   ├── Info.plist
│   └── Icon.png
└── Sources/XDVPN/
    ├── XDVPNApp.swift          # @main + MenuBarExtra + 图标色彩切换
    ├── ContentView.swift       # 弹窗 UI
    ├── VPNController.swift     # 状态 + 2s 轮询 + 启动自愈 + sleep hook
    ├── OpenConnectRunner.swift # Process 启动 openconnect（passing --script）
    ├── SudoersInstaller.swift  # 安装/卸载 sudoers + 两个 helper 脚本
    ├── KeychainStore.swift     # Security.framework 包装
    └── BiometricGate.swift     # LAContext 7 天门槛
```

## 应急恢复

万一 XDVPN 本身装不起来或装坏了，手动跑 cleanup：

```bash
sudo bash ~/Desktop/xdvpn-restore.sh   # XDVPN 第一次运行后会把应急脚本放在桌面
# 或直接调 helper（helper 已安装时）
sudo /usr/local/libexec/xdvpn-cleanup
```

## 卸载

在菜单栏图标 → ⋯ → "卸载免密 sudo 配置" 删除 sudoers 和两个 helper。
删 App 本体：`rm -rf build/XDVPN.app /Applications/XDVPN.app`。
清 Keychain：钥匙串访问 → 搜 `com.kafeifei.xdvpn` 删除。

## License

MIT
