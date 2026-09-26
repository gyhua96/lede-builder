#!/usr/bin/env bash
# ==============================================================================
# 脚本：custom.sh
# 作用：OpenWrt / LEDE 全套自定义配置总入口
# 职责：
#   1. 自动配置 feeds.conf.default（剔除 helloworld，精准合入 passwall 官方源）
#   2. 编译阶段阻断 coremark 定时跑分任务（彻底清理其自启和定时跑分触发器）
#   3. 注入开机自配置脚本 (files/etc/uci-defaults/99-custom-settings)：
#      - 默认 LAN IP 设为 10.0.0.1
#      - 默认开启 WiFi，智能区分 2.4G 与 5G，5G 锁定高频纯净 149 信道
#      - 注入防待机休眠掉线参数 (disassoc_low_ack=0, skip_inactivity_poll=1, max_inactivity=600)
#      - WAN 口支持 DHCP 或 PPPoE (放宽 LCP 保活 keepalive 5 5 防止整网重拨)
#      - 调优 IPv6 路由通告 (RA 10~30秒) 并关闭严格源地址过滤 (sourcefilter=0)
#      - 自动配置 Passwall2 分流规则：未分类与游戏流量全面直连 (_direct)
#      - 系统网络内核调优 (tcp_max_syn_backlog 2048) 杜绝高并发 DNS 丢包
#      - 自动创建并自启 512MB Swap 虚拟内存，根治 OOM
#      - 清除运行时残留的 CoreMark 定时跑分任务
# ==============================================================================
set -euo pipefail

TARGET_DIR="${1:-lede}"
CUSTOM_LAN_IP="${CUSTOM_LAN_IP:-10.0.0.1}"
CUSTOM_NETMASK="${CUSTOM_NETMASK:-255.255.255.0}"
CUSTOM_WIFI_SSID="${CUSTOM_WIFI_SSID:-LEDE-WIFI}"
CUSTOM_WIFI_KEY="${CUSTOM_WIFI_KEY:-1234567890}"         # 默认密码 1234567890，留空为无密码
CUSTOM_WIFI_ENCRYPTION="${CUSTOM_WIFI_ENCRYPTION:-psk2}" # 默认 psk2 (WPA2-PSK) 加密
CUSTOM_WIFI_ENABLE="${CUSTOM_WIFI_ENABLE:-0}"           # 0=开启无线(OpenWrt disabled=0代表启用), 1=禁用
CUSTOM_HOSTNAME="${CUSTOM_HOSTNAME:-LEDE-Router}"
CUSTOM_TIMEZONE="${CUSTOM_TIMEZONE:-CST-8}"
CUSTOM_ZONENAME="${CUSTOM_ZONENAME:-Asia/Shanghai}"

# WAN 拨号相关变量
WAN_PROTO="${WAN_PROTO:-dhcp}"                           # "dhcp" 或 "pppoe"
PPPOE_USER="${PPPOE_USER:-}"
PPPOE_PASS="${PPPOE_PASS:-}"

if [ ! -d "${TARGET_DIR}" ]; then
    echo "[-] 错误: 目标源码目录 '${TARGET_DIR}' 不存在！" >&2
    exit 1
fi

echo "=========================================================="
echo "          执行 custom.sh 全套自定义配置注入"
echo "=========================================================="
echo "源码目录:    ${TARGET_DIR}"
echo "默认管理 IP: ${CUSTOM_LAN_IP} (${CUSTOM_NETMASK})"
echo "默认 WiFi:   ${CUSTOM_WIFI_SSID} (5G 锁定 149 信道, 2.4G 为原名, 5G 带 _5G)"
echo "WAN 口协议:  ${WAN_PROTO}"
if [ "${WAN_PROTO}" = "pppoe" ]; then
    echo "PPPoE 账号:  ${PPPOE_USER:-未指定}"
fi
echo "系统主机名:  ${CUSTOM_HOSTNAME}"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. 配置 feeds.conf.default（替换源与移除 helloworld）
# ------------------------------------------------------------------------------
FEEDS_CONF="${TARGET_DIR}/feeds.conf.default"
if [ -f "${FEEDS_CONF}" ]; then
    echo "[*] [1/3] 正在配置 ${FEEDS_CONF} ..."
    rm -f "${TARGET_DIR}/feeds.conf"
    
    # 移除 helloworld
    sed -i '/helloworld/d' "${FEEDS_CONF}"
    
    # 清理已存在的同名源避免重复定义
    sed -i -E '/^[[:space:]]*src-[a-z]+[[:space:]]+(passwall_packages|passwall2)([[:space:]]|$)/d' "${FEEDS_CONF}"
    
    # 精准追加两个 passwall 官方源，不添加其他任何额外 feed
    echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >> "${FEEDS_CONF}"
    echo "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git" >> "${FEEDS_CONF}"
    
    echo "[✓] feeds.conf.default 当前生效源清单："
    grep -E '^[[:space:]]*src-[a-z]+' "${FEEDS_CONF}"
else
    echo "[-] 警告: 未找到 ${FEEDS_CONF}，跳过 Feeds 注入。"
fi

# ------------------------------------------------------------------------------
# 2. 编译阶段拦截与清理 CoreMark 定时任务触发器
# ------------------------------------------------------------------------------
echo ""
echo "[*] [2/3] 正在清理 CoreMark 定时跑分构建脚本..."
# 清理 feeds/packages 中的 coremark 自启动与定时注入代码（如果已拉取 feeds）
if [ -d "${TARGET_DIR}/feeds/packages/utils/coremark" ]; then
    find "${TARGET_DIR}/feeds/packages/utils/coremark" -type f -exec sed -i '/crontab/d' {} + 2>/dev/null || true
    find "${TARGET_DIR}/feeds/packages/utils/coremark" -type f -exec sed -i '/coremark\.sh/d' {} + 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. 注入开机自配置脚本 (files/etc/uci-defaults/99-custom-settings)
# ------------------------------------------------------------------------------
echo ""
echo "[*] [3/3] 正在注入全套开机自启动优化配置..."
OVERLAY_DIR="${TARGET_DIR}/files/etc/uci-defaults"
mkdir -p "${OVERLAY_DIR}"

SETTING_SCRIPT="${OVERLAY_DIR}/99-custom-settings"

cat << 'EOF' > "${SETTING_SCRIPT}"
#!/bin/sh
# OpenWrt First Boot Custom Initialization
# Automatically executed on first system boot

EOF

cat << EOF >> "${SETTING_SCRIPT}"
# 1. 设置 LAN 口 IP 与子网掩码
uci -q batch <<-UCI_LAN
	set network.lan.ipaddr='${CUSTOM_LAN_IP}'
	set network.lan.netmask='${CUSTOM_NETMASK}'
UCI_LAN
uci commit network

# 2. 配置 WAN 口协议 (DHCP 或 PPPoE) 与 LCP 心跳保活 (解决外网定时整网掉线)
if [ "${WAN_PROTO}" = "pppoe" ] && [ -n "${PPPOE_USER}" ]; then
	uci -q batch <<-UCI_WAN
		set network.wan.proto='pppoe'
		set network.wan.username='${PPPOE_USER}'
		set network.wan.password='${PPPOE_PASS}'
		set network.wan.ipv6='auto'
		set network.wan.keepalive='5 5'
	UCI_WAN
	uci commit network
else
	# 预设 keepalive 5 5 (容忍 25 秒抖动，即使后续切 PPPoE 也不掉线)
	uci -q set network.wan.keepalive='5 5'
	uci commit network
fi

# 3. IPv6 协议栈调优：缩短前缀通告周期与放宽源路由过滤 (解决“连着Wi-Fi满格却无网/转圈”)
uci -q batch <<-UCI_IPV6
	set network.wan.sourcefilter='0'
	set network.wan6.sourcefilter='0'
	set dhcp.lan.ra_mininterval='10'
	set dhcp.lan.ra_maxinterval='30'
UCI_IPV6
uci commit network
uci commit dhcp

# 4. 设置系统主机名与时区
uci -q batch <<-UCI_SYS
	set system.@system[0].hostname='${CUSTOM_HOSTNAME}'
	set system.@system[0].timezone='${CUSTOM_TIMEZONE}'
	set system.@system[0].zonename='${CUSTOM_ZONENAME}'
UCI_SYS
uci commit system

# 5. 默认开启并配置 WiFi（5G 迁移至纯净高频 149 信道，解决 5G 断连与撞包）
if [ ! -f /etc/config/wireless ]; then
	/sbin/wifi config 2>/dev/null || true
fi

if [ -f /etc/config/wireless ]; then
	# 开启全部无线硬件 (disabled=0 即开启无线)
	for dev in \$(uci show wireless | grep '=wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
		uci set wireless.\${dev}.disabled='${CUSTOM_WIFI_ENABLE}'
		uci set wireless.\${dev}.country='CN'

		band=\$(uci -q get wireless.\${dev}.band || echo "")
		htmode=\$(uci -q get wireless.\${dev}.htmode || echo "")
		channel=\$(uci -q get wireless.\${dev}.channel || echo "")

		# 若为 5G 射频硬件，强制锁定高频纯净 149 信道并设置 80MHz 频宽
		if [ "\$band" = "5g" ] || [ "\$band" = "6g" ] || [ "\$channel" -gt 14 ] 2>/dev/null || echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
			uci set wireless.\${dev}.channel='149'
			uci set wireless.\${dev}.htmode='HE80'
		fi
	done

	# 遍历无线接口：精准绑定 SSID、设置 psk2 密码、注入防休眠踢人参数
	for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
		uci set wireless.\${iface}.disabled='0'
		# 防手机/移动设备锁屏待机断线调优
		uci set wireless.\${iface}.disassoc_low_ack='0'
		uci set wireless.\${iface}.skip_inactivity_poll='1'
		uci set wireless.\${iface}.max_inactivity='600'

		dev=\$(uci -q get wireless.\${iface}.device || echo "")
		band=\$(uci -q get wireless.\${dev}.band || echo "")
		channel=\$(uci -q get wireless.\${dev}.channel || echo "")
		htmode=\$(uci -q get wireless.\${dev}.htmode || echo "")

		is_5g=0
		if [ "\$band" = "5g" ] || [ "\$band" = "6g" ] || [ "\$channel" -gt 14 ] 2>/dev/null || echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
			is_5g=1
		fi

		if [ "\$is_5g" -eq 1 ]; then
			uci set wireless.\${iface}.ssid='${CUSTOM_WIFI_SSID}_5G'
		else
			uci set wireless.\${iface}.ssid='${CUSTOM_WIFI_SSID}'
		fi

		if [ -n "${CUSTOM_WIFI_KEY}" ]; then
			uci set wireless.\${iface}.encryption='${CUSTOM_WIFI_ENCRYPTION:-psk2}'
			uci set wireless.\${iface}.key='${CUSTOM_WIFI_KEY}'
		else
			uci set wireless.\${iface}.encryption='none'
			uci -q delete wireless.\${iface}.key
		fi
	done
	uci commit wireless
	/sbin/wifi reload 2>/dev/null || true
fi

# 6. Passwall2 分流策略调优：未分类与游戏流量全面国内直连 (根治游戏对局跳 100+ms/断线)
if [ -f /etc/config/passwall2 ]; then
	uci -q batch <<-UCI_PW
		set passwall2.rulenode.default_node='_direct'
		set passwall2.rulenode.ProxyGame='_direct'
		delete passwall2.@global[0].tcp_no_redir_ports 2>/dev/null || true
	UCI_PW
	uci commit passwall2
fi

# 7. 对齐 SSH Banner 版本信息 (与 Web 页面 LEDE R26.05.20 保持一致)
if [ -f /etc/banner ]; then
	sed -i -E 's/OpenWrt[[:space:]]+[0-9.]+/LEDE R26.05.20/g' /etc/banner
fi

# 8. 系统网络内核参数调优 (扩容半连接队列与网络队列，杜绝 DNS 并发丢包)
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-network-stability.conf
net.ipv4.tcp_max_syn_backlog=2048
net.core.netdev_max_backlog=2048
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-network-stability.conf 2>/dev/null || true

# 9. 自动创建并激活 512MB Swap 虚拟内存 (根治 Passwall/Xray 内存击穿 OOM 被强杀)
if [ ! -f /overlay/swapfile ] && [ -d /overlay ]; then
	avail_kb=\$(df -k /overlay | awk 'NR==2 {print \$4}')
	if [ -n "\$avail_kb" ] && [ "\$avail_kb" -gt 819200 ]; then
		dd if=/dev/zero of=/overlay/swapfile bs=1M count=512 2>/dev/null
		chmod 600 /overlay/swapfile
		mkswap /overlay/swapfile 2>/dev/null
		swapon /overlay/swapfile 2>/dev/null || true
	fi
fi

# 将 Swap 自启持久化注入 /etc/rc.local
if [ -f /etc/rc.local ] && ! grep -q "swapfile" /etc/rc.local; then
	sed -i '/exit 0/i [ -f /overlay/swapfile ] && swapon /overlay/swapfile 2>/dev/null' /etc/rc.local
fi

# 10. 彻底清理与阻断 CoreMark 定时跑分任务 (防止每日凌晨跑分吃满 CPU 与内存)
sed -i '/coremark/d' /etc/crontabs/root 2>/dev/null || true
rm -f /etc/coremark.sh /etc/uci-defaults/xxx-coremark 2>/dev/null || true

exit 0
EOF

chmod +x "${SETTING_SCRIPT}"
echo "[✓] 自定义启动配置注入成功: ${SETTING_SCRIPT}"
echo "=========================================================="
echo "          custom.sh 全部操作执行完成"
echo "=========================================================="
