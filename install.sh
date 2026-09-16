#!/bin/bash
# DSH Desktop 一键安装 / 体检脚本
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/EnderWolf006/dsh-macos/main/install.sh | bash
#       三段式：① 环境预检 ② 下载安装 ③ 状态回馈
#
#   curl -fsSL https://raw.githubusercontent.com/EnderWolf006/dsh-macos/main/install.sh | bash -s -- doctor
#       只读体检：逐项检查本地环境与应用运行状态，输出人读报告 + KEY=VALUE 行（供 agent 解析）。
#       追加 --fix 可执行白名单内的安全修复（当前仅：清理失效的命令解析缓存）。
#
# 说明：curl 下载的文件不带隔离标记，Gatekeeper 不介入，无需任何签名证书。
set -euo pipefail

REPO="EnderWolf006/dsh-macos"
APP_NAME="DSH Desktop.app"
BUNDLE_ID="com.deepseek-ai.dsh-desktop"
ASSET="DSH.MacOS.Desktop.zip"   # GitHub 会把资产名空格归一化为点号，直接用点号命名
BASE_URL="https://github.com/${REPO}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS="✓"; WARN="!"; FAIL="✗"
SUMMARY=()
note() { SUMMARY+=("$1"); }

# ---------------------------------------------------------------- 环境预检
preflight() {
  local rc=0
  echo "── ① 环境预检 ──────────────────────────────"

  # macOS 版本
  local ver major
  ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  major="${ver%%.*}"
  if [ "${major:-0}" -ge 13 ]; then
    echo " ${PASS} macOS ${ver}"
    note "OS_OK=1 OS_VERSION=${ver}"
  else
    echo " ${FAIL} macOS ${ver} 过旧，本应用需要 13+"; note "OS_OK=0"; rc=1
  fi

  # 架构
  local arch; arch="$(uname -m)"
  echo " ${PASS} 架构 ${arch}"
  note "ARCH=${arch}"

  # Node.js（运行时依赖；缺失不阻断安装，但给出明确指引）
  if command -v node >/dev/null 2>&1; then
    echo " ${PASS} Node.js $(node -v)"
    note "NODE_OK=1 NODE_VERSION=$(node -v)"
  else
    echo " ${WARN} 未检测到 Node.js —— 应用可安装，但启动后端需要它"
    echo "     安装后端依赖：brew install node   （或访问 https://nodejs.org）"
    note "NODE_OK=0"
  fi

  # 基础工具
  for t in curl unzip ditto; do
    if command -v "$t" >/dev/null 2>&1; then
      echo " ${PASS} 工具 ${t}"
    else
      echo " ${FAIL} 缺少工具 ${t}"; note "TOOL_${t}_OK=0"; rc=1
    fi
  done

  # 目标目录与既有安装
  INSTALL_DEST="/Applications"
  [ -w "/Applications" ] || { INSTALL_DEST="${HOME}/Applications"; mkdir -p "$INSTALL_DEST"; }
  if [ -d "${INSTALL_DEST}/${APP_NAME}" ]; then
    local old; old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "${INSTALL_DEST}/${APP_NAME}/Contents/Info.plist" 2>/dev/null || echo '?')
    echo " ${PASS} 检测到既有安装 v${old}（将升级替换）"
    note "UPGRADE_FROM=${old}"
  fi

  # 端口 3080 现状（仅提示；attach 机制会在运行时处理）
  if lsof -nP -iTCP:3080 -sTCP:LISTEN >/dev/null 2>&1; then
    echo " ${WARN} 端口 3080 已有进程监听——应用将自动接管该实例（attach），无需处理"
    note "PORT3080=occupied"
  else
    echo " ${PASS} 端口 3080 空闲"
    note "PORT3080=free"
  fi

  return $rc
}

# ---------------------------------------------------------------- 安装
do_install() {
  local pre_rc=0
  preflight || pre_rc=$?

  echo "── ② 下载与安装 ────────────────────────────"
  local url="${BASE_URL}/releases/latest/download/${ASSET}"
  echo " → ${url}"
  curl -fSL --progress-bar -o "${TMP}/${ASSET}" "$url"
  unzip -q -o "${TMP}/${ASSET}" -d "$TMP"
  [ -d "${TMP}/${APP_NAME}" ] || {
    echo " ${FAIL} 资产包结构不符合预期，请到 ${BASE_URL}/releases 手动下载"; exit 1; }

  # 运行中的旧实例先温和退出（避免文件替换后新旧混杂）；3 秒不动则提示稍后自行重启生效
  if pgrep -f "${APP_NAME}/Contents/MacOS" >/dev/null 2>&1; then
    echo " → 检测到正在运行的实例，尝试温和退出…"
    osascript -e 'quit app id "'"${BUNDLE_ID}"'"' >/dev/null 2>&1 || true
    sleep 3
    pgrep -f "${APP_NAME}/Contents/MacOS" >/dev/null 2>&1 \
      && echo " ! 实例仍在运行（可能被用户取消退出），本次替换将在其下次重启时生效"
  fi

  rm -rf "${INSTALL_DEST:?}/${APP_NAME}"
  ditto "${TMP}/${APP_NAME}" "${INSTALL_DEST}/${APP_NAME}"
  echo " ${PASS} 已安装到 ${INSTALL_DEST}/${APP_NAME}"

  echo "── ③ 启动与状态回馈 ────────────────────────"
  open "${INSTALL_DEST}/${APP_NAME}"

  # 就绪探测：最多 15 秒，健康即回馈版本信息
  local ready="" i
  for i in $(seq 1 15); do
    sleep 1
    local http
    http=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:3080/" || true)
    [ "$http" = "200" ] && { ready=1; break; }
  done
  if [ -n "$ready" ]; then
    echo " ${PASS} 后端服务就绪（127.0.0.1:3080）"
    note "BACKEND_READY=1"
  else
    echo " ${WARN} 后端暂未就绪（首次需拉取依赖，稍候片刻或查看应用状态面板）"
    note "BACKEND_READY=0"
  fi

  echo "──────────────────────────────"
  echo "安装完成：${INSTALL_DEST}/${APP_NAME}"
  echo
  echo "── 摘要（供 agent 解析）──"
  local s; for s in "${SUMMARY[@]:-}"; do [ -n "$s" ] && echo "$s"; done
  echo "INSTALL_DEST=${INSTALL_DEST}"
  echo "BACKEND_READY=${BACKEND_READY:-${ready:+1}}"
  [ "$pre_rc" -eq 0 ] || { echo "PREFLIGHT_WARN=1（存在告警项，见上文）"; }
}

# ---------------------------------------------------------------- 体检
doctor() {
  local fix=0; [ "${2:-}" = "--fix" ] && fix=1
  echo "── DSH Desktop 体检报告 ────────────────────"

  # 系统
  local ver; ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  echo "[$( [ "${ver%%.*}" -ge 13 ] && echo "$PASS" || echo "$FAIL") ] macOS ${ver}"
  note "OS_VERSION=${ver}"

  # 应用安装
  local app_path=""
  for p in "/Applications/${APP_NAME}" "${HOME}/Applications/${APP_NAME}"; do
    [ -d "$p" ] && { app_path="$p"; break; }
  done
  if [ -n "$app_path" ]; then
    local dv; dv=$(codesign -dv -r- "$app_path" 2>&1 | grep -c 'designated => identifier "com.deepseek-ai.dsh-desktop"' || true)
    echo "[${PASS}] 应用已安装：${app_path}（稳定化签名 DR 命中：$([ "$dv" -gt 0 ] && echo 是 || echo 否)）"
    note "APP_PATH=${app_path}"
  else
    echo "[${FAIL}] 未找到已安装的应用"; note "APP_FOUND=0"
  fi

  # Node
  if command -v node >/dev/null 2>&1; then
    echo "[${PASS}] Node.js $(node -v)"; note "NODE_VERSION=$(node -v)"
  else
    echo "[${FAIL}] 未安装 Node.js —— 后端无法运行。修复建议：brew install node"
    note "NODE_MISSING=1"
  fi

  # 端口与身份
  local pid health="-"
  pid=$(lsof -nP -iTCP:3080 -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $2}')
  if [ -n "$pid" ]; then
    local http; http=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:3080/" || true)
    local marker; marker=$(curl -s -m 2 "http://127.0.0.1:3080/" 2>/dev/null | head -c 65536 | grep -c '__DSH_BOOT__' || true)
    if [ "$http" = "200" ] && [ "${marker:-0}" -ge 1 ]; then
      echo "[${PASS}] 端口 3080：DSH 后端健康（pid ${pid}）"
      note "BACKEND_HEALTHY=1 BACKEND_PID=${pid}"
      # 桥接明细
      local bridge; bridge=$(curl -s -m 2 "http://127.0.0.1:3080/api/desktop/status" 2>/dev/null || true)
      [ -n "$bridge" ] && echo "[${PASS}] 桥接接口：${bridge}"
    else
      echo "[${FAIL}] 端口 3080 被非 DSH 进程占用（pid ${pid}, HTTP ${http}）"
      echo "        修复建议：确认该进程无用后 kill ${pid}，再重启应用"
      note "BACKEND_HEALTHY=0 PORT_SQUATTER_PID=${pid}"
    fi
  else
    echo "[${WARN}] 后端未在运行（应用启动时会自动拉起，或手动打开应用）"
    note "BACKEND_RUNNING=0"
  fi

  # npx 缓存概况
  local cache_n=0
  [ -d "${HOME}/.npm/_npx" ] && cache_n=$(find "${HOME}/.npm/_npx" -maxdepth 4 -type d -name "dsh" -path "*@deepseek-ai*" 2>/dev/null | wc -l | tr -d ' ')
  echo "[${PASS}] npx 缓存中 dsh 副本数：${cache_n}（应用更新时会自动清理旧副本并保护使用中目录）"
  note "NPX_COPIES=${cache_n}"

  # 失效解析缓存检测 + 白名单修复
  if defaults read ${BUNDLE_ID} resolvedServerCommand >/dev/null 2>&1; then
    local cmd; cmd=$(defaults read ${BUNDLE_ID} resolvedServerCommand)
    local first; first=$(echo "$cmd" | awk '{print $1}')
    if [ -x "$first" ]; then
      echo "[${PASS}] 命令解析缓存有效（首 token 可执行）"
    else
      echo "[${WARN}] 命令解析缓存指向不存在的可执行文件：${first}"
      if [ "$fix" -eq 1 ]; then
        defaults delete ${BUNDLE_ID} resolvedServerCommand 2>/dev/null || true
        defaults delete ${BUNDLE_ID} resolvedServerCommandSource 2>/dev/null || true
        echo "        ${PASS} 已清理失效缓存（--fix），下次启动将重新解析"
      else
        echo "        修复方式：重跑本命令并追加 --fix"
      fi
      note "STALE_RESOLVE_CACHE=1"
    fi
  else
    echo "[${PASS}] 无命令解析缓存（首次运行属正常）"
  fi

  echo "──────────────────────────────"
  echo "体检摘要（供 agent 解析）──"
  local s; for s in "${SUMMARY[@]:-}"; do [ -n "$s" ] && echo "$s"; done
  echo "DOCTOR_MODE=read_only$([ "$fix" -eq 1 ] && echo _with_fix)"
  echo "如需针对某项自动修复，把本报告发给你的 agent，或在能力范围内追加 --fix 重跑。"
}

# ---------------------------------------------------------------- 入口
MODE="${1:-install}"
case "$MODE" in
  install) do_install ;;
  doctor)  shift || true; doctor "$@" ;;
  *) echo "用法: install.sh [install|doctor [--fix]]"; exit 1 ;;
esac
