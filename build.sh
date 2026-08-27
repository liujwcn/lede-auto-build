#!/usr/bin/env bash
# 编译单个设备的 LEDE 固件
# 用法: DEVICE_NAME=m28c ./build.sh
# 可选环境变量:
#   LEDE_REPO   LEDE 仓库地址 (默认 https://github.com/coolsnowwolf/lede.git)
#   LEDE_BRANCH 目标分支 (默认自动探测稳定分支: 按 openwrt-23.05 → openwrt-22.03
#               → openwrt-21.02 → master 顺序选第一个存在的分支)
#   JOBS        并行编译数 (默认 $(nproc))
#   QMODEM_FEED QModem 软件源地址 (默认 https://github.com/FUjr/QModem.git)
# 约定: 设备配置位于 devices/<DEVICE_NAME>.config;
#       配置中含 CONFIG_FEED_qmodem=y 时自动向 feeds.conf.default 注入 QModem 软件源。
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_NAME="${DEVICE_NAME:?需要设置 DEVICE_NAME (设备配置文件名，不含 .config 后缀)}"
DEVICE_CONFIG="devices/${DEVICE_NAME}.config"
LEDE_REPO="${LEDE_REPO:-https://github.com/coolsnowwolf/lede.git}"
# 留空 = 自动探测稳定分支 (见下方第 0 步)
LEDE_BRANCH="${LEDE_BRANCH:-}"
JOBS="${JOBS:-$(nproc)}"
QMODEM_FEED="${QMODEM_FEED:-https://github.com/FUjr/QModem.git}"

[ -f "$DEVICE_CONFIG" ] || { echo "错误: 找不到设备配置 $DEVICE_CONFIG" >&2; exit 1; }

# 0. 探测目标分支: LEDE_BRANCH 显式指定则直接使用;
#    否则一次性拉取分支列表, 按候选顺序选第一个已存在的分支
#    (master 通常最不稳定, 仅作最后回退)。
if [ -n "$LEDE_BRANCH" ]; then
  BRANCH="$LEDE_BRANCH"
  echo "使用指定分支: $BRANCH"
else
  HEADS="$(git ls-remote --heads "$LEDE_REPO" || true)"
  BRANCH=""
  for c in openwrt-23.05 openwrt-22.03 openwrt-21.02 master; do
    if printf '%s\n' "$HEADS" | grep -q "refs/heads/$c$"; then
      BRANCH="$c"
      echo "已自动选择分支: $BRANCH"
      break
    fi
  done
  [ -n "$BRANCH" ] || { echo "错误: $LEDE_REPO 中不存在候选分支 (openwrt-23.05/22.03/21.02/master)" >&2; exit 1; }
fi

# 1. 获取 LEDE 源码
git clone --depth 1 -b "$BRANCH" "$LEDE_REPO" lede
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

# 4. 同步配置: 设备配置可能落后于目标分支 ($BRANCH) 的 Kconfig,
#    先重新同步 (非交互, 保留已有选择, 新增符号取默认值)
make defconfig

# 4a. 设备校验: 目标分支若已移除该设备, defconfig 会静默丢弃对应符号,
#     继续编译将产出错误的默认设备固件, 因此检测到丢弃时中止本设备构建。
MISSING=()
while IFS= read -r sym; do
  if ! grep -q "^${sym}=y" .config; then
    MISSING+=("$sym")
  fi
done < <(grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9-]+=y' "../devices/${DEVICE_NAME}.config" || true)
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "错误: 分支 $BRANCH 不包含以下设备符号, 已中止编译:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  echo "提示: 该设备未在目标分支的 target/linux 中定义, 或设备配置已过期。" >&2
  exit 1
fi

# 5. 更新 feeds 并编译 (LEDE 无 make update 目标, 需直接调用 scripts/feeds;
#    feeds 更新后配置可能再次不同步, 需再同步一次)
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make -j"$JOBS"

# 6. 收集产物到仓库根目录 bin/
mkdir -p ../bin
cp -v bin/targets/*/*/*.img* ../bin/ 2>/dev/null || true
