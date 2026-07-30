# my-vpn-hotspot

基于 Termux + gost + unbound，将手机上已配置好的系统级 VPN 通过热点/socks5 分享给其他设备使用。

## 使用方法

1. 安装 Termux（推荐 GitHub Release 版）
2. 需要 root（Magisk/KernelSU）
3. 运行：

\`\`\`bash
curl -o install.sh https://raw.githubusercontent.com/jskdkdkdkdsjjsjsks-coder/my-vpn-hotspot/main/install.sh
bash install.sh
\`\`\`

## 功能
- socks5/http 代理（可设密码）
- 热点透明转发（自动分流国内/国外流量）
- 内置 DNS 解析修复，避免 DNS 污染和解析异常
## 致谢

- 基础思路参考自 [yonggekkk/google_vpn_proxy](https://github.com/yonggekkk/google_vpn_proxy)
- 代理转发核心使用 [go-gost/gost](https://github.com/go-gost/gost)
- DNS 解析使用 [NLnetLabs/unbound](https://github.com/NLnetLabs/unbound)
- 终端环境基于 [Termux](https://github.com/termux/termux-app)
- 本项目的脚本整合、调试过程借助 AI 助手（Claude by Anthropic、ChatGPT by OpenAI）完成

## 免责声明

本项目仅供技术学习与个人使用交流，作者不对使用本脚本产生的任何后果负责，包括但不限于账号异常、服务限制、数据丢失等。使用者应自行了解并遵守相关服务的用户协议，因使用本项目造成的一切后果由使用者自行承担，与代码来源、开发过程中使用的工具无关。
