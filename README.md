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
