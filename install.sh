#!/usr/bin/env bash
# Qoder 每日 100 Credits 自动领取 —— 一键部署
#
# 用法（在解压后的项目目录里以 root 执行）：
#   ./install.sh                          装到默认位置，账号取 accounts.conf（默认 acct1 acct2）
#   ./install.sh --accounts acct1,acct2   指定账号
#   ./install.sh --with-proxy             额外部署 mitmproxy（令牌获取 L3 兜底）
#   ./install.sh --skip-cli               不检查/安装官方 CLI
#   ./install.sh --no-systemd             只铺文件，不装定时器
#   ./install.sh --uninstall              卸载（保留账号数据）
#   ./install.sh --uninstall --purge      卸载并删除账号数据
set -euo pipefail

INSTALL_DIR="${QODER_INSTALL_DIR:-/opt/qoder-signin}"
ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-${INSTALL_DIR}/accounts}"
CONF_DIR="${QODER_ACCOUNT_ENV_DIR:-/etc/qoder-signin/accounts}"
LOG_DIR="${QODER_LOG_DIR:-/var/log/qoder-signin}"
RUN_DIR="${QODER_RUNDIR:-/run/qoder-signin}"
UNIT_DIR="/etc/systemd/system"
CLI_BIN="/root/.local/bin/qoderclicn"

WINDOW_BASE_HOUR=10
WINDOW_BASE_MIN=20
WINDOW_SECONDS=14400          # 每账号窗口 4 小时
RANDOMIZED_DELAY=14400        # 提交给 systemd 的抖动（= 窗口大小）

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

DO_CLI=1
DO_SYSTEMD=1
DO_PROXY=0
UNINSTALL=0
PURGE=0
ACCOUNTS_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --accounts)   ACCOUNTS_ARG="${2:-}"; shift 2 ;;
        --accounts=*) ACCOUNTS_ARG="${1#*=}"; shift ;;
        --skip-cli)   DO_CLI=0; shift ;;
        --no-systemd) DO_SYSTEMD=0; shift ;;
        --with-proxy) DO_PROXY=1; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --purge)      PURGE=1; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 64 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "[FATAL] 请用 root 执行（本脚本要写 /etc、/opt、/var/log 并管理 systemd）" >&2
    exit 77
fi

# ---------- 账号列表 ----------
resolve_accounts() {
    local out=""
    if [ -n "$ACCOUNTS_ARG" ]; then
        out="$(printf '%s' "$ACCOUNTS_ARG" | tr ',' ' ')"
    elif [ -f "${SELF_DIR}/accounts.conf" ]; then
        out="$(grep -v '^[[:space:]]*#' "${SELF_DIR}/accounts.conf" 2>/dev/null \
               | grep -v '^[[:space:]]*$' | awk '{print $1}' | tr '\n' ' ')"
    fi
    [ -n "${out// /}" ] || out="acct1 acct2"
    printf '%s\n' $out
}

mapfile -t ACCOUNTS < <(resolve_accounts)

# ---------- 卸载 ----------
if [ "$UNINSTALL" -eq 1 ]; then
    echo "== 卸载 =="
    for a in "${ACCOUNTS[@]}"; do
        systemctl disable --now "qoder-claim@${a}.timer" 2>/dev/null || true
        rm -rf "${UNIT_DIR}/qoder-claim@${a}.timer.d"
    done
    rm -f "${UNIT_DIR}/qoder-claim@.service" "${UNIT_DIR}/qoder-claim@.timer"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$RUN_DIR"
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"
        echo "已删除账号数据（--purge）"
    else
        rm -f "${INSTALL_DIR}"/*.py "${INSTALL_DIR}"/*.sh
        echo "已卸载程序（账号数据保留在 $ACCOUNTS_ROOT 与 $CONF_DIR）"
    fi
    echo "完成。"
    exit 0
fi

echo "=============================================================="
echo " Qoder 自动领取 —— 部署"
echo "   程序目录 : $INSTALL_DIR"
echo "   账号目录 : $ACCOUNTS_ROOT"
echo "   账号配置 : $CONF_DIR"
echo "   日志目录 : $LOG_DIR"
echo "   账号     : ${ACCOUNTS[*]}"
echo "=============================================================="
echo

# ---------- 0. 官方 CLI ----------
echo "== 0. 检查官方 CLI =="
if [ "$DO_CLI" -eq 1 ]; then
    if [ -x "$CLI_BIN" ]; then
        echo "  已存在：$CLI_BIN"
        "$CLI_BIN" --version 2>/dev/null | head -1 | sed 's/^/  版本: /' || true
    else
        echo "  未安装，正在执行官方安装脚本（中国版）…"
        if curl -fsSL https://qoder.cn/install | bash; then
            echo "  安装完成：$CLI_BIN"
        else
            echo "  [WARN] 自动安装失败，请手动执行：curl -fsSL https://qoder.cn/install | bash" >&2
        fi
    fi
else
    echo "  已跳过（--skip-cli）"
fi
echo

# ---------- 1. 目录与权限 ----------
echo "== 1. 创建目录 =="
mkdir -p "$INSTALL_DIR" "$ACCOUNTS_ROOT" "$CONF_DIR" "$LOG_DIR" "$RUN_DIR"
chmod 700 "$ACCOUNTS_ROOT" "$CONF_DIR"
chmod 750 "$LOG_DIR" "$RUN_DIR"
echo "  ok"

# ---------- 2. 铺程序文件 ----------
echo "== 2. 安装程序文件 =="
# 注意：如果项目目录本身就是安装目录，cp 源=目标会报 "are the same file"
# 并被 set -e 中断，所以这里显式判断同文件情形。
install_file() {
    local src="$1" dst="$2" mode="${3:-0755}"
    if [ ! -f "$src" ]; then
        echo "  ! 源文件不存在：$src" >&2
        return 0
    fi
    if [ -e "$dst" ] && [ "$(readlink -f "$src")" = "$(readlink -f "$dst")" ]; then
        chmod "$mode" "$dst"
        echo "  = $dst（源即目标，仅校正权限）"
        return 0
    fi
    install -m "$mode" "$src" "$dst"
    echo "  + $dst"
}

for f in qoder_claim.py run.sh login-cli.sh audit-accounts.sh precheck.sh selftest-server.sh; do
    install_file "${SELF_DIR}/${f}" "${INSTALL_DIR}/${f}" 0755
done
install_file "${SELF_DIR}/selftest.py" "${INSTALL_DIR}/selftest.py" 0755
install_file "${SELF_DIR}/accounts.conf" "${INSTALL_DIR}/accounts.conf" 0644
for f in README.md 协议合规核查.md 部署记录.md; do
    install_file "${SELF_DIR}/${f}" "${INSTALL_DIR}/${f}" 0644
done

# ---------- 3. 每账号配置 ----------
echo "== 3. 生成账号配置 =="
IDX=0
declare -A WINDOW_OF
declare -A WINDOW_END_OF
for a in "${ACCOUNTS[@]}"; do
    ENVF="${CONF_DIR}/${a}.env"
    CFGD="${ACCOUNTS_ROOT}/${a}"
    mkdir -p "$CFGD"
    chmod 700 "$CFGD"

    if [ -f "$ENVF" ]; then
        echo "  = $ENVF（已存在，不覆盖）"
    else
        cat > "$ENVF" <<EOF
# Qoder 每日领取 —— 账号 $a 的独立配置
# 权限必须是 600：这里决定了该账号用哪份凭据
QODER_CONFIG_DIR="${CFGD}"
# 渠道伪装：10 = 中国版桌面端（服务端只对桌面端下发活动）
QODER_CLIENT_TYPE="10"
# 令牌获取 L3（mitmproxy 抓包兜底）开关，1 开 0 关
QODER_ENABLE_PROXY_FALLBACK="1"
# 仅 cron 降级路径使用；systemd 下请用 timer 的 RandomizedDelaySec
QODER_JITTER_SECONDS="0"
EOF
        chmod 600 "$ENVF"
        echo "  + $ENVF"
    fi

    # 窗口顺延：第 i 个账号 = 10:20 + i*4 小时，保证互不重叠
    # ⚠️ 用纯算术算，不能用 `date -d "10:20 +0 hours"` ——
    #    GNU date 会把 "+0" 当成 UTC 偏移，算出 19:20 这种离谱结果。
    TOTAL_MIN=$(( WINDOW_BASE_HOUR * 60 + WINDOW_BASE_MIN + IDX * (WINDOW_SECONDS / 60) ))
    END_MIN=$(( TOTAL_MIN + WINDOW_SECONDS / 60 ))
    HH="$(printf '%02d:%02d' $(( (TOTAL_MIN / 60) % 24 )) $(( TOTAL_MIN % 60 )))"
    HH_END="$(printf '%02d:%02d' $(( (END_MIN / 60) % 24 )) $(( END_MIN % 60 )))"
    WINDOW_OF["$a"]="$HH"
    WINDOW_END_OF["$a"]="$HH_END"
    IDX=$((IDX + 1))
done

# ---------- 4. systemd ----------
echo "== 4. 安装 systemd 定时器 =="
if [ "$DO_SYSTEMD" -eq 0 ]; then
    echo "  已跳过（--no-systemd）"
else
    install -m 0644 "${SELF_DIR}/systemd/qoder-claim@.service" "${UNIT_DIR}/qoder-claim@.service"
    install -m 0644 "${SELF_DIR}/systemd/qoder-claim@.timer"   "${UNIT_DIR}/qoder-claim@.timer"
    echo "  + ${UNIT_DIR}/qoder-claim@.service"
    echo "  + ${UNIT_DIR}/qoder-claim@.timer"

    for a in "${ACCOUNTS[@]}"; do
        DROP="${UNIT_DIR}/qoder-claim@${a}.timer.d"
        mkdir -p "$DROP"
        cat > "${DROP}/window.conf" <<EOF
# 账号 $a 的随机窗口：起点 ${WINDOW_OF[$a]}，窗口 $((RANDOMIZED_DELAY / 3600)) 小时
# 多个账号的窗口互不重叠，避免同一时刻集中请求
[Timer]
# ⚠️ 必须先用空的 OnCalendar= 清空模板里的默认值：
#    systemd 的列表型设置是**累加**而非覆盖，不清空会让定时器一天触发两次
#    （实测 systemctl show -p TimersCalendar 会同时挂上两个时间点）。
OnCalendar=
OnCalendar=*-*-* ${WINDOW_OF[$a]}:00
RandomizedDelaySec=${RANDOMIZED_DELAY}
AccuracySec=1s
Persistent=true
EOF
        echo "  + ${DROP}/window.conf   窗口 [${WINDOW_OF[$a]}, ${WINDOW_END_OF[$a]})"
    done

    systemctl daemon-reload
    mkdir -p /var/lib/systemd/timers
    for a in "${ACCOUNTS[@]}"; do
        systemctl enable "qoder-claim@${a}.timer" >/dev/null 2>&1 \
            && echo "  ✓ 已启用 qoder-claim@${a}.timer" \
            || echo "  ! 启用 qoder-claim@${a}.timer 失败，请检查 systemctl status"

        # Persistent=true 会把"安装前已错过的当天时间点"当成漏跑并立刻补跑。
        # 刚装完不该立刻触发（尤其第二个账号可能还没登录），所以先把时间戳打到当前时刻。
        STAMP="/var/lib/systemd/timers/stamp-qoder-claim@${a}.timer"
        if [ ! -f "$STAMP" ]; then
            touch "$STAMP"
        fi
        systemctl restart "qoder-claim@${a}.timer" >/dev/null 2>&1 || true
    done

    echo
    echo "  下次触发时间："
    systemctl list-timers 'qoder-claim@*' --no-pager 2>/dev/null | sed 's/^/    /' || true
fi

# ---------- 5. mitmproxy（可选） ----------
echo "== 5. mitmproxy（令牌 L3 兜底，可选） =="
if [ "$DO_PROXY" -eq 1 ]; then
    if [ -x /root/mitmenv/bin/mitmdump ]; then
        echo "  已存在：/root/mitmenv/bin/mitmdump"
    else
        echo "  创建虚拟环境并安装 mitmproxy（约 120MB）…"
        /usr/bin/python3.12 -m ensurepip --upgrade >/dev/null 2>&1 || true
        /usr/bin/python3.12 -m venv /root/mitmenv
        /root/mitmenv/bin/pip install -q --upgrade pip
        /root/mitmenv/bin/pip install -q mitmproxy
        echo "  已安装"
    fi
    echo "  生成 CA 并装入系统信任库…"
    /root/mitmenv/bin/mitmdump --set confdir=/root/.mitmproxy -q -w /dev/null &
    MP=$!
    sleep 8
    kill "$MP" 2>/dev/null || true
    if [ -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]; then
        cp -f /root/.mitmproxy/mitmproxy-ca-cert.pem /etc/pki/ca-trust/source/anchors/ 2>/dev/null \
            && update-ca-trust 2>/dev/null \
            && echo "  CA 已装入信任库" \
            || echo "  [WARN] CA 装入失败（L3 仍可用 NODE_EXTRA_CA_CERTS 兜住）"
    fi
else
    echo "  已跳过（如需 L3 兜底请加 --with-proxy）"
    echo "  说明：默认走 L1 缓存 + L2 内存扫描，通常不需要 mitmproxy"
fi

# ---------- 6. 自检 ----------
echo
echo "== 6. 快速自检 =="
if [ -x "${INSTALL_DIR}/run.sh" ]; then
    "${INSTALL_DIR}/run.sh" "${ACCOUNTS[0]}" --inspect 2>&1 | sed 's/^/  /' || true
else
    echo "  ! run.sh 不可执行"
fi

cat <<EOF

==============================================================
 部署完成
==============================================================

下一步：

1) 登录每个账号（每个账号单独执行一次）：
     ${INSTALL_DIR}/login-cli.sh ${ACCOUNTS[0]}
   ⚠️ 第二个及以后的账号，请用**无痕窗口**打开授权链接，
      否则浏览器复用旧会话，两个"账号"其实是同一个人。

2) 体检（会核对两个账号的 uid 是否真的不同）：
     ${INSTALL_DIR}/audit-accounts.sh

3) 立刻试跑一次（只查不领）：
     ${INSTALL_DIR}/run.sh ${ACCOUNTS[0]} --dry-run

4) 真实跑一次：
     ${INSTALL_DIR}/run.sh ${ACCOUNTS[0]}

5) 查看定时器：
     systemctl list-timers 'qoder-claim@*'

日志：${LOG_DIR}/<账号名>.log
EOF
