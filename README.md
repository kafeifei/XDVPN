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

下载 [Release](https://github.com/kafeifei/XDVPN/releases/latest) 里的 `XDVPN-v*.zip`，解压后把 `XDVPN.app` 拖进 `/Applications/`。

Release 包已内置 OpenConnect；用户机器不需要预装 Homebrew 或 openconnect。

### 首次打开

XDVPN 目前未做 Apple 公证，首次打开可能会被 macOS Gatekeeper 拦截。推荐流程：

1. 双击 `/Applications/XDVPN.app`，看到系统拦截提示后点“完成”或关闭弹窗。
2. 打开“系统设置 → 隐私与安全性”。
3. 在页面底部找到 XDVPN 的拦截提示，点击“仍要打开”。
4. 再次确认打开。

如果系统设置里没有出现“仍要打开”，也可以在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/XDVPN.app
open /Applications/XDVPN.app
```

## 使用

1. 菜单栏出现锁盾图标，点开弹窗
2. 底部点"一键配置"安装系统组件（仅首次）
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
<user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.kafeifei.xdvpn/xdvpn-openconnect
<user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.kafeifei.xdvpn/xdvpn-cleanup
```

**Helper 脚本**（位于 `/Library/PrivilegedHelperTools/com.kafeifei.xdvpn/`，目录和文件均为 root:wheel、用户不可写）：

| 文件 | 作用 |
|------|------|
| `openconnect/` | 从 App 内置资源安装来的 OpenConnect + 依赖 dylib |
| `xdvpn-openconnect` | 受控 OpenConnect wrapper，固定参数与 route script，只接受协议/用户/服务器 |
| `xdvpn-route-script` | openconnect `--script` 调用，做 def1 路由 + DNS + 写 session |
| `xdvpn-cleanup` | 停 openconnect + 按 session 记录逐项清理，幂等 |
| `xdvpn-dns-proxy` | 域名分流时代理指定后缀 DNS，并只清理带 XDVPN 标记的 resolver 文件 |

**凭据**：密码存 Keychain（`kSecAttrAccessibleWhenUnlocked`），其他字段 UserDefaults。

## 第三方依赖

Release 包内置了以下第三方软件，完整许可证文本见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)：

| 组件 | 许可证 | 用途 |
|------|--------|------|
| [OpenConnect](https://www.infradead.org/openconnect/) | LGPL-2.1 | VPN 客户端核心 |
| [ocproxy](https://github.com/cernekee/ocproxy) | BSD-3-Clause | 用户态 SOCKS5 代理（纯代理模式） |
| [libevent](https://libevent.org/) | BSD-3-Clause | ocproxy 运行时依赖 |

OpenConnect 以 LGPL-2.1 授权，以动态链接方式使用；源码可从上游仓库获取。

## 构建 & 发布

本地构建 release 包需要用 Homebrew 提供 OpenConnect 和 ocproxy 作为打包输入；版本范围由 `Vendor/openconnect.lock` 锁定为同一 major/minor、允许 patch 更新。

```bash
brew install openconnect ocproxy   # 仅构建者需要，用户安装 Release 不需要
./build.sh                         # 构建 .app
./build.sh release                 # 构建 + 打包 zip
```

改 `Resources/Info.plist` 版本号，并同步更新 `RELEASE_NOTES.md` 的版本标题和“更新了什么”。
打 tag 推送后，GitHub Actions 会校验两处版本一致，再自动构建并发布 Release。

## 卸载

菜单 → ⋯ → "卸载免密 sudo 配置"，然后 `rm -rf /Applications/XDVPN.app`。

## License

XDVPN 自身代码以 [MIT](LICENSE) 许可证发布。

Release 包内置的第三方组件各有其许可证（LGPL-2.1、BSD-3-Clause），详见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
