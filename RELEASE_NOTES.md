# XDVPN v1.5.9

## 更新了什么

- 修复 Wi-Fi 按需连接把 macOS 返回的 `<redacted>` 隐私占位符误当成真实 SSID 的问题。
- 打开 Wi-Fi 按需连接设置时会主动申请读取 Wi-Fi 名称所需的定位权限；权限关闭时会显示原因和系统设置入口。
- 修复 SSID 读取失败后仍保留旧值的问题，避免按过期网络名称执行连接或断开规则。
- 更新日志在升级后首次启动时自动展示一次，也可随时从主窗口底部或菜单栏“帮助”中重新打开。

## 安装

1. 下载下面的 `XDVPN-v1.5.9.zip` 并解压。
2. 把 `XDVPN.app` 拖进 `/Applications/`。
3. 双击 `/Applications/XDVPN.app`；如果被 Gatekeeper 拦截，在“系统设置 → 隐私与安全性”中选择“仍要打开”。
4. 菜单栏出现锁盾图标后，首次使用请点“一键配置”安装系统组件。

## OpenConnect

OpenConnect 9.21 已随 XDVPN.app 内置，用户机器不需要预装 Homebrew 或 OpenConnect。

## 说明

- 未经 Apple 公证：个人自用项目，没有 Apple Developer 账号。源码公开，可自行运行 `./build.sh` 从头构建。
- 支持 macOS 14+。
