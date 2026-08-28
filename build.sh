#!/usr/bin/env bash
# 编译单个设备的 LEDE 固件
# 用法: DEVICE_NAME=m28c ./build.sh
# 可选环境变量:
#   LEDE_REPO   LEDE 仓库地址 (默认 https://github.com/coolsnowwolf/lede.git)
#   LEDE_TAG    固定源码 tag (如 openwrt-23.05.6), 显式指定时优先级最高
#               (coolsnowwolf/lede 基本不发布源码 tag, 需固定版本时建议
#               将 LEDE_REPO 切到 openwrt/openwrt 官方仓库再用 LEDE_TAG)
#   LEDE_BRANCH 固定分支, 显式指定时优先于自动探测
#   JOBS        并行编译数 (默认 $(nproc))
#   QMODEM_FEED QModem 软件源地址 (默认 https://github.com/FUjr/QModem.git)
#   VERBOSE     非空时 make 加 V=s, 输出详细日志便于排查构建失败
# 默认策略 (LEDE_TAG/LEDE_BRANCH 均留空): 自动固定当前稳定版本, 而不是最新提交:
#   ① 优先取仓库最新稳定 tag (排除 rc/alpha/beta/pre 等候选);
#   ② 无稳定 tag 则按 openwrt-23.05 → openwrt-22.03 → openwrt-21.02 → master
#      顺序选第一个存在的分支 (master 仅作最后回退)。
# 约定: 设备配置位于 devices/<DEVICE_NAME>.config;
#       配置中含 CONFIG_FEED_qmodem=y 时自动向 feeds.conf.default 注入 QModem 软件源。
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_NAME="${DEVICE_NAME:?需要设置 DEVICE_NAME (设备配置文件名，不含 .config 后缀)}"
DEVICE_CONFIG="devices/${DEVICE_NAME}.config"
LEDE_REPO="${LEDE_REPO:-https://github.com/coolsnowwolf/lede.git}"
LEDE_TAG="${LEDE_TAG:-}"
LEDE_BRANCH="${LEDE_BRANCH:-}"
JOBS="${JOBS:-$(nproc)}"
QMODEM_FEED="${QMODEM_FEED:-https://github.com/FUjr/QModem.git}"
VERBOSE="${VERBOSE:-}"

[ -f "$DEVICE_CONFIG" ] || { echo "错误: 找不到设备配置 $DEVICE_CONFIG" >&2; exit 1; }

# 0. 确定源码版本 REF (优先级: LEDE_TAG > LEDE_BRANCH > 自动探测)
if [ -n "$LEDE_TAG" ]; then
  REF="$LEDE_TAG"
  echo "使用指定 tag: $REF"
elif [ -n "$LEDE_BRANCH" ]; then
  REF="$LEDE_BRANCH"
  echo "使用指定分支: $REF"
else
  # ① 自动取最新稳定 tag (排除 rc/alpha/beta/pre/test/snapshot 等非稳定后缀)
  TAGS="$(git ls-remote --tags --refs "$LEDE_REPO" | sed 's#.*refs/tags/##' || true)"
  STABLE="$(printf '%s\n' "$TAGS" | grep -viE '(^|[-_.])?(rc|alpha|beta|pre|test|snapshot)([-_.]|$)' || true)"
  REF="$(printf '%s\n' "$STABLE" | sort -V | tail -n 1 || true)"
  if [ -n "$REF" ]; then
    echo "已自动选择最新稳定 tag: $REF"
  else
    # ② 无稳定 tag, 回退候选分支 (按稳定优先级)
    HEADS="$(git ls-remote --heads "$LEDE_REPO" || true)"
    REF=""
    for c in openwrt-23.05 openwrt-22.03 openwrt-21.02 master; do
      if printf '%s\n' "$HEADS" | grep -q "refs/heads/$c$"; then
        REF="$c"
        echo "已自动选择分支: $REF"
        break
      fi
    done
    [ -n "$REF" ] || { echo "错误: $LEDE_REPO 中无稳定 tag 也无候选分支 (openwrt-23.05/22.03/21.02/master)" >&2; exit 1; }
  fi
fi

# 1. 获取 LEDE 源码 (tag/分支均可用 -b 检出)
git clone --depth 1 -b "$REF" "$LEDE_REPO" lede
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

# 4. 同步配置: 设备配置可能落后于目标源码 ($REF) 的 Kconfig,
#    先重新同步 (非交互, 保留已有选择, 新增符号取默认值)
make defconfig

# 4a. 设备校验: 目标源码若已移除该设备, defconfig 会静默丢弃对应符号,
#     继续编译将产出错误的默认设备固件, 因此检测到丢弃时中止本设备构建。
MISSING=()
while IFS= read -r sym; do
  if ! grep -q "^${sym}=y" .config; then
    MISSING+=("$sym")
  fi
done < <(grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9-]+=y' "../devices/${DEVICE_NAME}.config" || true)
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "错误: 源码版本 $REF 不包含以下设备符号, 已中止编译:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  echo "提示: 该设备未在所选源码的 target/linux 中定义, 或设备配置已过期。" >&2
  exit 1
fi

# 5. 更新 feeds 并编译 (LEDE 无 make update 目标, 需直接调用 scripts/feeds;
#    feeds 更新后配置可能再次不同步, 需再同步一次)
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
# VERBOSE 非空时输出详细日志 (make V=s), 便于定位编译失败根因
make -j"$JOBS" ${VERBOSE:+V=s}

# 6. 收集产物到仓库根目录 bin/
mkdir -p ../bin
cp -v bin/targets/*/*/*.img* ../bin/ 2>/dev/null || true
