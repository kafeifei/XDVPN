# XDVPN

极简 macOS 菜单栏 VPN 客户端，openconnect 的 GUI 包装。

不信任闭源 VPN 客户端，又烦每次手敲 `sudo openconnect ...` 和输密码，而且 openconnect 命令行不能保存密码，所以自己做了一个。

## 特性

- 菜单栏常驻，无 Dock 图标
- 一次授权，之后连接/断开零弹窗
- 密码存 Keychain，7 天无活动弹 Touch ID
- 崩溃不坏路由（def1 技巧，不碰系统默认路由）
- 启动自愈 + 退出自清 + 休眠唤醒自动重连
- 支持 anyconnect / nc / gp / pulse / f5 / fortinet / array

## 安装

```bash
brew install openconnect   # 前置依赖
```

下载 [Release](https://github.com/kafeifei/XDVPN/releases/latest)，或自己构建：

```bash
./build.sh && open build/XDVPN.app
```

> 未经 Apple 公证，首次打开需：系统设置 → 隐私与安全性 → "仍要打开"。
> 自己 `./build.sh` 的不受此限制。

## 使用

1. 菜单栏出现锁盾图标，点开弹窗
2. 底部点"一键配置"免密 sudo（仅首次）
3. 填服务器、用户名、密码，点连接

## 路由安全

用 def1 技巧替代 vpnc-script：加两条 `/1` 路由覆盖 default，**不替换**系统原有默认路由。

```
route add -net 0.0.0.0/1   -interface utun4
route add -net 128.0.0.0/1 -interface utun4
```

openconnect 崩溃 → kernel 关 fd → utun 销毁 → `/1` 路由自动消失 → 网络立刻恢复。残留的 DNS 和 host route 由下次启动时的 cleanup 按 session 记录逐项删除。

## 安全

**sudoers**（2 条，仅白名单固定路径）：

```
<user> ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect
<user> ALL=(root) NOPASSWD: /usr/local/libexec/xdvpn-cleanup
```

**Helper 脚本**（root:wheel 0755，用户不可写）：

| 文件 | 作用 |
|------|------|
| `xdvpn-route-script` | openconnect `--script` 调用，做 def1 路由 + DNS + 写 session |
| `xdvpn-cleanup` | 停 openconnect + 按 session 记录逐项清理，幂等 |

**凭据**：密码存 Keychain（`kSecAttrAccessibleWhenUnlocked`），其他字段 UserDefaults。

## 构建 & 发布

```bash
./build.sh              # 构建 .app
./build.sh release      # 构建 + 打包 zip
```

改 `Resources/Info.plist` 版本号，打 tag 推送，GitHub Actions 自动发 Release。

## 卸载

菜单 → ⋯ → "卸载免密 sudo 配置"，然后 `rm -rf /Applications/XDVPN.app`。

## License

MIT
