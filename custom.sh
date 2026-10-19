#!/usr/bin/env bash
# ==============================================================================
# 脚本：custom.sh
# 作用：OpenWrt / LEDE 自定义配置入口分发器
# 说明：依据目标平台 (TARGET_SEED) 自动调用 custom/<TARGET_SEED>.sh 专用脚本
# ==============================================================================
set -euo pipefail

TARGET_DIR="${1:-lede}"
TARGET_SEED="${2:-${TARGET_SEED:-jdcloud_re-ss-01}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_SCRIPT="${SCRIPT_DIR}/custom/${TARGET_SEED}.sh"

if [ ! -f "${DEVICE_SCRIPT}" ]; then
    echo "[-] 错误: 未找到目标平台 '${TARGET_SEED}' 对应的定制脚本: ${DEVICE_SCRIPT}" >&2
    echo "    当前支持平台脚本: $(ls "${SCRIPT_DIR}/custom/" 2>/dev/null || echo '无')" >&2
    exit 1
fi

chmod +x "${DEVICE_SCRIPT}"
exec "${DEVICE_SCRIPT}" "${TARGET_DIR}"
