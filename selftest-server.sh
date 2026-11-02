#!/usr/bin/env bash
# Qoder 服务器侧自测 —— 专门覆盖 Python 自测够不到的部分
#
# 用法：selftest-server.sh [账号A] [账号B]
#
# 重点验证：
#   · 账号 env 的 set -a 链路是否真的把变量传给了子进程（这是最容易静默失效的一环）
#   · 多账号是否真的隔离（配置目录 / 锁文件 / 凭据落点）
#   · 锁文件互斥是否生效
#   · "绝不回落全局配置" 的安全防线
#   · systemd 定时窗口是否落在活动窗口内
set -uo pipefail

INSTALL_DIR="${QODER_INSTALL_DIR:-/opt/qoder-signin}"
ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-/opt/qoder-signin/accounts}"
CONF_DIR="${QODER_ACCOUNT_ENV_DIR:-/etc/qoder-signin/accounts}"
PYTHON_BIN="${QODER_PYTHON:-/usr/bin/python3.12}"
CLI_BIN="${QODER_CLI:-/root/.local/bin/qoderclicn}"
RUN="${INSTALL_DIR}/run.sh"

A1="${1:-acct1}"
A2="${2:-acct2}"

TMP_ACCT="_selftest"
TMP_CFG="/tmp/_qoder_selftest_cfg"
TMP_ENV="${CONF_DIR}/${TMP_ACCT}.env"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s   %s\n' "$1" "${2:-}"; }
head1(){ echo; echo "=============================================================="; echo " $1"; echo "=============================================================="; }

cleanup() {
    rm -f  "$TMP_ENV"
    rm -rf "$TMP_CFG"
    rm -f  "/run/qoder-signin/${TMP_ACCT}.lock"
    rm -f  "/var/log/qoder-signin/${TMP_ACCT}.log"
}
trap cleanup EXIT

head1 "1. 基础环境"

if [ -x "$PYTHON_BIN" ]; then ok "解释器可执行：$PYTHON_BIN"; else no "解释器不可执行" "$PYTHON_BIN"; fi

if [ -x "$CLI_BIN" ]; then
    ok "CLI 可执行：$CLI_BIN"
else
    no "CLI 不存在" "$CLI_BIN（请先 curl -fsSL https://qoder.cn/install | bash）"
fi

if [ -f "${INSTALL_DIR}/qoder_claim.py" ]; then
    if "$PYTHON_BIN" -m py_compile "${INSTALL_DIR}/qoder_claim.py" 2>/dev/null; then
        ok "qoder_claim.py 语法编译通过"
    else
        no "qoder_claim.py 编译失败" "$( "$PYTHON_BIN" -m py_compile "${INSTALL_DIR}/qoder_claim.py" 2>&1 | tail -2 )"
    fi
else
    no "找不到主脚本" "${INSTALL_DIR}/qoder_claim.py"
fi

if [ -x "$RUN" ]; then ok "run.sh 可执行"; else no "run.sh 不可执行" "$RUN"; fi

head1 "2. 账号配置与权限"

if [ -f "${CONF_DIR}/${A1}.env" ]; then
    PERM="$(stat -c%a "${CONF_DIR}/${A1}.env")"
    if [ "$PERM" = "600" ]; then ok "${A1}.env 权限 600"; else no "${A1}.env 权限应为 600" "实际 $PERM"; fi
else
    no "找不到账号配置" "${CONF_DIR}/${A1}.env"
fi

CFG1="$(set -a; . "${CONF_DIR}/${A1}.env" 2>/dev/null; set +a; echo "${QODER_CONFIG_DIR:-}")"
[ -n "$CFG1" ] || CFG1="${ACCOUNTS_ROOT}/${A1}"
if [ -d "$CFG1" ]; then
    PERM="$(stat -c%a "$CFG1")"
    if [ "$PERM" = "700" ]; then ok "${A1} 配置目录权限 700"; else no "配置目录权限应为 700" "实际 $PERM ($CFG1)"; fi
else
    no "配置目录不存在" "$CFG1"
fi

head1 "3. 安全防线（绝不回落全局配置）"

if [ "$CFG1" != "/root/.qoder-cn" ] && [ "$CFG1" != "$ACCOUNTS_ROOT" ]; then
    ok "${A1} 配置目录指向账号私有目录：$CFG1"
else
    no "${A1} 配置目录指向了非账号目录" "$CFG1"
fi

check_guard() {
    local acct="$1" cfg="$2"
    if [ "$cfg" != "/root/.qoder-cn" ]; then
        ok "${acct} 不会回落全局 /root/.qoder-cn"
    else
        no "${acct} 回落到了全局配置" "$cfg"
    fi
}
check_guard "$A1" "$CFG1"

if [ -f "${CONF_DIR}/${A2}.env" ]; then
    CFG2="$(set -a; . "${CONF_DIR}/${A2}.env" 2>/dev/null; set +a; echo "${QODER_CONFIG_DIR:-}")"
    [ -n "$CFG2" ] || CFG2="${ACCOUNTS_ROOT}/${A2}"
    check_guard "$A2" "$CFG2"

    head1 "4. 多账号隔离"
    if [ "$CFG1" != "$CFG2" ]; then
        ok "两账号配置目录不同（${A1}=$CFG1 / ${A2}=$CFG2）"
    else
        no "两账号配置目录相同，凭据会互相覆盖" "$CFG1"
    fi

    if [ -f "${CFG1}/.auth/user" ] && [ -f "${CFG2}/.auth/user" ]; then
        M1="$(md5sum "${CFG1}/.auth/user" | cut -d' ' -f1)"
        M2="$(md5sum "${CFG2}/.auth/user" | cut -d' ' -f1)"
        if [ "$M1" != "$M2" ]; then
            ok "两账号凭据文件内容不同（不是同一份）"
        else
            no "两账号凭据文件完全相同" "可能登录成了同一个账号"
        fi
    else
        ok "凭据文件检查跳过（有一个账号还没登录）"
    fi

    L1="/run/qoder-signin/${A1}.lock"
    L2="/run/qoder-signin/${A2}.lock"
    if [ "$L1" != "$L2" ]; then ok "两账号锁文件不同"; else no "两账号锁文件相同，会互相阻塞" "$L1"; fi
else
    ok "只配了一个账号（${A2} 不存在），跳过隔离检查"
fi

head1 "5. set -a 链路（账号 env 是否真的传给了子进程）"

mkdir -p "$TMP_CFG"
chmod 700 "$TMP_CFG"
cat > "$TMP_ENV" <<EOF
QODER_CONFIG_DIR="${TMP_CFG}"
QODER_MITM_PORT="19999"
QODER_SELFTEST_MARKER="marker-abc-123"
EOF
chmod 600 "$TMP_ENV"

OUT="$("$RUN" "$TMP_ACCT" --inspect 2>&1 || true)"

if printf '%s' "$OUT" | grep -q 'marker-abc-123'; then
    ok "账号 env 里的自定义变量已传到子进程（set -a 生效）"
else
    no "账号 env 变量没传进来" "缺 set -a 时会静默丢失"
fi

if printf '%s' "$OUT" | grep -q 'QODER_MITM_PORT=19999'; then
    ok "QODER_MITM_PORT 覆盖生效（19999）"
else
    no "QODER_MITM_PORT 覆盖未生效" "应为 19999"
fi

if printf '%s' "$OUT" | grep -q "配置目录 *: *${TMP_CFG}"; then
    ok "临时账号的配置目录解析正确"
else
    no "临时账号配置目录解析错误" "期望 $TMP_CFG"
fi

# 反向验证：变量不存在时不应出现
if printf '%s' "$OUT" | grep -q 'QODER_NOT_DEFINED_XYZ'; then
    no "反向验证失败：未定义的变量竟然出现了"
else
    ok "反向验证：未定义的变量确实不出现"
fi

head1 "6. 锁文件互斥"

LOCK_T="/run/qoder-signin/${TMP_ACCT}.lock"
mkdir -p /run/qoder-signin
flock -x "$LOCK_T" -c 'sleep 6' &
HOLDER=$!
sleep 1
LOUT="$("$RUN" "$TMP_ACCT" --dry-run 2>&1 || true)"
if printf '%s' "$LOUT" | grep -q 'SKIP'; then
    ok "锁被占用时第二次调用被跳过（不会并发跑）"
else
    no "锁没起作用" "第二次调用没有被跳过"
fi
wait "$HOLDER" 2>/dev/null || true

head1 "7. 定时器窗口"

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^qoder-claim@\.timer'; then
    # 用 LoadState 判断实例单元是否存在（list-unit-files 对模板实例不一定列出）
    LOAD="$(systemctl show -p LoadState "qoder-claim@${A1}.timer" 2>/dev/null | cut -d= -f2-)"
    if [ "$LOAD" = "loaded" ]; then
        ok "qoder-claim@${A1}.timer 已安装（LoadState=loaded）"
    else
        no "qoder-claim@${A1}.timer 不存在或未加载" "LoadState=${LOAD:-空}，请重跑 install.sh"
    fi

    CAL="$(systemctl show -p TimersCalendar "qoder-claim@${A1}.timer" 2>/dev/null | cut -d= -f2-)"
    HH="$(printf '%s' "$CAL" | grep -o -E '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 | cut -d: -f1)"
    if [ -n "$HH" ] && [ "$HH" -ge 10 ] 2>/dev/null; then
        ok "${A1} 窗口起点在 10:00 之后（$CAL）"
    elif [ -n "$HH" ]; then
        no "${A1} 窗口起点早于 10:00" "活动 10:00 才刷新，$CAL"
    else
        no "读不到 ${A1} 的 OnCalendar" "$CAL"
    fi

    # systemd 的 OnCalendar 在 drop-in 里是累加：模板默认值 + drop-in 值会同时生效，
    # 结果是定时器一天触发两次。drop-in 里必须先用空的 OnCalendar= 清空。
    NCAL="$(systemctl show -p TimersCalendar "qoder-claim@${A1}.timer" 2>/dev/null \
            | grep -o -c 'TimersCalendar=' || true)"
    if [ "${NCAL:-0}" -le 1 ]; then
        ok "${A1} 只有一个 OnCalendar（drop-in 正确清空了模板默认值）"
    else
        no "${A1} 挂着 ${NCAL} 个 OnCalendar 时间点" "定时器会一天触发多次，drop-in 里要先写一行空的 OnCalendar="
    fi

    RND="$(systemctl show -p RandomizedDelayUSec "qoder-claim@${A1}.timer" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$RND" ] && [ "$RND" != "0" ] && [ "$RND" != "0us" ]; then
        ok "${A1} 启用了随机抖动（$RND）"
    else
        no "${A1} 没有随机抖动" "固定钟点容易被识别"
    fi

    if grep -q '^ExecStart.*sleep' "${INSTALL_DIR}/qoder-claim@*.service" 2>/dev/null \
       || grep -q 'sleep' "${INSTALL_DIR}/systemd/qoder-claim@.service" 2>/dev/null; then
        no "服务单元里出现 sleep" "会占用 TimeoutStartSec 导致被 SIGTERM"
    else
        ok "服务单元内没有 sleep"
    fi
else
    ok "未安装 systemd 定时器，跳过窗口检查（cron 模式）"
fi

head1 "8. 令牌缓存"

if [ -f "${CFG1}/.dt-token" ]; then
    PERM="$(stat -c%a "${CFG1}/.dt-token")"
    LEN="$(wc -c < "${CFG1}/.dt-token" | tr -d ' ')"
    if [ "$PERM" = "600" ]; then ok "令牌缓存权限 600"; else no "令牌缓存权限应为 600" "实际 $PERM"; fi
    if [ "$LEN" = "27" ]; then ok "令牌长度 27（形如 dt- + 24）"; else no "令牌长度异常" "实际 $LEN"; fi
else
    ok "尚无令牌缓存（首次运行后会生成）"
fi

echo
echo "=============================================================="
echo " 结果：${PASS} 通过 / ${FAIL} 失败"
if [ "$FAIL" -gt 0 ]; then
    echo " ⚠ 有失败项，请按上面的提示处理"
    echo "=============================================================="
    exit 1
fi
echo " 全部通过 ✅"
echo "=============================================================="
exit 0
