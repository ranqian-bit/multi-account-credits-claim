#!/usr/bin/env bash
# Qoder 领取前置检查 —— 只做诊断与提示，永远不阻塞主流程
#
# 由 systemd 以 `ExecStartPre=-/opt/qoder-signin/precheck.sh %i` 调用，
# 前面的 "-" 表示本脚本失败也不影响主服务启动。
#
# 关注点：
#   · 账号配置 / 配置目录是否齐全
#   · CLI 是否还在登录态（凭据过期或被登出时给出明确告警）
#   · 磁盘与内存余量（这台机器内存小，CLI 单进程就要 200MB+）
set -uo pipefail

ACCOUNT="${1:-}"
if [ -z "$ACCOUNT" ]; then
    echo "[precheck] 缺少账号名参数，跳过"
    exit 0
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_BIN="${QODER_CLI:-/root/.local/bin/qoderclicn}"
ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-/opt/qoder-signin/accounts}"
ACCOUNT_ENV="${QODER_ACCOUNT_ENV:-/etc/qoder-signin/accounts/${ACCOUNT}.env}"

if [ -f "$ACCOUNT_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ACCOUNT_ENV"
    set +a
fi
CFG="${QODER_CONFIG_DIR:-${ACCOUNTS_ROOT}/${ACCOUNT}}"

tag="[precheck ${ACCOUNT}]"

if [ ! -d "$CFG" ]; then
    echo "$tag 配置目录不存在：$CFG → 请执行 $SELF_DIR/install.sh 或 login-cli.sh $ACCOUNT"
    exit 0
fi

if [ ! -f "${CFG}/.auth/user" ]; then
    echo "$tag 未发现凭据文件 ${CFG}/.auth/user → 该账号可能从未登录，请执行 $SELF_DIR/login-cli.sh $ACCOUNT"
    exit 0
fi

if [ -x "$CLI_BIN" ]; then
    ST="$(QODERCN_CONFIG_DIR="$CFG" "$CLI_BIN" status 2>&1 || true)"
    if printf '%s' "$ST" | grep -q 'Username:'; then
        echo "$tag 登录态正常：$(printf '%s' "$ST" | awk -F': ' '/^Username:/{print $2; exit}')"
    else
        echo "$tag ⚠ 未检测到登录态（凭据可能已过期或被登出）→ 请执行 $SELF_DIR/login-cli.sh $ACCOUNT"
    fi
else
    echo "$tag ⚠ 找不到 CLI：$CLI_BIN"
fi

mem_mb="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${mem_mb:-0}" -lt 400 ] 2>/dev/null; then
    echo "$tag ⚠ 可用内存仅 ${mem_mb}MB，CLI 可能需要 200MB+，存在被杀风险"
fi

exit 0
