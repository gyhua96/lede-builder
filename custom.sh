#!/usr/bin/env bash
# ==============================================================================
# 脚本：custom.sh
# 作用：OpenWrt / LEDE 全套自定义配置总入口
# 职责：
#   1. 自动配置 feeds.conf.default（剔除 helloworld，精准合入 passwall 官方源）
#   2. 注入开机初始化网络脚本：
#      - 默认 LAN IP 设为 10.0.0.1
#      - 默认开启 WiFi，智能识别 2.4G 与 5G 频段设置 SSID
#      - 支持配置 WAN 口上网协议（DHCP 或 PPPoE 拨号账号密码）
#   3. 通过 files/etc/uci-defaults/ 机制实现，不修改任何源码 tracked 文件
# ==============================================================================
set -euo pipefail

TARGET_DIR="${1:-lede}"
CUSTOM_LAN_IP="${CUSTOM_LAN_IP:-10.0.0.1}"
CUSTOM_NETMASK="${CUSTOM_NETMASK:-255.255.255.0}"
CUSTOM_WIFI_SSID="${CUSTOM_WIFI_SSID:-LEDE-WIFI}"
CUSTOM_WIFI_KEY="${CUSTOM_WIFI_KEY:-}"                   # 留空为无密码
CUSTOM_WIFI_ENCRYPTION="${CUSTOM_WIFI_ENCRYPTION:-none}" # "none" 或 "psk2"
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
echo "默认 WiFi:   ${CUSTOM_WIFI_SSID} (2.4G 为原名称, 5G 自动附加 _5G 后缀)"
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
    echo "[*] [1/2] 正在配置 ${FEEDS_CONF} ..."
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
# 2. 注入开机自配置脚本 (files/etc/uci-defaults/99-custom-settings)
# ------------------------------------------------------------------------------
echo ""
echo "[*] [2/2] 正在注入开机启动设置..."
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

# 2. 配置 WAN 口上网协议 (DHCP 或 PPPoE)
if [ "${WAN_PROTO}" = "pppoe" ] && [ -n "${PPPOE_USER}" ]; then
	uci -q batch <<-UCI_WAN
		set network.wan.proto='pppoe'
		set network.wan.username='${PPPOE_USER}'
		set network.wan.password='${PPPOE_PASS}'
		set network.wan.ipv6='auto'
	UCI_WAN
	uci commit network
fi

# 3. 设置系统主机名与时区
uci -q batch <<-UCI_SYS
	set system.@system[0].hostname='${CUSTOM_HOSTNAME}'
	set system.@system[0].timezone='${CUSTOM_TIMEZONE}'
	set system.@system[0].zonename='${CUSTOM_ZONENAME}'
UCI_SYS
uci commit system

# 4. 默认开启并配置 WiFi（精准识别 2.4G 与 5G 频段，杜绝颠倒）
if [ ! -f /etc/config/wireless ]; then
	/sbin/wifi config 2>/dev/null || true
fi

if [ -f /etc/config/wireless ]; then
	# 开启全部无线射频硬件 (disabled=0 即开启无线)
	for dev in \$(uci show wireless | grep '=wifi-device' | cut -d'.' -f2 | cut -d'=' -f1); do
		uci set wireless.\${dev}.disabled='${CUSTOM_WIFI_ENABLE}'
		uci set wireless.\${dev}.country='CN'
	done

	# 遍历无线接口，读取对应射频设备的 band / channel 精准判定频段
	for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
		uci set wireless.\${iface}.disabled='0'
		dev=\$(uci -q get wireless.\${iface}.device || echo "")
		band=\$(uci -q get wireless.\${dev}.band || echo "")
		channel=\$(uci -q get wireless.\${dev}.channel || echo "")
		htmode=\$(uci -q get wireless.\${dev}.htmode || echo "")

		is_5g=0
		# 判定 1: 声明了 5g 或 6g 频段
		if [ "\$band" = "5g" ] || [ "\$band" = "6g" ]; then
			is_5g=1
		# 判定 2: 信道大于 14 (标准 2.4G 最大信道为 14)
		elif [ -n "\$channel" ] && [ "\$channel" -gt 14 ] 2>/dev/null; then
			is_5g=1
		# 判定 3: htmode 包含 VHT 或 HE80/HE160
		elif echo "\$htmode" | grep -q -E 'VHT|HE80|HE160'; then
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

# 5. 对齐 SSH Banner 版本信息 (与 Web 页面 LEDE R26.05.20 保持一致)
if [ -f /etc/banner ]; then
	sed -i -E 's/OpenWrt[[:space:]]+[0-9.]+/LEDE R26.05.20/g' /etc/banner
fi

exit 0
EOF

chmod +x "${SETTING_SCRIPT}"
echo "[✓] 自定义启动配置注入成功: ${SETTING_SCRIPT}"
echo "=========================================================="
echo "          custom.sh 全部操作执行完成"
echo "=========================================================="
