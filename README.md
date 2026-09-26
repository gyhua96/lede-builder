# OpenWrt (LEDE) 自动化固件构建仓库

基于 GitHub Actions 的 OpenWrt (Lean's LEDE) 自动化编译工作流。

---

## 项目目录结构

```text
├── .github/
│   └── workflows/
│       └── build-openwrt.yml         # GitHub Actions 自动化编译流水线
├── config/
│   └── jdcloud_re-ss-01.seed.config  # 目标设备精简差异配置 (京东云 RE-SS-01 / IPQ60xx)
├── custom.sh                         # 自定义配置注入脚本 (Feeds / 默认 IP / 默认 WiFi)
└── README.md
```

---

## 预置特性与配置

1. **默认管理 IP**：`10.0.0.1`（子网掩码：`255.255.255.0`）。
2. **默认无线网络与防休眠掉线**：
   - WiFi 默认开启（`disabled=0`），SSID 默认为 `LEDE-WIFI`（5G 频段自动带 `_5G` 后缀）。
   - **5G 信道调优**：强制锁定纯净高频 **149 信道**（80MHz 频宽，5775MHz），避开周边低频段（36~48）严重同频撞包冲突，解决 5G 握手失败与断连。
   - 默认使用 `psk2` 加密，密码为 `1234567890`（支持在 Workflow 中自定义或留空设为无密码）。
   - **防待机掉线调优**：禁用低应答暴力断开（`disassoc_low_ack=0`）、开启跳过空闲轮询探测（`skip_inactivity_poll=1`）、离线超时放宽至 10 分钟（`max_inactivity=600`），根治手机息屏待机断网。
3. **WAN 口支持 PPPoE / DHCP 与防掉线心跳**：
   - 默认通过 DHCP 上网。
   - 在 Actions 触发或运行时传入 `wan_proto=pppoe` 以及宽带账号密码，即可直接刷机自动拨号。
   - **PPPoE 稳定性加固**：预设 `keepalive='5 5'`（放宽 LCP 心跳，容忍 25 秒抖动，根治每 30~80 分钟整网短暂掉线）。
4. **IPv6 协议栈防假死优化**：
   - 缩短路由通告周期至 `ra_mininterval='10'`、`ra_maxinterval='30'`，关闭严格源路由过滤（`sourcefilter='0'`），彻底解决运营商换前缀后手机显示满格却“无网转圈”问题。
5. **Passwall2 游戏与未分类对局流量直连**：
   - 预设 `default_node='_direct'` 与 `ProxyGame='_direct'`，未识别与游戏流量一律走本地超低延迟直连，绝不绕道海外代理，根治游戏对局跳 100+ms/掉线。
6. **彻底去除 CoreMark 跑分与定时任务**：
   - 配置与构建全链路阻断 `coremark`，清除其开机与凌晨 4 点定时触发的 CPU 满载跑分任务。
7. **内存防崩溃保护 (Swap)**：
   - 首次开机时自动利用 `/overlay` 空间生成并激活 512MB 虚拟内存（`/overlay/swapfile`），持久化注入 `/etc/rc.local` 开机自启，彻底杜绝 Passwall/Xray 高并发下的 OOM 闪退崩溃。
8. **内核网络队列调优**：
   - 预设 `net.ipv4.tcp_max_syn_backlog=2048` 与 `net.core.netdev_max_backlog=2048`，解决本地 DNS (端口 2004) 高并发 SYN flood 丢包与网页白屏卡顿。
9. **插件源定制**：
   - 移除原仓库自带的 `helloworld` 源。
   - 自动集成官方 `passwall_packages` 与 `passwall2` 软件源。
4. **默认设备配置**：
   - 内置 `jdcloud_re-ss-01` 配置文件，包含 Passwall2、Sing-box、MosDNS、Haproxy、Argon 主题、F2FS 与 SFE 网络加速等核心组件。
5. **零源码污染机制**：
   - IP 与 WiFi 设置通过 OpenWrt 原生 `files/etc/uci-defaults/` 机制在首次开机时自动应用并自毁。
   - 不修改上游源码的 tracked 文件，确保未来源码更新无任何 Git 冲突。

---

## 使用方法

### 方式一：通过 GitHub Actions 编译（推荐）

1. 将本项目推送至你的 GitHub 仓库。
2. 进入仓库页面的 **Actions** 标签。
3. 在左侧选择 **Build OpenWrt (LEDE) Firmware** 工作流。
4. 点击 **Run workflow**：
   - **target_seed**: 目标设备配置文件名（默认 `jdcloud_re-ss-01`）
   - **custom_ip**: 后台管理 IP（默认 `10.0.0.1`）
   - **custom_ssid**: 默认 WiFi 名称（默认 `LEDE-WIFI`）
5. 编译完成后，在流水线页面的 **Artifacts** 区域直接下载固件镜像。

### 方式二：本地或自建环境使用

在已克隆好的 LEDE 源码根目录下，直接调用 `custom.sh` 即可完成全部配置注入：

```bash
# 1. 克隆 LEDE 源码
git clone https://github.com/coolsnowwolf/lede.git lede

# 2. 执行自定义脚本 (完成 feeds.conf.default 调整及默认 IP/WiFi 注入)
./custom.sh lede

# 3. 安装 feeds 依赖
cd lede
./scripts/feeds update -a
./scripts/feeds install -a

# 4. 加载目标设备配置并展开依赖
cp ../config/jdcloud_re-ss-01.seed.config .config
FORCE=1 make defconfig

# 5. 下载依赖包并开始编译
make download -j8
make -j$(nproc) || make -j1 V=s
```
