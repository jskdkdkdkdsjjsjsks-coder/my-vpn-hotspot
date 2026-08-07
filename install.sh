#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  VPN 热点分享 一键安装脚本
#  整合 gost + unbound + 看门狗
#  需要：Termux + root（Magisk/KernelSU）
# ============================================================
set -e
cd ~

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

info() { echo -e "${GREEN}==>${RESET} $1"; }
warn() { echo -e "${YELLOW}!!${RESET} $1"; }

echo -e "${BOLD}"
echo "================================================"
echo "   VPN 热点分享 - 一键安装"
echo "================================================"
echo -e "${RESET}"

# ---------- 0. 检查 root ----------
info "检查 root 权限..."
if ! su -c "id" >/dev/null 2>&1; then
    warn "没有检测到 root 权限。热点透明转发功能需要 root。"
    warn "如果只想用 socks5/http 代理（不共享热点），可以继续安装，"
    warn "但涉及 iptables 的功能会失败。"
    read -p "仍要继续吗？(y/N): " cont
    [ "$cont" != "y" ] && [ "$cont" != "Y" ] && exit 1
fi

# ---------- 1. 安装依赖 ----------
info "安装依赖包（screen curl unbound dnsutils）..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y screen curl unbound dnsutils

# ---------- 2. 清理旧环境 ----------
info "清理旧的会话与进程（如果是重装）..."
pkill -9 -f 'watchdog.sh' 2>/dev/null || true
pkill -9 -f 'keep_running.sh' 2>/dev/null || true
pkill -9 -f './gost' 2>/dev/null || true
pkill -9 -f 'unbound -c' 2>/dev/null || true
pkill -9 SCREEN 2>/dev/null || true
rm -rf ~/.lock_watchdog.d ~/.lock_hotspot_watchdog.d ~/.lock_unbound_run.d ~/.lock_gost_run.d
rm -rf ~/.screen
if su -c "id" >/dev/null 2>&1; then
    su -c "iptables -t nat -F GOST_REDIRECT 2>/dev/null" || true
fi

# ---------- 3. 下载 gost ----------
if [ ! -x ./gost ]; then
    info "下载 gost..."
    GOST_VER="3.0.0"
    ARCH="linux_arm64"
    curl -L -o gost.tar.gz -# --retry 2 --insecure \
        "https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_${ARCH}.tar.gz" \
        || curl -L -o gost.tar.gz -# --retry 2 --insecure \
        "https://gh-proxy.com/https://github.com/go-gost/gost/releases/download/v${GOST_VER}/gost_${GOST_VER}_${ARCH}.tar.gz"
    tar zxvf gost.tar.gz
    rm -f gost.tar.gz README* LICENSE*
    chmod +x ./gost
fi
if [ ! -x ./gost ]; then
    warn "gost 下载失败，请检查网络后重新运行本脚本。"
    exit 1
fi

# ---------- 4. 设置端口和 socks5 认证 ----------
echo ""
read -p "设置 Socks5 端口（回车用随机端口）: " socks_port
[ -z "$socks_port" ] && socks_port=$(shuf -i 10000-65535 -n 1)
read -p "设置 Http 端口（回车用随机端口）: " http_port
[ -z "$http_port" ] && http_port=$(shuf -i 10000-65535 -n 1)

warn "为防止同一WiFi下的人蹭用你的代理，建议设置用户名密码"
read -p "Socks5/Http 用户名（回车跳过，不设密码）: " proxy_user
proxy_pass=""
if [ -n "$proxy_user" ]; then
    read -p "密码: " proxy_pass
fi

# ---------- 5. 生成 config.yaml ----------
info "生成 gost 配置..."

AUTH_BLOCK=""
if [ -n "$proxy_user" ]; then
    AUTH_BLOCK="    auth:
      username: ${proxy_user}
      password: ${proxy_pass}"
fi

cat > ~/config.yaml << EOF
services:
  - name: service-socks5
    addr: ":${socks_port}"
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
    addr: ":${http_port}"
    resolver: resolver-0
${AUTH_BLOCK}
    handler:
      type: http
      metadata:
        udp: true
        udpbuffersize: 4096
    listener:
      type: tcp

  - name: service-red
    addr: ":1088"
    handler:
      type: red
      chain: chain-0
    listener:
      type: tcp

chains:
  - name: chain-0
    hops:
      - name: hop-0
        nodes:
          - name: socks-out
            addr: "127.0.0.1:${socks_port}"
            connector:
              type: socks5
            dialer:
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

cat > ~/gost_run.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd /data/data/com.termux/files/home || exit 1
./gost -C config.yaml
EOF
chmod +x ~/gost_run.sh

# ---------- 6. 生成 unbound 配置（修复 DNS 污染+回程 NAT 问题） ----------
info "生成 unbound DNS 配置..."
mkdir -p ~/unbound
cat > ~/unbound/unbound.conf << 'EOF'
server:
    interface: 0.0.0.0@5353
    access-control: 10.0.0.0/8 allow
    access-control: 127.0.0.1/32 allow
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    cache-min-ttl: 0
    cache-max-ttl: 300
    prefetch: yes
    logfile: "/data/data/com.termux/files/home/unbound/unbound.log"
    verbosity: 1

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
EOF

cat > ~/unbound_run.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~ || exit 1
unbound -c ~/unbound/unbound.conf -d
EOF
chmod +x ~/unbound_run.sh

# ---------- 7. 下载国内 IP 分流名单 ----------
info "下载国内 IP 分流名单..."
curl -Ls --retry 2 --insecure -o ~/chnroute.txt \
    "https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt" \
    || curl -Ls --retry 2 --insecure -o ~/chnroute.txt \
    "https://gh-proxy.com/https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
[ -s ~/chnroute.txt ] && info "国内IP名单：$(wc -l < ~/chnroute.txt) 条" || warn "国内IP名单下载失败，稍后会自动重试"

# ---------- 8. 生成规则重建脚本（用 iptables-restore 避免命令过长） ----------
info "生成 iptables 规则构建脚本..."
cat > ~/build_gost_rules.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
RED_PORT=1088
RULES_FILE=~/.gost_iptables_rules

{
    echo "*nat"
    echo ":GOST_REDIRECT - [0:0]"
    echo "-A GOST_REDIRECT -d 127.0.0.0/8 -j RETURN"
    echo "-A GOST_REDIRECT -d 10.0.0.0/8 -j RETURN"
    echo "-A GOST_REDIRECT -d 172.16.0.0/12 -j RETURN"
    echo "-A GOST_REDIRECT -d 192.168.0.0/16 -j RETURN"
    echo "-A GOST_REDIRECT -d 224.0.0.0/4 -j RETURN"
    if [ -f ~/chnroute.txt ]; then
        awk '{print "-A GOST_REDIRECT -d " $1 " -j RETURN"}' ~/chnroute.txt
    fi
    echo "-A GOST_REDIRECT -p tcp -j REDIRECT --to-ports $RED_PORT"
    echo "COMMIT"
} > "$RULES_FILE"

su -c "iptables-restore -n < $RULES_FILE"
EOF
chmod +x ~/build_gost_rules.sh

# ---------- 9. 生成国内IP名单自动更新脚本 ----------
cat > ~/update_chnroute.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
CHNLIST=~/chnroute.txt
DAYS=3

need_update=0
if [ ! -f "$CHNLIST" ]; then
    need_update=1
elif [ -n "$(find "$CHNLIST" -mtime +$DAYS 2>/dev/null)" ]; then
    need_update=1
fi
[ "$need_update" = "0" ] && exit 0

curl -Ls --retry 2 --insecure -o "$CHNLIST" \
    "https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt" \
    || curl -Ls --retry 2 --insecure -o "$CHNLIST" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"

if [ ! -s "$CHNLIST" ]; then
    echo "$(date '+%F %T') 国内IP列表更新失败" >> ~/bashrc_start.log
    exit 1
fi
echo "$(date '+%F %T') 国内IP列表已更新，共 $(wc -l < $CHNLIST) 条" >> ~/bashrc_start.log

screen -list 2>/dev/null | grep hotspot_watchdog | cut -d. -f1 | awk '{print $1}' | xargs -r kill
pkill -9 -f 'hotspot_watchdog.sh' 2>/dev/null
pkill -9 -f 'keep_running.sh.*hotspot' 2>/dev/null
rm -rf ~/.lock_hotspot_watchdog.d
su -c "iptables -t nat -F GOST_REDIRECT 2>/dev/null"
screen -dmS hotspot_watchdog bash ~/keep_running.sh ~/hotspot_watchdog.sh
EOF
chmod +x ~/update_chnroute.sh

# ---------- 10. 生成代理健康检测看门狗 ----------
cat > ~/watchdog.sh << EOF
#!/data/data/com.termux/files/usr/bin/bash
cd ~ || exit 1
SOCKS_PORT=${socks_port}

check_alive() {
    code=\$(curl -s -m 5 -o /dev/null -w "%{http_code}" -x socks5h://127.0.0.1:\${SOCKS_PORT} https://www.gstatic.com/generate_204)
    [ "\$code" = "204" ]
}

restart_gost() {
    echo "\$(date '+%F %T') 代理失效，正在重启 gost..."
    pkill -9 -f './gost' 2>/dev/null
}

while true; do
    check_alive || restart_gost
    sleep 180
done
EOF
chmod +x ~/watchdog.sh

# ---------- 11. 生成热点转发看门狗（含 DNS 自愈） ----------
cat > ~/hotspot_watchdog.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
RED_PORT=1088
DNS_PORT=5353
LOG=~/bashrc_start.log

detect_iface() {
    ifconfig 2>/dev/null | awk '
    /^[a-zA-Z0-9_]+:/ {
        if (iface != "" && is_bcast && has_inet) print iface
        iface=$1; sub(/:$/,"",iface)
        is_bcast=($0 ~ /BROADCAST/)
        has_inet=0
        next
    }
    /inet /{ has_inet=1 }
    END {
        if (iface != "" && is_bcast && has_inet) print iface
    }
    ' | grep -viE '^(wlan0|lo|rmnet[0-9]*|ipsec[0-9]*|dummy[0-9]*|r_rmnet[0-9]*|ccmni[0-9]*|usb[0-9]*)$' | head -n1
}

build_chain() { bash ~/build_gost_rules.sh; }

ensure_unbound() {
    if ! screen -list 2>/dev/null | grep -vi 'dead' | awk '{print $1}' | awk -F. '{print $2}' | grep -qx "unbound-dns"; then
        screen -dmS unbound-dns bash ~/keep_running.sh ~/unbound_run.sh
        echo "$(date '+%F %T') [DNS] unbound-dns 会话已(重新)建立" >> "$LOG"
        sleep 1
    fi
}

ensure_gost() {
    if ! screen -list 2>/dev/null | grep -vi 'dead' | awk '{print $1}' | awk -F. '{print $2}' | grep -qx "myscreen"; then
        rm -rf ~/.lock_gost_run.d
        screen -dmS myscreen bash ~/keep_running.sh ~/gost_run.sh
        echo "$(date '+%F %T') [代理] myscreen 会话已(重新)建立" >> "$LOG"
        sleep 1
    fi
}

ensure_dns_rules() {
    local iface=$1
    su -c "iptables -t nat -C PREROUTING -i $iface -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT" 2>/dev/null
    if [ $? -ne 0 ]; then
        su -c "iptables -t nat -A PREROUTING -i $iface -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
        echo "$(date '+%F %T') [DNS] UDP 53重定向规则已补上 [$iface]" >> "$LOG"
    fi
    su -c "iptables -t nat -C PREROUTING -i $iface -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT" 2>/dev/null
    if [ $? -ne 0 ]; then
        su -c "iptables -t nat -A PREROUTING -i $iface -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
        echo "$(date '+%F %T') [DNS] TCP 53重定向规则已补上 [$iface]" >> "$LOG"
    fi
    UDP_COUNT=$(su -c "iptables -t nat -S PREROUTING" | grep -c "udp --dport 53")
    TCP_COUNT=$(su -c "iptables -t nat -S PREROUTING" | grep -c "tcp --dport 53")
    if [ "$UDP_COUNT" -gt 1 ] || [ "$TCP_COUNT" -gt 1 ]; then
        echo "$(date '+%F %T') [DNS] 发现重复DNS规则(udp:$UDP_COUNT tcp:$TCP_COUNT)，清理重建" >> "$LOG"
        su -c "while iptables -t nat -D PREROUTING -i $iface -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null; do :; done"
        su -c "while iptables -t nat -D PREROUTING -i $iface -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT 2>/dev/null; do :; done"
        su -c "iptables -t nat -A PREROUTING -i $iface -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
        su -c "iptables -t nat -A PREROUTING -i $iface -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT"
    fi
}

clear_dns_rules() {
    local iface=$1
    su -c "iptables -t nat -D PREROUTING -i $iface -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT" 2>/dev/null
    su -c "iptables -t nat -D PREROUTING -i $iface -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT" 2>/dev/null
}

ensure_entry() {
    local iface=$1
    su -c "iptables -t nat -C PREROUTING -i $iface -p tcp -j GOST_REDIRECT" 2>/dev/null
    if [ $? -ne 0 ]; then
        su -c "iptables -t nat -A PREROUTING -i $iface -p tcp -j GOST_REDIRECT"
        echo "$(date '+%F %T') [热点转发] PREROUTING入口已补上 [$iface]" >> "$LOG"
    fi
    ENTRY_COUNT=$(su -c "iptables -t nat -S PREROUTING" | grep -c "GOST_REDIRECT")
    if [ "$ENTRY_COUNT" -gt 1 ]; then
        echo "$(date '+%F %T') [热点转发] 发现重复入口($ENTRY_COUNT条)，清理重建" >> "$LOG"
        su -c "while iptables -t nat -D PREROUTING -i $iface -p tcp -j GOST_REDIRECT 2>/dev/null; do :; done"
        su -c "iptables -t nat -A PREROUTING -i $iface -p tcp -j GOST_REDIRECT"
    fi
}

init_chain_once() {
    su -c "iptables -t nat -N GOST_REDIRECT" 2>/dev/null
    su -c "iptables -t nat -C GOST_REDIRECT -p tcp -j REDIRECT --to-ports $RED_PORT" 2>/dev/null
    if [ $? -ne 0 ]; then
        build_chain
        echo "$(date '+%F %T') [热点转发] GOST_REDIRECT链首次建立" >> "$LOG"
    fi
}

clear_rules() {
    local iface=$1
    su -c "while iptables -t nat -D PREROUTING -i $iface -p tcp -j GOST_REDIRECT 2>/dev/null; do :; done"
    clear_dns_rules "$iface"
    echo "$(date '+%F %T') [热点转发] 热点关闭，已清理" >> "$LOG"
}

# 孤儿进程清扫：进程还活着但screen会话没了（Android偶尔会杀掉screen壳但漏杀子进程）
reap_orphans() {
    screen -wipe >/dev/null 2>&1
    if pgrep -f './gost' >/dev/null 2>&1 && ! screen -list 2>/dev/null | grep -vi 'dead' | awk '{print $1}' | awk -F. '{print $2}' | grep -qx "myscreen"; then
        pkill -9 -f './gost' 2>/dev/null
        rm -rf ~/.lock_gost_run.d
        sleep 1
        screen -dmS myscreen bash ~/keep_running.sh ~/gost_run.sh
        echo "$(date '+%F %T') [自愈] 发现gost孤儿进程，已清理并重新纳管" >> "$LOG"
    fi

    UNBOUND_COUNT=$(pgrep -f 'unbound -c' 2>/dev/null | wc -l)
    HAS_UNBOUND_SCREEN=$(screen -list 2>/dev/null | grep -vi 'dead' | awk '{print $1}' | awk -F. '{print $2}' | grep -qx "unbound-dns" && echo 1 || echo 0)
    if [ "$UNBOUND_COUNT" -gt 1 ] || { [ "$UNBOUND_COUNT" -ge 1 ] && [ "$HAS_UNBOUND_SCREEN" = "0" ]; }; then
        pkill -9 -f 'unbound -c' 2>/dev/null
        rm -rf ~/.lock_unbound_run.d
        sleep 1
        screen -dmS unbound-dns bash ~/keep_running.sh ~/unbound_run.sh
        echo "$(date '+%F %T') [自愈] 发现unbound孤儿/重复进程，已清理并重新纳管" >> "$LOG"
    fi
}

STATE_APPLIED=0
CUR_IFACE=""
while true; do
    reap_orphans
    ensure_gost
    ensure_unbound
    IFACE=$(detect_iface)
    if [ -n "$IFACE" ]; then
        init_chain_once
        ensure_entry "$IFACE"
        ensure_dns_rules "$IFACE"
        STATE_APPLIED=1
        CUR_IFACE=$IFACE
    elif [ -z "$IFACE" ] && [ "$STATE_APPLIED" = "1" ]; then
        clear_rules "$CUR_IFACE"
        STATE_APPLIED=0
        CUR_IFACE=""
    fi
    sleep 8
done
EOF
chmod +x ~/hotspot_watchdog.sh

# ---------- 12. 生成崩溃自愈 + 防重复启动的包装脚本 ----------
cat > ~/keep_running.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
SCRIPT=$1
LOCKDIR="/data/data/com.termux/files/home/.lock_$(basename $SCRIPT .sh).d"
LOG=~/bashrc_start.log

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        return 0
    fi
    for i in 1 2 3; do
        [ -f "$LOCKDIR/pid" ] && break
        sleep 0.2
    done
    if [ -f "$LOCKDIR/pid" ]; then
        OLDPID=$(cat "$LOCKDIR/pid" 2>/dev/null)
        if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
            echo "$(date '+%F %T') $SCRIPT 已有实例在运行(PID $OLDPID)，本次不重复启动" >> "$LOG"
            return 1
        fi
    fi
    rmdir "$LOCKDIR" 2>/dev/null
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        return 0
    fi
    return 1
}

acquire_lock || exit 0
trap 'rm -rf "$LOCKDIR"' EXIT

while true; do
    bash "$SCRIPT"
    echo "$(date '+%F %T') $SCRIPT 意外退出，5秒后重启" >> "$LOG"
    sleep 5
done
EOF
chmod +x ~/keep_running.sh

# ---------- 13. 生成体检脚本 ----------
cat > ~/check_status.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
screen -wipe >/dev/null 2>&1
echo "================ 服务状态检查 ================"
for name in myscreen watchdog hotspot_watchdog unbound-dns; do
    if screen -list 2>/dev/null | grep -vi 'dead' | awk '{print $1}' | awk -F. '{print $2}' | grep -qx "$name"; then
        echo "  [运行中] $name"
    else
        echo "  [已停止] $name  <-- 需要手动拉起"
    fi
done
echo "================================================"
EOF
chmod +x ~/check_status.sh

# ---------- 14. 生成 IP 显示脚本 ----------
cat > ~/show_ip.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "================ 网络信息 ================"
ifconfig 2>/dev/null | awk '
/^[a-zA-Z0-9_]+:/ {iface=$1; sub(/:$/,"",iface)}
/inet /{for(i=1;i<=NF;i++) if($i=="inet") print "  " iface " : " $(i+1)}
' | grep -v '127.0.0.1'
PUB_IP=$(curl -s -m 3 https://ifconfig.me 2>/dev/null)
[ -n "$PUB_IP" ] && echo "公网出口 IP    : $PUB_IP"
echo "============================================"
EOF
chmod +x ~/show_ip.sh

# ---------- 14.5 生成一键重置脚本（兜底手段） ----------
cat > ~/reset_all.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# 遇到玄学问题（时好时坏、重复进程）时，直接跑这个脚本清空重启
echo "正在清空所有相关进程与规则..."
pkill -9 -f 'unbound -c' 2>/dev/null
pkill -9 -f './gost' 2>/dev/null
pkill -9 -f 'watchdog.sh' 2>/dev/null
pkill -9 -f 'keep_running.sh' 2>/dev/null
pkill -9 SCREEN 2>/dev/null
sleep 1
rm -rf ~/.screen
rm -rf ~/.lock_watchdog.d ~/.lock_hotspot_watchdog.d ~/.lock_unbound_run.d ~/.lock_gost_run.d

IFACE=$(ifconfig 2>/dev/null | awk '
/^[a-zA-Z0-9_]+:/ {
    if (iface != "" && is_bcast && has_inet) print iface
    iface=$1; sub(/:$/,"",iface)
    is_bcast=($0 ~ /BROADCAST/)
    has_inet=0
    next
}
/inet /{ has_inet=1 }
END {
    if (iface != "" && is_bcast && has_inet) print iface
}
' | grep -viE '^(wlan0|lo|rmnet[0-9]*|ipsec[0-9]*|dummy[0-9]*|r_rmnet[0-9]*|ccmni[0-9]*|usb[0-9]*)$' | head -n1)

if [ -n "$IFACE" ]; then
    su -c "iptables -t nat -F GOST_REDIRECT 2>/dev/null"
    su -c "while iptables -t nat -D PREROUTING -i $IFACE -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null; do :; done"
    su -c "while iptables -t nat -D PREROUTING -i $IFACE -p tcp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null; do :; done"
    su -c "while iptables -t nat -D PREROUTING -i $IFACE -p tcp -j GOST_REDIRECT 2>/dev/null; do :; done"
fi

echo "重新启动所有服务..."
cd ~
screen -dmS myscreen bash ~/keep_running.sh ~/gost_run.sh
sleep 1
screen -dmS unbound-dns bash ~/keep_running.sh ~/unbound_run.sh
sleep 1
screen -dmS watchdog bash ~/keep_running.sh ~/watchdog.sh
screen -dmS hotspot_watchdog bash ~/keep_running.sh ~/hotspot_watchdog.sh
sleep 3

echo "正在预热DNS连接（首次连接上游可能需要几秒到几十秒）..."
timeout 60 dig @127.0.0.1 -p 5353 www.google.com +short >/dev/null 2>&1
echo "预热完成"

echo "清理僵尸会话记录..."
screen -wipe >/dev/null 2>&1

echo "完成，当前状态："
bash ~/check_status.sh
EOF
chmod +x ~/reset_all.sh

# ---------- 15. 写入 .bashrc 自动拉起逻辑（幂等，重复安装不会重复写入） ----------
info "配置开机自动拉起..."
MARKER="# === GVPN_AUTOSTART_BLOCK ==="
if ! grep -q "$MARKER" ~/.bashrc 2>/dev/null; then
cat >> ~/.bashrc << EOF

$MARKER
screen -wipe >/dev/null 2>&1
running() {
    screen -list 2>/dev/null | grep -vi 'dead' | awk '{print \$1}' | awk -F. '{print \$2}' | grep -qx "\$1"
}
LOG=~/bashrc_start.log
echo "\$(date '+%F %T') ---- .bashrc 开始执行 ----" >> "\$LOG"
if ! running myscreen; then
    screen -dmS myscreen bash ~/keep_running.sh ~/gost_run.sh
    echo "\$(date '+%F %T') 启动了 myscreen" >> "\$LOG"
fi
if ! running watchdog; then
    screen -dmS watchdog bash ~/keep_running.sh ~/watchdog.sh
    echo "\$(date '+%F %T') 启动了 watchdog" >> "\$LOG"
fi
if ! running hotspot_watchdog; then
    screen -dmS hotspot_watchdog bash ~/keep_running.sh ~/hotspot_watchdog.sh
    echo "\$(date '+%F %T') 启动了 hotspot_watchdog" >> "\$LOG"
fi
if ! running unbound-dns; then
    screen -dmS unbound-dns bash ~/keep_running.sh ~/unbound_run.sh
    echo "\$(date '+%F %T') 启动了 unbound-dns" >> "\$LOG"
fi
bash ~/show_ip.sh
bash ~/update_chnroute.sh
$MARKER
EOF
    info ".bashrc 自启动逻辑已添加"
else
    info ".bashrc 已包含自启动逻辑，跳过"
fi

# ---------- 16. 首次启动全部服务 ----------
info "首次启动所有服务..."
screen -dmS myscreen bash ~/keep_running.sh ~/gost_run.sh
sleep 1
screen -dmS unbound-dns bash ~/keep_running.sh ~/unbound_run.sh
sleep 1
screen -dmS watchdog bash ~/keep_running.sh ~/watchdog.sh
screen -dmS hotspot_watchdog bash ~/keep_running.sh ~/hotspot_watchdog.sh

sleep 2

# ---------- 完成 ----------
echo ""
echo -e "${BOLD}================================================${RESET}"
echo -e "${GREEN}安装完成！${RESET}"
echo "================================================"
echo "Socks5 端口   : ${socks_port}"
echo "Http 端口     : ${http_port}"
if [ -n "$proxy_user" ]; then
    echo "认证用户名     : ${proxy_user}"
    echo "认证密码       : ${proxy_pass}"
else
    echo "认证           : 未设置（任何人都能连，建议重装时设置密码）"
fi
echo "------------------------------------------------"
echo "使用说明："
echo "  1. 电脑/其他设备用 socks5 代理，填手机内网IP + 上面的端口"
echo "  2. 开热点后，连热点的设备会自动透明代理，无需手动设置"
echo "  3. 查看运行状态：bash ~/check_status.sh"
echo "  4. 查看日志：cat ~/bashrc_start.log"
echo "================================================"
bash ~/show_ip.sh
