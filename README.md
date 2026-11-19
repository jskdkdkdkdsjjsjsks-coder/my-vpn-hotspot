# my-vpn-hotspot2

一套基于 **Termux + gost** 的 Android 代理共享脚本。项目延续第一版 `my-vpn-hotspot` 的设计思路：在手机上运行代理服务，将手机当前可用的网络通过 **SOCKS5 / HTTP 代理**提供给电脑、平板或其他设备使用。

如果手机已经连接系统级 VPN，并且 VPN 客户端没有将 Termux 排除在 VPN 隧道之外，那么通过本项目连接的代理流量也可以使用该 VPN 网络。实际流量路径仍取决于 Android 的 VPN 实现及客户端分流设置。

**第二版（V2）在保留代理服务、自动启动和故障自愈机制的基础上进行了精简：不需要 Root，不再提供热点透明转发，不操作 iptables，也不单独运行 unbound。** 其他设备需要手动填写手机的局域网 IP、代理端口和认证信息。

## 前置要求

- 一台 Android 手机。
- [Termux](https://github.com/termux/termux-app/releases)，建议使用官方 GitHub Releases 版本，不建议使用已停止维护的旧版 Google Play 版本。
- Android **ARM64 / aarch64** 设备。当前安装脚本提供 `linux_arm64` 版 gost。
- [Termux:Boot](https://github.com/termux/termux-boot)（可选）。只有需要手机重启后自动启动服务时才需要安装。
- 如果希望代理流量经过手机上已配置的系统级 VPN，请确认 VPN 客户端没有将 Termux 排除在 VPN 隧道之外。

> **不需要 Root 权限。** 安装和运行过程不会调用 `su`，不会修改 iptables、Android 系统 DNS 或热点网络配置，也不需要安装 `root-repo`、`x11-repo` 等额外仓库。

## 使用方法

在 Termux 中执行以下命令：

```bash
curl -o install.sh https://raw.githubusercontent.com/jskdkdkdkdsjjsjsks-coder/my-vpn-hotspot/main/install2.sh
bash install.sh
```

按提示设置 SOCKS5 / HTTP 端口（直接回车则随机分配）和代理用户名、密码。用户名留空表示不启用认证；建议设置认证，避免同一局域网内其他设备未经授权使用代理。

安装方式与第一版保持一致：**只需下载一个安装脚本并运行，不需要手动克隆仓库，也不需要另外下载配套脚本。** 安装器会在手机本地生成 gost 配置、supervisor、watchdog、启动 / 停止 / 重启 / 状态 / 卸载等管理脚本。

安装完成后，在电脑或其他设备的网络设置中手动填写：

- **代理服务器地址**：手机当前连接网络的局域网 IP。
- **SOCKS5 端口**：安装时设置或随机分配的 SOCKS5 端口。
- **HTTP 端口**：安装时设置或随机分配的 HTTP 端口。
- **认证信息**：安装时设置了用户名和密码时，客户端也需要填写对应信息。

手机与客户端设备需要处于能够互相访问的同一局域网内。设备即使连接的是手机热点，也需要在该设备上手动设置代理；V2 不会自动接管连接热点设备的全部流量。

## 功能

- **SOCKS5 代理**：支持用户名密码认证，配置中启用了 UDP 支持。
- **HTTP 代理**：支持用户名密码认证。
- **DNS-over-TLS 上游解析**：由 gost 使用配置文件中的 DNS-over-TLS 上游进行解析；不单独安装或运行 unbound，也不修改 Android 系统 DNS。
- **崩溃自愈**：supervisor 负责监控 gost；gost 异常退出后等待 5 秒并自动重新启动。
- **Watchdog 健康检查**：每 20 秒检查 gost 进程及本机 SOCKS5 监听端口；连续 3 次检查失败后，终止本项目自己的 gost 进程，再由 supervisor 自动拉起。
- **Screen 会话自愈**：检查时执行 `screen -wipe` 清理失效 socket；只把 `Detached`、`Attached`、`Multi` 视为有效会话，`Remote or dead` / `Unreachable` 不会被误判为服务仍在运行。V2 的 gost 监管会话缺失时会尝试重新建立。
- **防重复启动**：通过启动锁和独立 Screen 会话，避免重复启动 V2 服务。
- **自动启动**：打开 Termux 时会尝试启动服务；配合 Termux:Boot 可在 Android 重启后自动启动。
- **独立安装目录**：V2 的配置、脚本和日志保存在 `~/.my-vpn-hotspot2/`，与第一版文件分开。

## V2 不包含的功能

- 热点透明转发；连接手机热点的设备不会自动获得代理，需要在设备上手动配置 SOCKS5 / HTTP 代理。
- Root 权限、iptables NAT / REDIRECT 规则及热点网卡自动识别。
- 国内 / 国外 IP 分流名单及相关转发规则。
- 独立 unbound DNS 服务、DNS 重定向及第一版的 DNS 修复流程。

## 常用命令

| 命令 | 作用 |
|---|---|
| `bash ~/.my-vpn-hotspot2/status.sh` | 查看 gost、watchdog、Screen 会话及代理端口状态 |
| `bash ~/.my-vpn-hotspot2/start.sh` | 启动 V2 服务 |
| `bash ~/.my-vpn-hotspot2/stop.sh` | 停止 V2 服务 |
| `bash ~/.my-vpn-hotspot2/restart.sh` | 重启 V2 服务 |
| `tail -f ~/.my-vpn-hotspot2/gost.log` | 查看 gost 运行及重启日志 |
| `tail -f ~/.my-vpn-hotspot2/watchdog.log` | 查看 watchdog 健康检查及自愈日志 |
| `bash ~/.my-vpn-hotspot2/uninstall.sh` | 卸载 V2（会删除 V2 配置和日志，不主动删除第一版文件） |

## Watchdog 与故障自愈机制

Watchdog **只管理 V2 自己的 gost 进程和 Screen 会话，不管理其他应用或系统网络组件**：

1. **Supervisor 负责进程保活**：启动 gost 并等待进程退出；如果 gost 意外退出，记录日志，等待 5 秒后重新启动。
2. **Watchdog 定期检查**：每 20 秒检查一次 gost 进程及本机 SOCKS5 TCP 监听端口。
3. **连续异常时恢复**：SOCKS5 本机端口连续 3 次检查失败后，watchdog 会终止 V2 自己的 gost 进程，由 supervisor 检测到退出并重新拉起。
4. **Screen 会话异常处理**：启动及 watchdog 检查时执行 `screen -wipe`；`Remote or dead`、`Unreachable` 等失效状态不会被当作有效会话。若 V2 的 `gost2` 监管会话不可用，会尝试重新建立会话。
5. **避免外网波动造成误重启**：watchdog 检查的是本机进程和 SOCKS5 监听端口，不访问 Google 或其他外部网站判断网络状态。因此，VPN 上游或外网暂时不可达时，不会仅因为外网探测失败就重启 gost。
6. **监控范围有限**：watchdog 不检测 VPN 隧道是否真正连通，不检查其他应用、热点状态或系统 DNS。HTTP 端口状态可通过 `status.sh` 查看。

> Android 仍可能因省电策略、内存压力或厂商后台管理而同时终止 Termux、Screen 和 watchdog。进程被系统整体回收后，watchdog 无法在自身已停止的情况下独立复活；重新打开 Termux，或通过 Termux:Boot 触发启动脚本，才能重新拉起服务。

## 自动启动说明

- **打开 Termux 时启动**：安装器会在 `~/.bashrc` 中加入 V2 启动入口。
- **Android 开机后启动**：安装器会创建 `~/.termux/boot/20-my-vpn-hotspot2`。需要另外安装 [Termux:Boot](https://github.com/termux/termux-boot)，并至少手动打开一次，才能在设备开机后执行启动脚本。
- 建议将 Termux 和 Termux:Boot 的电池使用策略设为「不受限制」，并允许后台运行。部分 Android 厂商还需要单独允许自启动。

## 常见问题排查

**其他设备连接代理失败**

1. 确认手机和客户端设备连接在同一个可互通的局域网内。
2. 确认客户端填写的是手机当前的局域网 IP，而不是 `127.0.0.1`。
3. 检查客户端使用了正确的代理类型、端口、用户名和密码。
4. 在手机 Termux 中运行 `bash ~/.my-vpn-hotspot2/status.sh`，检查 gost 进程及 SOCKS5 / HTTP 端口是否正常。
5. 检查路由器是否启用了 AP 隔离 / 客户端隔离，以及手机系统是否限制了 Termux 的网络访问。

**代理能够连接，但流量没有经过手机 VPN**

检查 VPN 客户端的按应用分流设置，确认 Termux 没有被排除。V2 本身不创建 VPN 隧道，也不修改 VPN 客户端的分流策略。实际出口取决于 Android VPN 的路由和应用分流规则。

**`screen -ls` 出现大量 `Remote or dead`**

这类条目是 Screen 的失效 / 不可达会话记录，不代表 gost 一定已经退出，也不能据此判断代理仍在运行。V2 启动和 watchdog 检查时会执行 `screen -wipe`，并且只把 `Detached`、`Attached` 或 `Multi` 状态视为有效会话；失效的 `gost2` 会话不会被当成正常运行状态。也可以手动执行：

```bash
screen -wipe
bash ~/.my-vpn-hotspot2/start.sh
```

`screen -wipe` 用于清理当前 Termux 用户下的失效 Screen socket，不会主动结束仍在运行的有效会话。

**长时间运行后代理异常**

先查看状态和日志：

```bash
bash ~/.my-vpn-hotspot2/status.sh
tail -n 80 ~/.my-vpn-hotspot2/gost.log
tail -n 80 ~/.my-vpn-hotspot2/watchdog.log
```

再尝试重启：

```bash
bash ~/.my-vpn-hotspot2/restart.sh
```

如果 Termux 被 Android 系统整体回收，watchdog 也会随之停止。建议关闭 Termux 的电池优化，并检查系统的后台运行 / 自启动限制；需要开机自启时，请安装并启用 Termux:Boot。

## 与第一版共存

V2 使用独立目录 `~/.my-vpn-hotspot2/`，不会主动删除第一版文件。若两版同时运行，请为它们设置不同的 SOCKS5 / HTTP 端口，避免端口冲突。两版各自管理自己的 gost 进程和 Screen 会话。

## 致谢

- 基础思路参考自 [yonggekkk/google_vpn_proxy](https://github.com/yonggekkk/google_vpn_proxy)
- 代理核心使用 [go-gost/gost](https://github.com/go-gost/gost)
- 终端环境基于 [Termux](https://github.com/termux/termux-app)
- 本项目的脚本整合、调试过程借助 AI 助手（Claude by Anthropic、ChatGPT by OpenAI）完成

## 免责声明

本项目仅供技术学习与个人使用交流。使用者应自行了解并遵守相关服务的用户协议及所在地法律法规。作者不对使用本脚本产生的任何后果负责，包括但不限于账号异常、服务限制、数据丢失或网络连接问题。使用者应自行承担使用本项目所产生的风险与后果。
