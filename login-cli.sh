#!/usr/bin/env bash
# Qoder 账号登录 —— 服务器无图形界面下生成授权链接
#
# 用法：
#   login-cli.sh <账号名>                     # 默认轮数 6，每轮 ~5 分钟
#   login-cli.sh <账号名> <轮数>              # 自定义轮数
#   login-cli.sh <账号名> <轮数> <每轮秒数>   # 自定义每轮等待秒数
#
# 原理：qoderclicn login 在无 GUI 环境下走「服务端轮询」模式，
#       会直接打印一条可在任意浏览器打开的授权链接；你在浏览器里选账号并确认后，
#       服务器这边的 CLI 会自己拿到凭据。
#
# 🔴 关键限制：服务端下发的 device flow **5 分钟就过期**，CLI 无参数可调。
#    所以本脚本做成「自动换链」：一轮超时后立刻重新发起一条新链接。
#    每一轮的链接会写到 var/log/qoder-signin/<账号>.login.url（覆盖写），
#    随时可以 `cat` 它拿到**当前有效**的那条。
#
# ⚠️ 必须用**独立的 tmux socket**（-L qoder-login-<账号名>）承载登录会话。
#    若复用默认 socket，清理别的会话时误杀会导致授权回调静默失败
#    （现象：明明点过授权了，status 仍显示 Not logged in）。
set -euo pipefail

CLI_BIN="${QODER_CLI:-/root/.local/bin/qoderclicn}"
ACCOUNT="${1:-}"
ROUNDS="${2:-6}"
ROUND_WAIT="${3:-290}"

if [ -z "$ACCOUNT" ]; then
    echo "用法: $0 <账号名> [轮数，默认 6] [每轮秒数，默认 290]" >&2
    exit 64
fi

ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-/opt/qoder-signin/accounts}"
ACCOUNT_ENV="${QODER_ACCOUNT_ENV:-/etc/qoder-signin/accounts/${ACCOUNT}.env}"

if [ -f "$ACCOUNT_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ACCOUNT_ENV"
    set +a
fi

CFG="${QODER_CONFIG_DIR:-${ACCOUNTS_ROOT}/${ACCOUNT}}"
SESSION="qoder-login-${ACCOUNT}"
LOG_DIR="/var/log/qoder-signin"
LOG="${LOG_DIR}/${ACCOUNT}.login.log"
URL_FILE="${LOG_DIR}/${ACCOUNT}.login.url"

mkdir -p "$CFG" "$LOG_DIR"
chmod 700 "$CFG" 2>/dev/null || true

if [ ! -x "$CLI_BIN" ]; then
    echo "[FATAL] 找不到 CLI：$CLI_BIN" >&2
    echo "        请先执行：curl -fsSL https://qoder.cn/install | bash" >&2
    exit 69
fi

echo "=============================================================="
echo " Qoder 账号登录：$ACCOUNT"
echo " 配置目录：$CFG"
echo " 轮数：$ROUNDS  每轮等待：${ROUND_WAIT}s（服务端链接 5 分钟过期，超时自动换链）"
echo "=============================================================="

# 已登录就不折腾了
STATUS_NOW="$(QODERCN_CONFIG_DIR="$CFG" "$CLI_BIN" status 2>&1 || true)"
if printf '%s' "$STATUS_NOW" | grep -q 'Username:'; then
    echo "[INFO] 该账号已登录，无需重新授权："
    printf '%s\n' "$STATUS_NOW" | head -6
    exit 0
fi

: > "$LOG"
: > "$URL_FILE"

for round in $(seq 1 "$ROUNDS"); do
    echo
    echo "---------------- 第 ${round}/${ROUNDS} 轮 ----------------"

    # 清掉上一轮的会话（只清自己这个 socket，不碰别人的）
    tmux -L "$SESSION" kill-server 2>/dev/null || true
    sleep 1
    : > "$LOG"

    tmux -L "$SESSION" new-session -d -s "$SESSION" -x 220 -y 50 \
        "QODERCN_CONFIG_DIR='$CFG' '$CLI_BIN' login 2>&1 | tee -a '$LOG'"

    # 抓授权链接
    URL=""
    for _ in $(seq 1 20); do
        sleep 2
        URL="$(grep -a -o -E 'https://[a-zA-Z0-9./?=&_%:-]*(device|login|auth)[a-zA-Z0-9./?=&_%:-]*' "$LOG" 2>/dev/null | tail -1 || true)"
        [ -n "$URL" ] && break
    done

    if [ -z "$URL" ]; then
        echo "[WARN] 本轮没抓到授权链接。原始输出：" >&2
        tail -20 "$LOG" >&2 || true
        continue
    fi

    printf '%s\n' "$URL" > "$URL_FILE"

    cat <<EOF
请在浏览器打开下面的链接完成授权（用哪个账号登录，就登录哪个账号）：

$URL

⏱️ 这条链接 **5 分钟内**必须点完（服务端硬限制）。过期了本脚本会自动出下一条。
EOF

    if [ "$round" -eq 1 ]; then
        cat <<'EOF'

⚠️ 如果本次是登录**第二个及以后的账号**，请务必：
  1. 用无痕 / 隐私窗口打开；
  2. 或先退出当前已登录的 Qoder 网页会话。
   否则浏览器会复用旧会话，导致"两个账号其实是同一个人"。
EOF
    fi
    echo

    # 等结果：成功 / 本轮超时
    #
    # 判据用「凭据文件出现」而不是每几秒调一次 `status`：
    # 后者每轮会起上百个子进程、并把 logs/runs 堆满垃圾目录，代价远高于收益。
    # 凭据落盘（.auth/user，acct1 实测 1304 字节）是成功的充分信号，再用 status 复核一次即可。
    AUTH_USER="${CFG}/.auth/user"
    DEADLINE=$(( $(date +%s) + ROUND_WAIT ))
    OK=0
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        sleep 3
        if [ -s "$AUTH_USER" ] && [ "$(stat -c%s "$AUTH_USER" 2>/dev/null || echo 0)" -gt 100 ]; then
            STATUS="$(QODERCN_CONFIG_DIR="$CFG" "$CLI_BIN" status 2>&1 || true)"
            if printf '%s' "$STATUS" | grep -q 'Username:'; then
                OK=1
                printf '%s\n' "$STATUS" | head -6
                break
            fi
        fi
        # CLI 自己报超时 → 提前结束本轮，立刻换链（不必空等）
        if grep -qa 'Device flow timed out\|Login failed\|login cancelled' "$LOG" 2>/dev/null; then
            echo "[INFO] 本轮链接已过期，正在生成新链接…"
            break
        fi
    done

    if [ "$OK" -eq 1 ]; then
        tmux -L "$SESSION" kill-server 2>/dev/null || true
        rm -f "$URL_FILE"
        echo
        echo "[OK] 登录成功（第 ${round} 轮）"
        echo
        echo "下一步（可选）：核对账号身份，避免两个账号其实是同一个人"
        echo "  audit-accounts.sh"
        exit 0
    fi
done

tmux -L "$SESSION" kill-server 2>/dev/null || true

echo >&2
echo "[FAIL] ${ROUNDS} 轮共约 $(( ROUNDS * ROUND_WAIT / 60 )) 分钟仍未检测到登录成功。" >&2
echo "       可重跑本脚本继续换链，或查看日志：$LOG" >&2
echo "       当前链接（可能已过期）：$(cat "$URL_FILE" 2>/dev/null || echo '(无)')" >&2
exit 1
