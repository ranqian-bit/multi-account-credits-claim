#!/usr/bin/env bash
# Qoder 多账号体检
#
# 用法：audit-accounts.sh [账号名...]      不给参数则体检全部账号
#
# 检查项：
#   1. 登录态（CLI status 能否读到 Username）
#   2. 账号身份 uid —— **两个账号 uid 相同就说明是同一个人的号，必须重登**
#   3. 令牌缓存文件是否存在、权限是否 600
#   4. 活动接口是否可达（--dry-run，只查不领）
#   5. **今天领没领**（只认 CLAIM_BENEFIT 的 claimStatus；顶层 claimable 不可信）
#   6. **Credits 余额**（rem/total）—— 这是"钱到底到没到"的硬证据
#   7. systemd 定时器的随机窗口
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${QODER_PYTHON:-/usr/bin/python3.12}"
CLI_BIN="${QODER_CLI:-/root/.local/bin/qoderclicn}"
ACCOUNTS_ROOT="${QODER_ACCOUNTS_ROOT:-/opt/qoder-signin/accounts}"
ACCOUNT_ENV_DIR="${QODER_AUDIT_ENV_DIR:-/etc/qoder-signin/accounts}"

if [ "$#" -gt 0 ]; then
    ACCOUNTS="$*"
else
    ACCOUNTS=""
    for f in "${ACCOUNT_ENV_DIR}"/*.env; do
        [ -e "$f" ] || continue
        ACCOUNTS="$ACCOUNTS $(basename "$f" .env)"
    done
fi
ACCOUNTS="$(printf '%s\n' $ACCOUNTS)"

if [ -z "$ACCOUNTS" ]; then
    echo "没找到任何账号配置（${ACCOUNT_ENV_DIR}/*.env）" >&2
    exit 1
fi

echo "=============================================================="
echo " Qoder 多账号体检   $(date '+%F %T')"
echo "=============================================================="
echo

printf '%-8s %-17s %-10s %-9s %-8s %-6s %-12s %s\n' \
    "账号" "登录身份" "uid(前8)" "令牌缓存" "活动查询" "今日" "Credits余额" "结论"
printf '%-8s %-17s %-10s %-9s %-8s %-6s %-12s %s\n' \
    "--------" "-----------------" "----------" "---------" "--------" "------" "------------" "------"

declare -A UIDS
ISSUES=0

for acct in $ACCOUNTS; do
    CFG="${ACCOUNTS_ROOT}/${acct}"
    [ -f "${ACCOUNT_ENV_DIR}/${acct}.env" ] && CFG="$(set -a; . "${ACCOUNT_ENV_DIR}/${acct}.env" >/dev/null 2>&1; set +a; echo "${QODER_CONFIG_DIR:-$CFG}")"

    # --- 登录态 ---
    UN="(未登录)"
    if [ -x "$CLI_BIN" ]; then
        ST="$(QODERCN_CONFIG_DIR="$CFG" "$CLI_BIN" status 2>&1 || true)"
        UN="$(printf '%s' "$ST" | awk -F': ' '/^Username:/{print $2; exit}')"
        [ -n "$UN" ] || UN="(未登录)"
    fi

    # --- 令牌缓存 ---
    TC="无"
    if [ -f "${CFG}/.dt-token" ]; then
        PERM="$(stat -c%a "${CFG}/.dt-token" 2>/dev/null || echo '?')"
        if [ "$PERM" = "600" ]; then TC="有(${PERM})"; else TC="权限${PERM}!"; ISSUES=$((ISSUES+1)); fi
    fi

    # --- 活动接口（只查不领）---
    # 一次 python 调用把需要的字段都取出来，避免每账号起好几个解释器（服务器内存紧张）
    OUT="$("$SELF_DIR/run.sh" "$acct" --dry-run 2>&1 || true)"
    RESULT="$(printf '%s' "$OUT" | grep -a '^RESULT ' | tail -1 | sed 's/^RESULT //')"
    FIELDS="$(printf '%s' "$RESULT" | "$PYTHON_BIN" -c '
import sys, json
try:
    j = json.load(sys.stdin)
except Exception:
    print("-\t-\t-\t-\t-"); sys.exit()
uid = str(j.get("uid") or "")
# 今天的 CLAIM_BENEFIT 领没领，只认 campaigns[].claimStatus（顶层 claimable 不可信）
today = "-"
for c in (j.get("campaigns") or []):
    if c.get("status_before") == "CLAIMED":
        today = "已领"; break
    if c.get("status_before") == "CLAIMABLE":
        today = "可领"
q = j.get("quota") or {}
rem = q.get("addon_remaining")
tot = q.get("addon_total")
if rem is None and tot is None:
    quota = "-"
else:
    quota = "%s/%s" % (rem, tot)
print("%s\t%s\t%s\t%s\t%s" % (j.get("campaigns_http", "-"),
                              uid[:8] if uid else "-", uid, today, quota))
' 2>/dev/null)"
    HTTP="$(printf '%s' "$FIELDS" | cut -f1)"
    UID8="$(printf '%s' "$FIELDS" | cut -f2)"
    UIDFULL="$(printf '%s' "$FIELDS" | cut -f3)"
    TODAY="$(printf '%s' "$FIELDS" | cut -f4)"
    QUOTA="$(printf '%s' "$FIELDS" | cut -f5)"

    NOTE="正常"
    if [ "$UN" = "(未登录)" ]; then NOTE="未登录"; ISSUES=$((ISSUES+1)); fi
    if [ "$HTTP" != "200" ]; then NOTE="接口${HTTP}"; ISSUES=$((ISSUES+1)); fi
    if [ -n "$UIDFULL" ]; then
        if [ -n "${UIDS[$UIDFULL]:-}" ]; then
            NOTE="⚠ 与${UIDS[$UIDFULL]}同号"
            ISSUES=$((ISSUES+1))
        else
            UIDS[$UIDFULL]="$acct"
        fi
    fi

    printf '%-8s %-17s %-10s %-9s %-8s %-6s %-12s %s\n' \
        "$acct" "$UN" "$UID8" "$TC" "$HTTP" "$TODAY" "$QUOTA" "$NOTE"
done

echo
echo "---------------------- 定时器窗口 ----------------------"
printf '%-26s %-26s %-10s %s\n' "单元" "窗口起点(OnCalendar)" "抖动" "下次触发"
for acct in $ACCOUNTS; do
    UNIT="qoder-claim@${acct}.timer"
    LOAD="$(systemctl show -p LoadState "$UNIT" 2>/dev/null | cut -d= -f2-)"
    if [ "$LOAD" = "loaded" ]; then
        CAL="$(systemctl show -p TimersCalendar "$UNIT" 2>/dev/null \
               | grep -o -E '\*-\*-\* [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)"
        NCAL="$(systemctl show -p TimersCalendar "$UNIT" 2>/dev/null \
                | grep -o -c 'TimersCalendar=' || echo 0)"
        RND="$(systemctl show -p RandomizedDelayUSec "$UNIT" 2>/dev/null | cut -d= -f2-)"
        NEXT="$(systemctl show -p NextElapseUSecRealtime "$UNIT" 2>/dev/null | cut -d= -f2-)"
        EXTRA=""
        [ "${NCAL:-0}" -gt 1 ] && EXTRA=" ⚠${NCAL}个时间点"
        printf '%-26s %-26s %-10s %s%s\n' "$UNIT" "${CAL:-?}" "${RND:-?}" "${NEXT:-?}" "$EXTRA"
    else
        printf '%-26s %s\n' "$UNIT" "(未安装)"
    fi
done

echo
if [ "$ISSUES" -eq 0 ]; then
    echo "结论：全部正常 ✅"
    exit 0
else
    echo "结论：发现 $ISSUES 处需要处理 ⚠"
    echo
    echo "常见处置："
    echo "  · 未登录        →  ./login-cli.sh <账号名>"
    echo "  · 接口非 200    →  看 /var/log/qoder-signin/<账号名>.log 里的令牌获取过程"
    echo "  · 同号（uid 相同）→ 说明两个账号其实是同一个人，必须用无痕窗口重登其中一个"
    exit 2
fi
