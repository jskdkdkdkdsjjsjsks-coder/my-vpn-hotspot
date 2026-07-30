# my-vpn-hotspot
# My VPN Hotspot Sharing

基于 Termux + gost + unbound，把手机的 Google VPN 通过热点/socks5 分享出去。

## 使用方法

1. 安装 Termux（推荐 GitHub Release 版，不要用 Google Play 版）
2. 需要 root（Magisk/KernelSU）
3. 运行：

\`\`\`bash
curl -o install.sh https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh
bash install.sh
\`\`\`

## 功能
- socks5/http 代理（可设密码）
- 热点透明转发（自动分流国内/国外）
- 修复了 DNS 污染和 NAT 回程问题
