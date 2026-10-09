# VPS 流量 Telegram 日报

一个自动把 **VPS 每天 / 每月流量** 通过 Telegram Bot 发送给你的小脚本。

- 自动统计流量（基于 `vnstat`）
- 每天早上 9:00 发日报
- 每月 1 号 9:05 发月报
- 支持多台 VPS，消息里带主机名区分
- 一键安装，一条命令搞定

---

## 效果预览

Telegram 里你会收到这样的消息：

📊 VPS 流量日报
🖥️ 主机：HK-VPS-1
🕐 2026-10-10 09:00
🖧 网卡：ens5

📅 今日（2026-10-10）
⬇️ 下行：1.23 GiB
⬆️ 上行：456.78 MiB
📦 合计：1.68 GiB

📈 本月累计（2026-10）
⬇️ 下行：12.34 GiB
⬆️ 上行：5.67 GiB
📦 合计：18.01 GiB


---

## 一、准备工作

### 1. 创建 Telegram Bot

1. 打开 Telegram，搜索 `@BotFather`
2. 发送 `/newbot`
3. 按提示输入 bot 名字、用户名
4. 创建成功后，BotFather 会给你一串 **Token**，长这样：
123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxx

**这个 Token 就是 `TG_BOT_TOKEN`，不要泄露给任何人。**

### 2. 获取你的 Chat ID

1. 在 Telegram 里搜索你刚创建的 bot
2. 给它发送 `/start`
3. 用浏览器打开（把 `<TOKEN>` 换成你的 Token）：
https://api.telegram.org/bot<TOKEN>/getUpdates

4. 在返回的 JSON 里找到：

```json
"chat": {
  "id": 2035264761,
  "first_name": "...",
  "username": "..."
}
2035264761 就是你的 Chat ID。

如果 getUpdates 返回空，先给 bot 发一条消息；如果设置了 webhook，先访问 https://api.telegram.org/bot<TOKEN>/deleteWebhook。

二、一键安装
SSH 登录你的 VPS，用 root 执行：

curl -fsSL https://raw.githubusercontent.com/SummerNeko722/vps-traffic-telegram-report/main/vps-traffic-install.sh \
  | bash -s -- \
    --token '<你的BOT_TOKEN>' \
    --chat-id '<你的CHAT_ID>' \
    --name '<你的VPS名字>'

参数说明
参数	必填	说明
--token	✅	Telegram Bot Token
--chat-id	✅	你的 Chat ID
--name	❌	VPS 名字，多台 VPS 用来区分。不填用 hostname
--iface	❌	网卡名，不填自动探测
--skip-test	❌	跳过安装后的测试消息
安装脚本会自动做这些事
把时区设置为 Asia/Shanghai

安装 vnstat、python3、python3-requests

启动并启用 vnstat 服务

自动探测网卡（ens5、eth0 等）

写入配置 /etc/status-send-tg.env

写入脚本 /root/traffic-report.py、/root/traffic-send.sh

创建并启用两个 systemd timer：

traffic-daily.timer 每天 09:00 发日报

traffic-monthly.timer 每月 1 号 09:05 发月报

可选：立即发送一条测试消息

三、多台 VPS
每台机器跑一次安装命令，只需要改 --name：

bash
# 香港机器
... --name 'HK-VPS-1'

# 日本机器
... --name 'JP-VPS-2'

# 美国机器
... --name 'US-VPS-3'
这样 Telegram 消息里会带上主机名，一眼区分。

四、常用命令
查看定时器状态
bash
systemctl list-timers | grep traffic
看到 NEXT 有值说明定时器已生效。

手动发一次日报 / 月报
bash
/root/traffic-send.sh daily
/root/traffic-send.sh monthly
查看某次执行日志
bash
journalctl -u traffic-daily.service -n 50 --no-pager
修改 VPS 名字
bash
nano /etc/status-send-tg.env
# 改 VPS_NAME=xxx
保存后立即生效，不用重启服务。

修改发送时间
bash
systemctl edit traffic-daily.timer
或者直接编辑 /etc/systemd/system/traffic-daily.timer，改 OnCalendar 那一行，然后：

bash
systemctl daemon-reload
systemctl restart traffic-daily.timer
停止 / 卸载
bash
systemctl disable --now traffic-daily.timer traffic-monthly.timer
rm -f /etc/systemd/system/traffic-*.service
rm -f /etc/systemd/system/traffic-*.timer
rm -f /root/traffic-report.py /root/traffic-send.sh
rm -f /etc/status-send-tg.env
systemctl daemon-reload
五、常见问题
1. 装完后没收到测试消息？
vnstat 首次采样需要几分钟。等 10~15 分钟，再执行：

bash
/root/traffic-send.sh daily
2. 消息里时间是 UTC，不是北京时间？
bash
timedatectl set-timezone Asia/Shanghai
systemctl restart traffic-daily.timer traffic-monthly.timer
3. 定时器没触发？
bash
systemctl list-timers | grep traffic
journalctl -u traffic-daily.timer -n 30 --no-pager
4. Token 泄漏了怎么办？
去 @BotFather → 发送 /mybots → 选择你的 bot → API Token → Revoke current token。然后用新 Token 更新：

bash
nano /etc/status-send-tg.env
5. Telegram 消息发不出去？
在 VPS 上测试：

bash
curl -I https://api.telegram.org
如果超时，说明 VPS 所在网络无法直连 Telegram，需要配置代理。编辑 /root/traffic-report.py，把 proxies = None 换成：

python
proxies = {
    "http": "http://127.0.0.1:7890",
    "https": "http://127.0.0.1:7890",
}
六、卸载
bash
systemctl disable --now traffic-daily.timer traffic-monthly.timer
rm -f /etc/systemd/system/traffic-*.{service,timer}
rm -f /root/traffic-report.py /root/traffic-send.sh
rm -f /etc/status-send-tg.env
systemctl daemon-reload
如果要连同 vnstat 一起删：

bash
apt remove --purge -y vnstat
rm -rf /var/lib/vnstat
