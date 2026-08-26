#!/usr/bin/env bash
# 编译单个设备的 LEDE 固件
# 用法: DEVICE_NAME=m28c ./build.sh
# 可选环境变量:
#   LEDE_REPO   LEDE 仓库地址 (默认 https://github.com/coolsnowwolf/lede.git)
#   LEDE_BRANCH LEDE 分支 (默认 master)
#   JOBS        并行编译数 (默认 $(nproc))
#   QMODEM_FEED QModem 软件源地址 (默认 https://github.com/FUjr/QModem.git)
# 约定: 设备配置位于 devices/<DEVICE_NAME>.config;
#       配置中含 CONFIG_FEED_qmodem=y 时自动向 feeds.conf.default 注入 QModem 软件源。
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_NAME="${DEVICE_NAME:?需要设置 DEVICE_NAME (设备配置文件名，不含 .config 后缀)}"
DEVICE_CONFIG="devices/${DEVICE_NAME}.config"
LEDE_REPO="${LEDE_REPO:-https://github.com/coolsnowwolf/lede.git}"
LEDE_BRANCH="${LEDE_BRANCH:-master}"
JOBS="${JOBS:-$(nproc)}"
QMODEM_FEED="${QMODEM_FEED:-https://github.com/FUjr/QModem.git}"

[ -f "$DEVICE_CONFIG" ] || { echo "错误: 找不到设备配置 $DEVICE_CONFIG" >&2; exit 1; }

# 1. 获取 LEDE 源码
git clone --depth 1 -b "$LEDE_BRANCH" "$LEDE_REPO" lede
cd lede

# 2. 应用设备配置
cp "../devices/${DEVICE_NAME}.config" .config

# 3. 按需注入 QModem 软件源 (仅当设备配置启用了 CONFIG_FEED_qmodem)
if grep -q '^CONFIG_FEED_qmodem=y' "../devices/${DEVICE_NAME}.config"; then
  if ! grep -q 'src-git qmodem' feeds.conf.default; then
    echo "src-git qmodem ${QMODEM_FEED}" >> feeds.conf.default
    echo "已注入 QModem 软件源: ${QMODEM_FEED}"
  fi
fi

# 4. 更新 feeds 并编译
make update
make -j"$JOBS"

# 5. 收集产物到仓库根目录 bin/
mkdir -p ../bin
cp -v bin/targets/*/*/*.img* ../bin/ 2>/dev/null || true
