#!/usr/bin/env bash
# Qoder 每日领取 —— 多账号入口
#
# 用法：
#   run.sh <账号名>              正常领取
#   run.sh <账号名> --dry-run    只查活动，不提交领取
#   run.sh <账号名> --inspect    打印本次解析出的每账号参数后退出
#
# 每个账号一套独立资源，互不干扰：
#   配置目录   $QODER_CONFIG_DIR   （默认 <账号根>/<账号名>，连 .auth 一起隔离）
#   锁文件     /run/qoder-signin/<账号名>.lock   （不分开会互相阻塞）
#   日志       /var/log/qoder-signin/<账号名>.log
#   令牌缓存   $QODER_CONFIG_DIR/.dt-token       （600）
#   tmux 会话  qoder-claim-<账号名>              （独立 socket，避免误杀别的账号）
set -euo pipefail

# ---------- 固定解释器 ----------
# 服务器 PATH 首位常是业务 venv，venv 重建会让 systemd 单元失效；
# 所以这里写死系统解释器，可用环境变量覆盖。
PYTHON_BIN="${QODER_PYTHON:-/usr/bin/python3.12}"

ACCOUNT="${1:-}"
MODE="${2:-}"
if [ -z "$ACCOUNT" ]; then
    echo "用法: $0 <账号名> [--dry-run|--inspect]" >&2
    exit 64
fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-/opt/qoder-signin/accounts}"
ACCOUNT_ENV="${QODER_ACCOUNT_ENV:-/etc/qoder-signin/accounts/${ACCOUNT}.env}"

# ---------- 加载账号配置 ----------
# 必须 set -a：否则文件里定义的变量不会传给 exec 出去的子进程，
# 现象是"配置文件里明明有值，脚本里却读不到"。
if [ -f "$ACCOUNT_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ACCOUNT_ENV"
    set +a
else
    echo "[WARN] 账号配置不存在: $ACCOUNT_ENV（将使用默认值）" >&2
fi

# ---------- 每账号默认值 ----------
export QODER_ACCOUNT="$ACCOUNT"
export QODER_CONFIG_DIR="${QODER_CONFIG_DIR:-${ACCOUNTS_ROOT}/${ACCOUNT}}"
export QODER_LOCK_FILE="${QODER_LOCK_FILE:-/run/qoder-signin/${ACCOUNT}.lock}"
export QODER_SIGNIN_LOG="${QODER_SIGNIN_LOG:-/var/log/qoder-signin/${ACCOUNT}.log}"
export QODER_SESSION="${QODER_SESSION:-qoder-claim-${ACCOUNT}}"
export QODER_RUNDIR="${QODER_RUNDIR:-/run/qoder-signin}"

if [ "$MODE" = "--dry-run" ]; then
    export QODER_DRY_RUN=1
fi

# ---------- 安全防线 ----------
# 设了 QODER_ACCOUNT 就绝不允许配置目录落到别处（防止两个账号写同一份 .auth）
if [ "$QODER_CONFIG_DIR" = "/root/.qoder-cn" ] || [ "$QODER_CONFIG_DIR" = "${ACCOUNTS_ROOT}" ]; then
    echo "[FATAL] QODER_CONFIG_DIR 指向了非账号目录：$QODER_CONFIG_DIR" >&2
    exit 78
fi

if [ "$MODE" = "--inspect" ]; then
    echo "账号            : $ACCOUNT"
    echo "账号配置        : $ACCOUNT_ENV"
    echo "配置目录        : $QODER_CONFIG_DIR"
    echo "锁文件          : $QODER_LOCK_FILE"
    echo "日志            : $QODER_SIGNIN_LOG"
    echo "tmux 会话       : $QODER_SESSION"
    echo "clientType      : ${QODER_CLIENT_TYPE:-10}"
    echo "解释器          : $PYTHON_BIN"
    echo "脚本            : $SELF_DIR/qoder_claim.py"
    echo "--- 本进程可见的全部 QODER_* 环境变量（用于验证账号 env 是否真的传进来了）---"
    env | grep '^QODER_' | sort | sed 's/^/  /'
    exit 0
fi

# ---------- 初始化目录与权限 ----------
mkdir -p "$QODER_CONFIG_DIR" "$(dirname "$QODER_SIGNIN_LOG")" "$(dirname "$QODER_LOCK_FILE")" \
         "$QODER_RUNDIR"
chmod 700 "$QODER_CONFIG_DIR" 2>/dev/null || true

if [ ! -x "$PYTHON_BIN" ]; then
    echo "[FATAL] 解释器不存在或不可执行：$PYTHON_BIN" >&2
    exit 69
fi
if [ ! -x "$SELF_DIR/qoder_claim.py" ] && [ ! -r "$SELF_DIR/qoder_claim.py" ]; then
    echo "[FATAL] 找不到主脚本：$SELF_DIR/qoder_claim.py" >&2
    exit 69
fi

# ---------- 日志轮转（超过 5MB 截断保留尾部） ----------
if [ -f "$QODER_SIGNIN_LOG" ] && [ "$(stat -c%s "$QODER_SIGNIN_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tail -c 1048576 "$QODER_SIGNIN_LOG" > "${QODER_SIGNIN_LOG}.tmp" 2>/dev/null || true
    mv -f "${QODER_SIGNIN_LOG}.tmp" "$QODER_SIGNIN_LOG" 2>/dev/null || true
fi

# ---------- 互斥锁（每账号一把，不阻塞：拿不到就退出） ----------
exec 9>"$QODER_LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] [SKIP] 另一个 $ACCOUNT 实例正在运行，本次跳过"
    exit 0
fi

# ---------- 随机抖动 ----------
# 注意：随机性要放在 systemd 那一层（RandomizedDelaySec），不要在这里 sleep。
# 这里只服务于 cron 降级路径；systemd 下若窗口过大自动压缩，避免撞 TimeoutStartSec。
if [ "${QODER_JITTER_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    JITTER="$QODER_JITTER_SECONDS"
    if [ -n "${INVOCATION_ID:-}" ] && [ "$JITTER" -gt 600 ]; then
        echo "[WARN] 检测到 systemd 环境，抖动 $JITTER 秒过大，压缩为 600 秒" >&2
        JITTER=600
    fi
    DELAY=$(( RANDOM % JITTER ))
    echo "[$(date '+%F %T')] [INFO] 抖动等待 ${DELAY}s（窗口 ${JITTER}s）"
    sleep "$DELAY"
fi

# ---------- 执行 ----------
exec "$PYTHON_BIN" "$SELF_DIR/qoder_claim.py"
