# my-vpn-hotspot

一套基于 Termux + gost + unbound 的自动化脚本，把手机上已配置好的系统级 VPN 通过热点透明转发或 socks5/http 代理分享给其他设备使用。内置崩溃自愈、僵尸进程清理、DNS 污染修复等机制，专门针对 Android 长时间后台运行场景做了大量稳定性加固。

## 前置要求

- 一台已经能正常使用系统级 VPN 的 Android 手机
- [Termux](https://github.com/termux/termux-app/releases)（务必用 GitHub Release 版，Google Play 版从 2021 年起已不再维护）
- Root 权限（Magisk / KernelSU），用于操作 iptables 实现透明转发

## 使用方法

```bash
curl -o install.sh https://raw.githubusercontent.com/jskdkdkdkdsjjsjsks-coder/my-vpn-hotspot/main/install.sh
bash install.sh
```

按提示设置端口（回车用随机端口）和代理密码（强烈建议设置，否则同一 WiFi 下任何人都能蹭用你的代理）。装完自动启动，无需额外操作。

## 功能

- socks5 / http 代理，支持用户名密码认证
- 热点透明转发：连热点的设备无需手动设代理，国内/国外流量自动分流
- 独立 DNS 解析器（unbound），修复常见的 DNS 污染和解析失败问题
- 崩溃自愈：核心进程（gost、DNS 服务）异常退出后自动重启
- 防重复启动：原子锁机制，杜绝同一服务被多次拉起
- 孤儿进程清理：定期检测并清理脱离监管的残留进程
- 热点网卡自动识别：不依赖固定命名规则，适应不同设备/系统版本的接口命名差异

## 常用命令

| 命令 | 作用 |
|---|---|
| `bash ~/check_status.sh` | 查看四个核心服务的运行状态 |
| `bash ~/diag.sh` | 完整诊断（进程、规则、DNS、代理连通性一次性检查） |
| `bash ~/reset_all.sh` | 一键清空重启所有服务，遇到疑难问题的首选恢复手段 |
| `cat ~/bashrc_start.log` | 查看历史启动/自愈日志 |

## 常见问题排查

**子设备显示"已连接但无法访问互联网"**
按顺序执行：`bash ~/diag.sh` 查看状态 → 若发现进程数异常（重复或缺失）执行 `bash ~/reset_all.sh` → 若一切正常但仍无法访问，大概率是 VPN 隧道本身的瞬时网络波动，重连一次热点或稍等片刻。

**某个特定网站/App 打不开，但其他网站正常**
可能是该网站走了 UDP/QUIC 协议绕过了透明转发（本方案仅转发 TCP），或者该 App 有自己的地理位置判断逻辑（读取 GPS、SIM 卡归属地等），与网络层无关。可先用浏览器访问同一网址排查是否为 App 自身问题。

**长时间运行后服务异常，需要频繁手动 reset**
Android 系统对后台进程的管理存在固有不确定性（内存紧张时可能被系统强制回收），加上 VPN 隧道本身的线路质量波动，这两类问题无法通过脚本完全消除。建议：
- 手机设置里将 Termux 的电池优化设为「无限制」
- 内存紧张（`free -h` 查看，`available` 长期低于 500MB）会显著增加进程被杀概率，适当清理后台 App 有帮助
- 遇到问题直接 `bash ~/reset_all.sh`，无需深究每次具体原因

## 致谢

- 基础思路参考自 [yonggekkk/google_vpn_proxy](https://github.com/yonggekkk/google_vpn_proxy)
- 代理转发核心使用 [go-gost/gost](https://github.com/go-gost/gost)
- DNS 解析使用 [NLnetLabs/unbound](https://github.com/NLnetLabs/unbound)
- 终端环境基于 [Termux](https://github.com/termux/termux-app)
- 本项目的脚本整合、调试过程借助 AI 助手（Claude by Anthropic、ChatGPT by OpenAI）完成

## 免责声明

本项目仅供技术学习与个人使用交流，作者不对使用本脚本产生的任何后果负责，包括但不限于账号异常、服务限制、数据丢失等。使用者应自行了解并遵守相关服务的用户协议，因使用本项目造成的一切后果由使用者自行承担，与代码来源、开发过程中使用的工具无关。
