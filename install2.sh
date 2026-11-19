#!/data/data/com.termux/files/usr/bin/bash
# my-vpn-hotspot2 - Termux + gost, rooted Android only
set -Eeuo pipefail

APP_NAME="my-vpn-hotspot2"
APP_DIR="$HOME/.my-vpn-hotspot2"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
GOST_VERSION="3.0.0"

info() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

printf '\n================================================\n'
printf '  %s 安装程序\n' "$APP_NAME"
printf '  仅支持已 Root 的 Android 设备\n'
printf '================================================\n\n'

info "检查 Root 权限..."
ROOT_UID="$(su -c 'id -u' 2>/dev/null | tail -n 1 | tr -d '\r')"
[ "$ROOT_UID" = "0" ] || die "未获得 Root 权限。请先在 Magisk / KernelSU 中授权 Termux，然后重新运行。"

case "$(uname -m)" in
  aarch64|arm64) GOST_ARCH="linux_arm64" ;;
  *) die "当前架构 $(uname -m) 暂未纳入此安装包，当前仅提供 Android ARM64 版本。" ;;
esac

info "安装依赖（screen、curl、tar、coreutils）..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y screen curl tar coreutils procps

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"
for f in supervisor.sh watchdog.sh start.sh stop.sh restart.sh status.sh uninstall.sh; do
  [ -f "$SOURCE_DIR/$f" ] || die "缺少项目文件：$f。请从完整的 V2 仓库目录运行 install.sh。"
  install -m 700 "$SOURCE_DIR/$f" "$APP_DIR/$f"
done

if [ ! -x "$APP_DIR/gost" ]; then
  info "下载 gost ${GOST_VERSION}（${GOST_ARCH}）..."
  TMP_TAR="$APP_DIR/gost.tar.gz"
  URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_${GOST_ARCH}.tar.gz"
  if ! curl -fL --retry 2 --connect-timeout 15 -o "$TMP_TAR" "$URL"; then
    warn "GitHub 下载失败，尝试备用代理..."
    curl -fL --retry 2 --connect-timeout 15 -o "$TMP_TAR" "https://gh-proxy.com/$URL" || die "gost 下载失败，请检查网络后重新运行。"
  fi
  tar -tzf "$TMP_TAR" >/dev/null 2>&1 || die "gost 压缩包校验失败。"
  tar -xzf "$TMP_TAR" -C "$APP_DIR" gost
  rm -f "$TMP_TAR"
  chmod 700 "$APP_DIR/gost"
fi
[ -x "$APP_DIR/gost" ] || die "未找到可执行的 gost 文件。"

read -r -p "设置 SOCKS5 端口（回车随机分配）: " SOCKS_PORT
SOCKS_PORT="${SOCKS_PORT:-$(shuf -i 10000-65535 -n 1)}"
read -r -p "设置 HTTP 端口（回车随机分配）: " HTTP_PORT
HTTP_PORT="${HTTP_PORT:-$(shuf -i 10000-65535 -n 1)}"
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }
valid_port "$SOCKS_PORT" || die "SOCKS5 端口必须是 1024–65535 之间的整数。"
valid_port "$HTTP_PORT" || die "HTTP 端口必须是 1024–65535 之间的整数。"
[ "$SOCKS_PORT" != "$HTTP_PORT" ] || die "SOCKS5 和 HTTP 不能使用同一个端口。"

printf '\n'
warn "建议设置代理认证，避免同一局域网内其他设备未经授权连接。"
read -r -p "代理用户名（回车表示不启用认证）: " PROXY_USER
PROXY_PASS=""
if [ -n "$PROXY_USER" ]; then
  read -r -s -p "代理密码: " PROXY_PASS
  printf '\n'
  [ -n "$PROXY_PASS" ] || die "启用认证时密码不能为空。"
fi

yaml_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/}
  printf '%s' "$s"
}
AUTH_BLOCK=""
if [ -n "$PROXY_USER" ]; then
  USER_ESC="$(yaml_escape "$PROXY_USER")"
  PASS_ESC="$(yaml_escape "$PROXY_PASS")"
  printf -v AUTH_BLOCK '    auth:\n      username: "%s"\n      password: "%s"' "$USER_ESC" "$PASS_ESC"
fi

cat > "$APP_DIR/config.yaml" <<EOF
services:
  - name: service-socks5
    addr: ":${SOCKS_PORT}"
    resolver: resolver-0
${AUTH_BLOCK}
    handler:
      type: socks5
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp

  - name: service-http
    addr: ":${HTTP_PORT}"
    resolver: resolver-0
${AUTH_BLOCK}
    handler:
      type: http
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp

resolvers:
  - name: resolver-0
    nameservers:
      - addr: tls://8.8.8.8:853
        prefer: ipv4
        ttl: 5m0s
        async: true
      - addr: tls://8.8.4.4:853
        prefer: ipv4
        ttl: 5m0s
        async: true
      - addr: tls://[2001:4860:4860::8888]:853
        prefer: ipv6
        ttl: 5m0s
        async: true
      - addr: tls://[2001:4860:4860::8844]:853
        prefer: ipv6
        ttl: 5m0s
        async: true
EOF
chmod 600 "$APP_DIR/config.yaml"
cat > "$APP_DIR/settings.env" <<EOF
SOCKS_PORT=$SOCKS_PORT
HTTP_PORT=$HTTP_PORT
EOF
chmod 600 "$APP_DIR/settings.env"

BASHRC="$HOME/.bashrc"
MARKER="# === MY_VPN_HOTSPOT2_AUTOSTART ==="
touch "$BASHRC"
if ! grep -Fq "$MARKER" "$BASHRC"; then
  cat >> "$BASHRC" <<'BASHRC_BLOCK'

# === MY_VPN_HOTSPOT2_AUTOSTART ===
if [ -x "$HOME/.my-vpn-hotspot2/start.sh" ]; then
  ( sleep 2; bash "$HOME/.my-vpn-hotspot2/start.sh" >/dev/null 2>&1 ) &
fi
BASHRC_BLOCK
fi

BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/20-my-vpn-hotspot2" <<'BOOT_SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock >/dev/null 2>&1 || true
sleep 10
bash "$HOME/.my-vpn-hotspot2/start.sh"
BOOT_SCRIPT
chmod 700 "$BOOT_DIR/20-my-vpn-hotspot2"

info "启动 gost 和 watchdog..."
bash "$APP_DIR/start.sh"
sleep 2

printf '\n================================================\n'
printf '\033[0;32mV2 安装完成\033[0m\n'
printf 'SOCKS5 端口：%s\n' "$SOCKS_PORT"
printf 'HTTP 端口  ：%s\n' "$HTTP_PORT"
if [ -n "$PROXY_USER" ]; then
  printf '认证       ：已启用（用户名：%s）\n' "$PROXY_USER"
else
  printf '认证       ：未启用\n'
fi
printf '\n常用命令：\n'
printf '  bash ~/.my-vpn-hotspot2/status.sh   查看状态\n'
printf '  bash ~/.my-vpn-hotspot2/restart.sh  重启服务\n'
printf '  bash ~/.my-vpn-hotspot2/stop.sh     停止服务\n'
printf '  tail -f ~/.my-vpn-hotspot2/gost.log 查看 gost 日志\n'
printf '================================================\n'
printf '\n注意：Termux:Boot 需要单独安装并至少打开一次，才能实现 Android 开机启动。\n'
