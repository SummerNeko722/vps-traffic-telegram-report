#!/bin/bash
# vps-traffic-report install.sh
set -euo pipefail

TG_BOT_TOKEN=""
TG_CHAT_ID=""
VPS_NAME=""
VNSTAT_IFACE=""
SKIP_TEST=0

usage() {
    cat <<USAGE
用法: bash $0 --token <TG_BOT_TOKEN> --chat-id <TG_CHAT_ID> [--name <VPS_NAME>] [--iface <网卡>] [--skip-test]

示例:
  bash $0 --token 123456:AAExxx --chat-id 123456789 --name "HK-VPS-1"
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) TG_BOT_TOKEN="$2"; shift 2 ;;
        --chat-id) TG_CHAT_ID="$2"; shift 2 ;;
        --name) VPS_NAME="$2"; shift 2 ;;
        --iface) VNSTAT_IFACE="$2"; shift 2 ;;
        --skip-test) SKIP_TEST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1"; usage; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "请以 root 身份运行"; exit 1
fi

if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    echo "缺少 --token 或 --chat-id"; usage; exit 1
fi

[[ -z "$VPS_NAME" ]] && VPS_NAME="$(hostname)"
VPS_NAME="${VPS_NAME// /-}"

echo "==> VPS 名称: $VPS_NAME"

# 0. 时区
timedatectl set-timezone Asia/Shanghai || true

# 1. 依赖
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq vnstat python3 python3-requests curl >/dev/null

# 2. vnstat
systemctl enable --now vnstat >/dev/null
sleep 2

# 3. 探测网卡
if [[ -z "$VNSTAT_IFACE" ]]; then
    VNSTAT_IFACE=$(ip -br link | awk '$2 == "UP" && $1 != "lo" {print $1; exit}')
fi
[[ -z "$VNSTAT_IFACE" ]] && { echo "无法探测网卡，请用 --iface"; exit 1; }
echo "==> 网卡: $VNSTAT_IFACE"

# 4. 配置
cat > /etc/status-send-tg.env <<EOF
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_CHAT_ID=$TG_CHAT_ID
VPS_NAME=$VPS_NAME
VNSTAT_IFACE=$VNSTAT_IFACE
EOF
chmod 600 /etc/status-send-tg.env

# 5. Python 脚本
cat > /root/traffic-report.py <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, json, subprocess, datetime, requests

BOT_TOKEN = os.getenv("TG_BOT_TOKEN")
CHAT_ID = os.getenv("TG_CHAT_ID")
IFACE = os.getenv("VNSTAT_IFACE", "eth0")
VPS_NAME = os.getenv("VPS_NAME", "VPS")
MODE = os.getenv("TRAFFIC_MODE", "daily")

if not BOT_TOKEN or not CHAT_ID:
    print("缺少 TG_BOT_TOKEN 或 TG_CHAT_ID"); sys.exit(1)

def fmt(n):
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if n < 1024: return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} PiB"

def vnstat_json(mode):
    out = subprocess.check_output(["vnstat", "--json", mode, "-i", IFACE], text=True)
    return json.loads(out)

def get_iface(data):
    if not data.get("interfaces"): return None
    return data["interfaces"][0]

def fetch_days():
    iface = get_iface(vnstat_json("d"))
    if iface is None: return []
    return iface["traffic"].get("day") or iface["traffic"].get("days") or []

def fetch_months():
    iface = get_iface(vnstat_json("m"))
    if iface is None: return []
    return iface["traffic"].get("month") or iface["traffic"].get("months") or []

def build_daily():
    days = fetch_days(); months = fetch_months()
    L = []
    L.append("📊 <b>VPS 流量日报</b>")
    L.append(f"🖥️ 主机：<code>{VPS_NAME}</code>")
    L.append(f"🕐 {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}")
    L.append(f"🖧 网卡：<code>{IFACE}</code>")
    L.append("")
    if days:
        d = days[-1]
        ds = f"{d['date']['year']:04d}-{d['date']['month']:02d}-{d['date']['day']:02d}"
        L.append(f"📅 <b>今日（{ds}）</b>")
        L.append(f"  ⬇️ 下行：{fmt(d['rx'])}")
        L.append(f"  ⬆️ 上行：{fmt(d['tx'])}")
        L.append(f"  📦 合计：<b>{fmt(d['rx'] + d['tx'])}</b>")
        L.append("")
    else:
        L.append("今日暂无数据"); L.append("")
    if months:
        m = months[-1]
        ms = f"{m['date']['year']:04d}-{m['date']['month']:02d}"
        L.append(f"📈 <b>本月累计（{ms}）</b>")
        L.append(f"  ⬇️ 下行：{fmt(m['rx'])}")
        L.append(f"  ⬆️ 上行：{fmt(m['tx'])}")
        L.append(f"  📦 合计：<b>{fmt(m['rx'] + m['tx'])}</b>")
    else:
        L.append("本月暂无数据")
    return "\n".join(L)

def build_monthly():
    months = fetch_months()
    L = []
    L.append("📊 <b>VPS 流量月报</b>")
    L.append(f"🖥️ 主机：<code>{VPS_NAME}</code>")
    L.append(f"🕐 {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}")
    L.append(f"🖧 网卡：<code>{IFACE}</code>")
    L.append("")
    if months:
        L.append("📋 <b>最近几个月</b>")
        for m in months[-6:]:
            ym = f"{m['date']['year']:04d}-{m['date']['month']:02d}"
            L.append(f"  <code>{ym}</code>  {fmt(m['rx'] + m['tx'])}")
        L.append("")
        cur = months[-1]
        cm = f"{cur['date']['year']:04d}-{cur['date']['month']:02d}"
        L.append(f"📈 <b>本月累计（{cm}）</b>")
        L.append(f"  ⬇️ 下行：{fmt(cur['rx'])}")
        L.append(f"  ⬆️ 上行：{fmt(cur['tx'])}")
        L.append(f"  📦 合计：<b>{fmt(cur['rx'] + cur['tx'])}</b>")
    else:
        L.append("暂无月度数据")
    return "\n".join(L)

def send(text):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    payload = {"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML",
               "disable_web_page_preview": True}
    r = requests.post(url, json=payload, timeout=15)
    print("HTTP:", r.status_code); print(r.text); r.raise_for_status()

def main():
    text = build_monthly() if MODE == "monthly" else build_daily()
    if not text:
        print("vnstat 无数据，跳过"); sys.exit(0)
    send(text); print("发送成功")

if __name__ == "__main__":
    main()
PYEOF
chmod +x /root/traffic-report.py

# 6. shell wrapper
cat > /root/traffic-send.sh <<'SHEOF'
#!/bin/bash
set -euo pipefail
set -a; . /etc/status-send-tg.env; set +a
export TRAFFIC_MODE="${1:-daily}"
exec /usr/bin/python3 /root/traffic-report.py
SHEOF
chmod +x /root/traffic-send.sh

# 7. systemd
cat > /etc/systemd/system/traffic-daily.service <<'EOF'
[Unit]
Description=Send daily VPS traffic report to Telegram
After=network-online.target vnstat.service
Wants=network-online.target vnstat.service

[Service]
Type=oneshot
ExecStart=/root/traffic-send.sh daily
WorkingDirectory=/root
EOF

cat > /etc/systemd/system/traffic-monthly.service <<'EOF'
[Unit]
Description=Send monthly VPS traffic report to Telegram
After=network-online.target vnstat.service
Wants=network-online.target vnstat.service

[Service]
Type=oneshot
ExecStart=/root/traffic-send.sh monthly
WorkingDirectory=/root
EOF

cat > /etc/systemd/system/traffic-daily.timer <<'EOF'
[Unit]
Description=Run daily traffic report at 9am

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
Unit=traffic-daily.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/traffic-monthly.timer <<'EOF'
[Unit]
Description=Run monthly traffic report on 1st at 9:05

[Timer]
OnCalendar=*-*-01 09:05:00
Persistent=true
Unit=traffic-monthly.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now traffic-daily.timer traffic-monthly.timer >/dev/null

echo ""
echo "==> 安装完成"
echo "    主机名称: $VPS_NAME"
echo "    网卡:     $VNSTAT_IFACE"
echo "    配置文件: /etc/status-send-tg.env"
echo "    脚本:     /root/traffic-report.py  /root/traffic-send.sh"
echo ""
systemctl list-timers | grep traffic || true

if [[ "$SKIP_TEST" -eq 0 ]]; then
    echo ""
    echo "==> 等待 vnstat 首次采样（最多 20 秒）"
    for i in {1..20}; do
        if ! vnstat -i "$VNSTAT_IFACE" 2>&1 | grep -q "No data"; then
            break
        fi
        sleep 1
    done
    echo "==> 发送测试消息"
    /root/traffic-send.sh daily || true
fi

echo ""
echo "全部完成。"
