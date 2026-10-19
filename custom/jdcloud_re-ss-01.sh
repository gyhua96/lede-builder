#!/usr/bin/env bash
# ==============================================================================
# 脚本：custom/jdcloud_re-ss-01.sh
# 作用：京东云 AX1800 Pro (IPQ60xx / RE-SS-01) 专用定制与环境配置
# ==============================================================================
set -euo pipefail

TARGET_DIR="${1:-lede}"
CUSTOM_LAN_IP="${CUSTOM_LAN_IP:-10.0.0.1}"
CUSTOM_NETMASK="${CUSTOM_NETMASK:-255.255.255.0}"
CUSTOM_WIFI_SSID="${CUSTOM_WIFI_SSID:-LEDE-WIFI}"
CUSTOM_WIFI_KEY="${CUSTOM_WIFI_KEY:-1234567890}"         # 默认密码 1234567890，留空为无密码
CUSTOM_WIFI_ENCRYPTION="${CUSTOM_WIFI_ENCRYPTION:-psk2}" # 默认 psk2 (WPA2-PSK) 加密
CUSTOM_WIFI_ENABLE="${CUSTOM_WIFI_ENABLE:-0}"           # 0=开启无线, 1=禁用
CUSTOM_HOSTNAME="${CUSTOM_HOSTNAME:-LEDE-Router}"
CUSTOM_TIMEZONE="${CUSTOM_TIMEZONE:-CST-8}"
CUSTOM_ZONENAME="${CUSTOM_ZONENAME:-Asia/Shanghai}"

# WAN 拨号相关变量
WAN_PROTO="${WAN_PROTO:-dhcp}"
PPPOE_USER="${PPPOE_USER:-}"
PPPOE_PASS="${PPPOE_PASS:-}"

if [ ! -d "${TARGET_DIR}" ]; then
    echo "[-] 错误: 目标源码目录 '${TARGET_DIR}' 不存在！" >&2
    exit 1
fi

echo "=========================================================="
echo "  [JDCloud RE-SS-01] 执行定制脚本与环境配置注入"
echo "=========================================================="
echo "源码目录:    ${TARGET_DIR}"
echo "默认管理 IP: ${CUSTOM_LAN_IP} (${CUSTOM_NETMASK})"
echo "默认 WiFi:   ${CUSTOM_WIFI_SSID} (5G 锁定 149 信道)"
echo "WAN 口协议:  ${WAN_PROTO}"
echo "系统主机名:  ${CUSTOM_HOSTNAME}"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. 配置 feeds.conf.default（置顶优先注入 passwall 官方源，剔除 helloworld）
# ------------------------------------------------------------------------------
FEEDS_CONF="${TARGET_DIR}/feeds.conf.default"
if [ -f "${FEEDS_CONF}" ]; then
    echo "[*] [1/4] 正在优化配置 ${FEEDS_CONF} ..."
    rm -f "${TARGET_DIR}/feeds.conf"
    sed -i '/helloworld/d' "${FEEDS_CONF}"
    sed -i -E '/^[[:space:]]*src-[a-z]+[[:space:]]+(passwall_packages|passwall2)([[:space:]]|$)/d' "${FEEDS_CONF}"
    sed -i '1i src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git' "${FEEDS_CONF}"
    sed -i '1i src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' "${FEEDS_CONF}"
fi

# ------------------------------------------------------------------------------
# 2. 京东云 AX1800 Pro (IPQ60xx) 专用构建层补丁：
#    切换 FitImageLzma 强力压缩，确保内核体积严格对齐 0:HLOS 6MB 物理红线
# ------------------------------------------------------------------------------
IPQ60XX_MK="${TARGET_DIR}/target/linux/qualcommax/image/ipq60xx.mk"
if [ -f "${IPQ60XX_MK}" ]; then
    echo "[*] [2/4] 配置 FitImageLzma 压缩，锁定 KERNEL_SIZE 为 6144k (0:HLOS 物理上限)..."
    sed -i '/define Device\/jdcloud_re-ss-01/,/endef/ s/\$(call Device\/FitImage)/\$(call Device\/FitImageLzma)/' "${IPQ60XX_MK}"
    sed -i '/define Device\/jdcloud_re-ss-01/,/endef/ s/KERNEL_SIZE := 12288k/KERNEL_SIZE := 6144k/' "${IPQ60XX_MK}"
fi

# 确保 hostapd-basic 编译时启用 CONFIG_WNM=y (802.11v BSS Transition 漫游支持)
HOSTAPD_BASIC_CONF="${TARGET_DIR}/package/network/services/hostapd/files/hostapd-basic.config"
if [ -f "${HOSTAPD_BASIC_CONF}" ]; then
    sed -i 's/#CONFIG_WNM=y/CONFIG_WNM=y/' "${HOSTAPD_BASIC_CONF}"
fi

# ------------------------------------------------------------------------------
# 3. 清理 CoreMark 定时跑分构建脚本
# ------------------------------------------------------------------------------
echo "[*] [3/4] 正在清理 CoreMark 定时跑分构建脚本..."
if [ -d "${TARGET_DIR}/feeds/packages/utils/coremark" ]; then
    find "${TARGET_DIR}/feeds/packages/utils/coremark" -type f -exec sed -i '/crontab/d' {} + 2>/dev/null || true
    find "${TARGET_DIR}/feeds/packages/utils/coremark" -type f -exec sed -i '/coremark\.sh/d' {} + 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 4. 注入开机自配置脚本 (files/etc/uci-defaults/99-custom-settings)
# ------------------------------------------------------------------------------
echo "[*] [4/4] 正在注入京东云 AX1800 Pro 开机自启动优化配置..."
OVERLAY_DIR="${TARGET_DIR}/files/etc/uci-defaults"
mkdir -p "${OVERLAY_DIR}"

SETTING_SCRIPT="${OVERLAY_DIR}/99-custom-settings"

cat << 'EOF' > "${SETTING_SCRIPT}"
#!/bin/sh
# OpenWrt First Boot Custom Initialization for JDCloud RE-SS-01
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
	uci -q set network.wan.keepalive='5 5'
	uci commit network
fi

# 3. IPv6 协议栈调优：缩短前缀通告周期与放宽源路由过滤
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

# 5. 默认开启并配置 WiFi（高通 Wi-Fi 6 架构，5G 锁定 149 高频纯净信道，支持 802.11k/v/r）
if [ ! -f /etc/config/wireless ]; then
	/sbin/wifi config 2>/dev/null || true
fi

if [ -f /etc/config/wireless ]; then
	for dev in \$(uci show wireless | grep '=wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
		uci set wireless.\${dev}.disabled='${CUSTOM_WIFI_ENABLE}'
		uci set wireless.\${dev}.country='CN'

		band=\$(uci -q get wireless.\${dev}.band || echo "")
		htmode=\$(uci -q get wireless.\${dev}.htmode || echo "")
		channel=\$(uci -q get wireless.\${dev}.channel || echo "0")

		is_5g=0
		if [ "\$band" = "5g" ] || [ "\$band" = "6g" ] || [ "\${channel:-0}" -gt 14 ] 2>/dev/null || echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
			is_5g=1
		fi

		if [ "\$is_5g" -eq 1 ]; then
			uci set wireless.\${dev}.channel='149'
			if echo "\$htmode" | grep -q -E 'HE'; then
				uci set wireless.\${dev}.htmode='HE80'
			else
				uci set wireless.\${dev}.htmode='VHT80'
			fi
		else
			if [ "\${channel:-0}" -gt 14 ] 2>/dev/null; then
				uci set wireless.\${dev}.channel='1'
			fi
			if echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
				uci set wireless.\${dev}.htmode='HT20'
			fi
		fi
	done

	for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
		dev=\$(uci -q get wireless.\${iface}.device || echo "")
		band=\$(uci -q get wireless.\${dev}.band || echo "")
		htmode=\$(uci -q get wireless.\${dev}.htmode || echo "")
		channel=\$(uci -q get wireless.\${dev}.channel || echo "0")

		uci set wireless.\${iface}.disabled='0'

		is_5g=0
		if [ "\$band" = "5g" ] || [ "\$band" = "6g" ] || [ "\${channel:-0}" -gt 14 ] 2>/dev/null || echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
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

		# 802.11k/v 漫游
		uci set wireless.\${iface}.ieee80211k='1'
		uci set wireless.\${iface}.rrm_neighbor_report='1'
		uci set wireless.\${iface}.rrm_beacon_report='1'
		uci set wireless.\${iface}.bss_transition='1'
		uci set wireless.\${iface}.wnm_sleep_mode='1'

		# 802.11r 快速漫游
		uci set wireless.\${iface}.ieee80211r='1'
		uci set wireless.\${iface}.ft_over_ds='1'
		uci set wireless.\${iface}.ft_psk_generate_local='1'
		uci set wireless.\${iface}.mobility_domain='e4a1'
	done
	uci commit wireless
	/sbin/wifi reload 2>/dev/null || true
fi

# 6. Passwall2 分流策略调优：未分类与游戏流量全面国内直连，严格关闭本机代理
if [ -f /etc/config/passwall2 ]; then
	uci -q batch <<-UCI_PW
		set passwall2.rulenode.default_node='_direct'
		set passwall2.rulenode.ProxyGame='_direct'
		set passwall2.@global[0].localhost_proxy='0'
		delete passwall2.@global[0].tcp_no_redir_ports 2>/dev/null || true
	UCI_PW
	uci commit passwall2
fi

# 7. 对齐 SSH Banner 版本信息
if [ -f /etc/banner ]; then
	sed -i -E 's/OpenWrt[[:space:]]+[0-9.]+/LEDE R26.05.20/g' /etc/banner
fi

# 8. 系统日志持久化落盘
mkdir -p /etc/log
uci -q batch <<-UCI_LOG
	set system.@system[0].log_file='/etc/log/system.log'
	set system.@system[0].log_size='2048'
UCI_LOG
uci commit system

# 9. 缩减 nlbwmon 内存 Netlink 缓冲区至 2MB
if [ -f /etc/config/nlbwmon ]; then
	uci -q set nlbwmon.@nlbwmon[0].netlink_buffer_size='2097152'
	uci commit nlbwmon
fi

# 10. 系统网络内核参数调优 (扩容半连接队列与网络队列，调优 Swap 与缓存回收)
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-network-stability.conf
net.ipv4.tcp_max_syn_backlog=2048
net.core.netdev_max_backlog=2048
# 仅在内存极度吃紧时才使用 Swap
vm.swappiness=1
# 激进回收无用的 inode 与 dentry 文件系统缓存，防止 PageCache 占死内存
vm.vfs_cache_pressure=150
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-network-stability.conf 2>/dev/null || true

# 11. 利用 eMMC /overlay 空间创建并激活 512MB Swap 虚拟内存 (防 OOM)
if [ ! -f /overlay/swapfile ] && [ -d /overlay ]; then
	avail_kb=\$(df -k /overlay | awk 'NR==2 {print \$4}')
	if [ -n "\$avail_kb" ] && [ "\$avail_kb" -gt 819200 ]; then
		if ! fallocate -l 512M /overlay/swapfile 2>/dev/null; then
			dd if=/dev/zero of=/overlay/swapfile bs=1M count=512 2>/dev/null
		fi
		chmod 600 /overlay/swapfile
		mkswap /overlay/swapfile 2>/dev/null
		swapon /overlay/swapfile 2>/dev/null || true
	fi
fi

if [ -f /etc/rc.local ] && ! grep -q "swapfile" /etc/rc.local; then
	sed -i '/exit 0/i [ -f /overlay/swapfile ] && swapon /overlay/swapfile 2>/dev/null' /etc/rc.local
fi

# 12. 彻底清理与阻断 CoreMark 定时跑分任务
sed -i '/coremark/d' /etc/crontabs/root 2>/dev/null || true
rm -f /etc/coremark.sh /etc/uci-defaults/xxx-coremark 2>/dev/null || true

exit 0
EOF

chmod +x "${SETTING_SCRIPT}"
echo "[✓] 京东云 AX1800 Pro 自定义启动配置注入成功: ${SETTING_SCRIPT}"
echo "=========================================================="
