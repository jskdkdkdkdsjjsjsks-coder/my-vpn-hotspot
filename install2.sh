#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# my-vpn-hotspot2 - Termux + gost 单文件安装脚本
# 无需 Root；仅提供 SOCKS5 / HTTP 手动代理，不做热点透明转发
# 安装器会在本机生成所需的管理脚本，不依赖仓库中的其他文件
# Screen 自愈：Remote or dead 不算存活，会清理失效 socket 后重新拉起 V2 会话
# ============================================================
set -Eeuo pipefail
umask 077

APP_NAME="my-vpn-hotspot2"
APP_DIR="$HOME/.my-vpn-hotspot2"
GOST_VERSION="3.0.0"

info() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

printf '\n================================================\n'
printf '  %s 安装程序\n' "$APP_NAME"
printf '  无需 Root；不包含热点透明转发\n'
printf '================================================\n\n'

[ -n "${PREFIX:-}" ] || die "请在 Termux 中运行此脚本。"
command -v pkg >/dev/null 2>&1 || die "未检测到 Termux 的 pkg 命令。"

case "$(uname -m)" in
  aarch64|arm64) GOST_ARCH="linux_arm64" ;;
  *) die "当前架构 $(uname -m) 暂未支持；当前安装包仅提供 Android ARM64 版 gost。" ;;
esac

info "安装依赖（screen、curl、tar、coreutils、procps）..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y screen curl tar coreutils procps

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

# ---------- 下载 gost ----------
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

# ---------- 设置代理端口 ----------
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

printf '\n'
read -r -p "设置 SOCKS5 端口（回车随机分配）: " SOCKS_PORT
SOCKS_PORT="${SOCKS_PORT:-$(shuf -i 10000-65535 -n 1)}"
valid_port "$SOCKS_PORT" || die "SOCKS5 端口必须是 1024–65535 之间的整数。"

read -r -p "设置 HTTP 端口（回车随机分配）: " HTTP_PORT
HTTP_PORT="${HTTP_PORT:-$(shuf -i 10000-65535 -n 1)}"
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

# ---------- 生成 gost 配置 ----------
info "生成 gost 配置..."
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

# ---------- 生成 gost supervisor：只负责 gost 崩溃后重启 ----------
cat > "$APP_DIR/supervisor.sh" <<'SUPERVISOR_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set +e
APP_DIR="$HOME/.my-vpn-hotspot2"
GOST="$APP_DIR/gost"
CONFIG="$APP_DIR/config.yaml"
PID_FILE="$APP_DIR/gost.pid"
STOP_FLAG="$APP_DIR/stop.flag"
LOG="$APP_DIR/gost.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
GOST_PID=""
cleanup() {
  if [ -n "$GOST_PID" ] && kill -0 "$GOST_PID" 2>/dev/null; then
    kill -TERM "$GOST_PID" 2>/dev/null || true
    wait "$GOST_PID" 2>/dev/null || true
  fi
  if [ "$(cat "$PID_FILE" 2>/dev/null || true)" = "$GOST_PID" ]; then rm -f "$PID_FILE"; fi
  exit 0
}
trap cleanup INT TERM HUP
while true; do
  [ -f "$STOP_FLAG" ] && exit 0
  "$GOST" -C "$CONFIG" >> "$LOG" 2>&1 &
  GOST_PID=$!
  printf '%s\n' "$GOST_PID" > "$PID_FILE"
  log "gost 已启动，PID=$GOST_PID"
  wait "$GOST_PID"
  EXIT_CODE=$?
  if [ "$(cat "$PID_FILE" 2>/dev/null || true)" = "$GOST_PID" ]; then rm -f "$PID_FILE"; fi
  [ -f "$STOP_FLAG" ] && exit 0
  log "gost 异常退出（exit=${EXIT_CODE}），5 秒后自动重启"
  sleep 5
  GOST_PID=""
done
SUPERVISOR_EOF

# ---------- 生成 watchdog：只检查 gost 和本机 SOCKS5 端口 ----------
cat > "$APP_DIR/watchdog.sh" <<'WATCHDOG_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u
APP_DIR="$HOME/.my-vpn-hotspot2"
PID_FILE="$APP_DIR/gost.pid"
STOP_FLAG="$APP_DIR/stop.flag"
LOG="$APP_DIR/watchdog.log"
SOCKS_PORT="$(awk -F= '$1=="SOCKS_PORT" {print $2}' "$APP_DIR/settings.env" 2>/dev/null)"
FAIL_LIMIT=3
FAIL_COUNT=0
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
is_our_gost_pid() {
  local pid="$1" cmd
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in *"$APP_DIR/gost"*) return 0 ;; *) return 1 ;; esac
}
session_running() {
  local name="$1"
  # 清理失效 socket；只把 Detached / Attached / Multi 视为真实运行会话。
  # Remote or dead / Unreachable 不能算作服务仍在运行。
  screen -wipe >/dev/null 2>&1 || true
  screen -ls 2>/dev/null | awk -v suffix=".$name" '
    $1 ~ ("^[0-9]+" suffix "$)") &&
    ($0 ~ /\(Detached\)/ || $0 ~ /\(Attached\)/ || $0 ~ /\(Multi/) { live=1 }
    END { exit !live }
  '
}
while true; do
  [ -f "$STOP_FLAG" ] && exit 0
  screen -wipe >/dev/null 2>&1 || true
  # supervisor 会话意外消失或变成 Remote or dead 时，只重建本项目的 gost 监管会话。
  if ! session_running gost2; then
    log "未发现 gost supervisor 会话，检查并清理本项目可能残留的 gost"
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_our_gost_pid "$OLD_PID"; then
      kill -TERM "$OLD_PID" 2>/dev/null || true
      sleep 2
      is_our_gost_pid "$OLD_PID" && kill -KILL "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    screen -dmS gost2 bash "$APP_DIR/supervisor.sh"
    sleep 2
  fi
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if ! is_our_gost_pid "$PID"; then
    FAIL_COUNT=0
    sleep 20
    continue
  fi
  # 仅检查本机 TCP 监听端口，不访问外网，不判断 VPN 上游是否可用。
  if timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SOCKS_PORT}" >/dev/null 2>&1; then
    FAIL_COUNT=0
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "SOCKS5 本机端口异常（${FAIL_COUNT}/${FAIL_LIMIT}），PID=${PID}"
    if [ "$FAIL_COUNT" -ge "$FAIL_LIMIT" ] && is_our_gost_pid "$PID"; then
      log "连续异常达到阈值，终止本项目 gost PID=${PID}，交由 supervisor 自动拉起"
      kill -TERM "$PID" 2>/dev/null || true
      sleep 3
      is_our_gost_pid "$PID" && kill -KILL "$PID" 2>/dev/null || true
      FAIL_COUNT=0
    fi
  fi
  sleep 20
done
WATCHDOG_EOF

# ---------- 生成启动脚本 ----------
cat > "$APP_DIR/start.sh" <<'START_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e
APP_DIR="$HOME/.my-vpn-hotspot2"
mkdir -p "$APP_DIR"
[ -x "$APP_DIR/gost" ] || { echo "未找到 gost，请重新运行安装脚本。" >&2; exit 1; }
rm -f "$APP_DIR/stop.flag"
session_running() {
  local name="$1"
  # 清理失效 socket；只把 Detached / Attached / Multi 视为真实运行会话。
  # Remote or dead / Unreachable 不能算作服务仍在运行。
  screen -wipe >/dev/null 2>&1 || true
  screen -ls 2>/dev/null | awk -v suffix=".$name" '
    $1 ~ ("^[0-9]+" suffix "$)") &&
    ($0 ~ /\(Detached\)/ || $0 ~ /\(Attached\)/ || $0 ~ /\(Multi/) { live=1 }
    END { exit !live }
  '
}
LOCK_DIR="$APP_DIR/.start.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
screen -wipe >/dev/null 2>&1 || true
if ! session_running gost2; then
  # 若 screen 会话消失但 gost 子进程仍残留，只清理本项目自己的 gost。
  PID="$(cat "$APP_DIR/gost.pid" 2>/dev/null || true)"
  if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
    CMD="$(ps -o args= -p "$PID" 2>/dev/null || true)"
    case "$CMD" in
      *"$APP_DIR/gost"*)
        kill -TERM "$PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        ;;
    esac
  fi
  rm -f "$APP_DIR/gost.pid"
  screen -dmS gost2 bash "$APP_DIR/supervisor.sh"
fi
sleep 1
if ! session_running watchdog2; then screen -dmS watchdog2 bash "$APP_DIR/watchdog.sh"; fi
echo "my-vpn-hotspot2 已启动。"
START_EOF

# ---------- 生成停止脚本 ----------
cat > "$APP_DIR/stop.sh" <<'STOP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
APP_DIR="$HOME/.my-vpn-hotspot2"
PID_FILE="$APP_DIR/gost.pid"
touch "$APP_DIR/stop.flag"
PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
  CMD="$(ps -o args= -p "$PID" 2>/dev/null || true)"
  case "$CMD" in
    *"$APP_DIR/gost"*)
      kill -TERM "$PID" 2>/dev/null || true
      sleep 2
      CMD="$(ps -o args= -p "$PID" 2>/dev/null || true)"
      case "$CMD" in *"$APP_DIR/gost"*) kill -KILL "$PID" 2>/dev/null || true ;; esac
      ;;
  esac
fi
screen -S watchdog2 -X quit >/dev/null 2>&1 || true
screen -S gost2 -X quit >/dev/null 2>&1 || true
rm -f "$PID_FILE"
echo "my-vpn-hotspot2 已停止。"
STOP_EOF

# ---------- 生成重启脚本 ----------
cat > "$APP_DIR/restart.sh" <<'RESTART_EOF'
#!/data/data/com.termux/files/usr/bin/bash
APP_DIR="$HOME/.my-vpn-hotspot2"
bash "$APP_DIR/stop.sh"
sleep 1
bash "$APP_DIR/start.sh"
echo "my-vpn-hotspot2 已重新启动。"
RESTART_EOF

# ---------- 生成状态检查脚本 ----------
cat > "$APP_DIR/status.sh" <<'STATUS_EOF'
#!/data/data/com.termux/files/usr/bin/bash
APP_DIR="$HOME/.my-vpn-hotspot2"
SOCKS_PORT="$(awk -F= '$1=="SOCKS_PORT" {print $2}' "$APP_DIR/settings.env" 2>/dev/null)"
HTTP_PORT="$(awk -F= '$1=="HTTP_PORT" {print $2}' "$APP_DIR/settings.env" 2>/dev/null)"
session_status() {
  local name="$1"
  screen -wipe >/dev/null 2>&1 || true
  screen -ls 2>/dev/null | awk -v suffix=".$name" '
    $1 ~ ("^[0-9]+" suffix "$)") {
      if ($0 ~ /\(Detached\)/) state="Detached"
      else if ($0 ~ /\(Attached\)/) state="Attached"
      else if ($0 ~ /\(Multi/) state="Multi"
      else if ($0 ~ /Remote or dead|Unreachable|Dead/) { if (state == "") state="Remote or dead" }
    }
    END { if (state == "") state="未运行"; print state }
  '
}
port_status() { local p="$1"; if [ -n "$p" ] && timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${p}" >/dev/null 2>&1; then echo "正常（${p}）"; else echo "未监听（${p:-未配置}）"; fi; }
PID="$(cat "$APP_DIR/gost.pid" 2>/dev/null || true)"
printf '\n===== my-vpn-hotspot2 状态 =====\n'
printf 'gost 会话    ：%s\n' "$(session_status gost2)"
printf 'watchdog 会话：%s\n' "$(session_status watchdog2)"
CMD="$(ps -o args= -p "$PID" 2>/dev/null || true)"
case "$CMD" in *"$APP_DIR/gost"*) printf 'gost 进程    ：运行中（PID %s）\n' "$PID" ;; *) printf 'gost 进程    ：未检测到\n' ;; esac
printf 'SOCKS5 端口  ：%s\n' "$(port_status "$SOCKS_PORT")"
printf 'HTTP 端口    ：%s\n' "$(port_status "$HTTP_PORT")"
printf '================================\n\n'
STATUS_EOF

# ---------- 生成卸载脚本 ----------
cat > "$APP_DIR/uninstall.sh" <<'UNINSTALL_EOF'
#!/data/data/com.termux/files/usr/bin/bash
APP_DIR="$HOME/.my-vpn-hotspot2"
read -r -p "确定卸载 my-vpn-hotspot2？（配置和日志也会删除）[y/N]: " ANSWER
case "$ANSWER" in y|Y|yes|YES) ;; *) echo "已取消。"; exit 0 ;; esac
bash "$APP_DIR/stop.sh" 2>/dev/null || true
sed -i '/# === MY_VPN_HOTSPOT2_AUTOSTART ===/,+3d' "$HOME/.bashrc" 2>/dev/null || true
rm -f "$HOME/.termux/boot/20-my-vpn-hotspot2"
rm -rf "$APP_DIR"
echo "my-vpn-hotspot2 已卸载。第一版文件未主动删除。"
UNINSTALL_EOF

chmod 700 "$APP_DIR"/*.sh

# ---------- 配置 Termux 会话启动 ----------
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

# ---------- 配置可选的 Android 开机启动 ----------
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/20-my-vpn-hotspot2" <<'BOOT_SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock >/dev/null 2>&1 || true
sleep 10
bash "$HOME/.my-vpn-hotspot2/start.sh"
BOOT_SCRIPT
chmod 700 "$BOOT_DIR/20-my-vpn-hotspot2"

# ---------- 启动服务 ----------
info "启动 gost 和 watchdog..."
bash "$APP_DIR/start.sh"
sleep 2

printf '\n================================================\n'
printf '\033[0;32m安装完成！\033[0m\n'
printf 'SOCKS5 端口：%s\n' "$SOCKS_PORT"
printf 'HTTP 端口  ：%s\n' "$HTTP_PORT"
if [ -n "$PROXY_USER" ]; then
  printf '认证       ：已启用（用户名：%s）\n' "$PROXY_USER"
else
  printf '认证       ：未启用（建议设置密码）\n'
fi
printf '\n常用命令：\n'
printf '  bash ~/.my-vpn-hotspot2/status.sh   查看状态\n'
printf '  bash ~/.my-vpn-hotspot2/restart.sh  重启服务\n'
printf '  bash ~/.my-vpn-hotspot2/stop.sh     停止服务\n'
printf '  tail -f ~/.my-vpn-hotspot2/gost.log 查看 gost 日志\n'
printf '================================================\n'
printf '\n注意：Termux:Boot 需要单独安装并至少打开一次，才能实现 Android 开机启动。\n'
