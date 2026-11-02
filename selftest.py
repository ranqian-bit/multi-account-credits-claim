#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地自测 —— 不需要服务器、不联网

覆盖范围：令牌识别逻辑、文件完整性、shell 语法、systemd 单元要点、脱敏检查。
在项目目录执行：  python selftest.py
"""
import os
import re
import sys
import json
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))

PASS, FAIL = [], []


def check(name, cond, detail=""):
    if cond:
        PASS.append(name)
        print("  ✓ %s" % name)
    else:
        FAIL.append((name, detail))
        print("  ✗ %s   %s" % (name, detail))


def section(t):
    print()
    print("=" * 66)
    print(t)
    print("=" * 66)


# ---------------------------------------------------------------- 被测对象

def load_claim():
    """把 qoder_claim.py 作为模块加载（不执行 main）"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("qoder_claim", os.path.join(HERE, "qoder_claim.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- 1. 令牌识别

REAL = "dt-TESTTESTTESTTESTTESTTEST"        # 27 字符：等长合成令牌（勿放真实令牌）
NOISE = "dt-audit-data-1a2b3c4"             # 21 字符：内存噪音（实测存在的那种）
NOISE2 = "dt-audit-data"                    # 14 字符：更短的噪音


def test_token_patterns():
    section("1. 令牌识别（内存扫描的噪音排除与排序）")
    m = load_claim()

    check("真令牌长度 = 27", len(REAL) == 27, "实际 %d" % len(REAL))
    check("噪音长度 = 21", len(NOISE) == 21, "实际 %d" % len(NOISE))

    check("RE_TOKEN 接受真令牌", bool(m.RE_TOKEN.match(REAL)))
    check("RE_TOKEN 本身就拒绝 21 字符噪音（第一道闸）",
          not m.RE_TOKEN.match(NOISE),
          "长度下限 %d，噪音 %d 字符" % (23, len(NOISE)))
    check("RE_TOKEN 拒绝过短串", not m.RE_TOKEN.match("dt-abc"))
    check("RE_TOKEN 拒绝无前缀串", not m.RE_TOKEN.match("5MEJmi5kipBoJy2YOhXNepXK"))
    check("RE_TOKEN 拒绝含非法字符", not m.RE_TOKEN.match("dt-5MEJmi5kipBoJy2YOhXNepXK!"))

    # 场景 A：真令牌带 Bearer 锚点，噪音混在堆里
    blob = (b"xxxx\x00Authorization: Bearer " + REAL.encode() + b"\x00yyyy" +
            NOISE.encode() + b"\x00" + NOISE2.encode())
    ranked = m.scan_bytes([blob])
    top = ranked[0][0] if ranked else None
    check("场景A：真令牌排第一", top == REAL, "实际 %s" % top)
    check("场景A：21 字符噪音被排除",
          all(t != NOISE for t, _, _ in ranked),
          "候选=%s" % [t for t, _, _ in ranked])
    check("场景A：真令牌带上 Bearer 锚点权重", ranked and ranked[0][1] >= 100,
          "weight=%s" % (ranked[0][1] if ranked else "-"))

    # 场景 A2：万一噪音长度也够 27（第二道闸——长度闸门只挡裸串）
    long_noise = "dt-audit-data-abcdefghijklm"      # 27 字符，与真令牌等长
    check("等长噪音长度 = 27（构造成立）", len(long_noise) == 27, "实际 %d" % len(long_noise))
    blob6 = (b"Bearer " + long_noise.encode() + b"\x00" + REAL.encode())
    ranked6 = m.scan_bytes([blob6])
    check("场景A2：等长噪音若带 Bearer 锚点则排前（故必须实时校验）",
          ranked6 and ranked6[0][0] == long_noise,
          "第一 = %s" % (ranked6[0][0] if ranked6 else None))

    # 场景 B：只有裸串，没有 Bearer / 引号锚点
    blob2 = (REAL.encode() + b"\x00" + REAL.encode() + b"\x00" + REAL.encode())
    ranked2 = m.scan_bytes([blob2])
    check("场景B：裸串仍能命中（weight=出现次数）",
          ranked2 and ranked2[0][0] == REAL and ranked2[0][1] == 3,
          "结果=%s" % ranked2[:2])

    # 场景 C：噪音出现次数多于真令牌（这是最初踩的坑）
    blob3 = NOISE.encode() + b"\x00" + NOISE.encode() + b"\x00" + NOISE.encode() + \
        b"\x00" + NOISE.encode() + b"\x00" + REAL.encode()
    ranked3 = m.scan_bytes([blob3])
    check("场景C：噪音出现 4 次也不会盖过真令牌",
          ranked3 and ranked3[0][0] == REAL,
          "第一 = %s" % (ranked3[0][0] if ranked3 else None))

    # 场景 D：引号包裹（JSON 值）
    blob4 = ('{"accessToken":"%s"}' % REAL).encode()
    ranked4 = m.scan_bytes([blob4])
    check("场景D：JSON 引号锚点命中", ranked4 and ranked4[0][0] == REAL)

    # 场景 E：空数据不应崩
    check("场景E：空输入返回空列表", m.scan_bytes([b""]) == [])

    # 场景 F：多个真形令牌时选票多的
    other = "dt-AAAAAAAAAAAAAAAAAAAAAAAA"
    blob5 = (REAL + "\x00" + REAL + "\x00" + other).encode()
    ranked5 = m.scan_bytes([blob5])
    check("场景F：同形令牌取出现次数多者", ranked5[0][0] == REAL)


# ---------------------------------------------------------------- 2. 配置与常量

def test_config():
    section("2. 关键常量（渠道伪装 / 接口 / 超时）")
    m = load_claim()
    src = open(os.path.join(HERE, "qoder_claim.py"), encoding="utf-8").read()
    check("clientType 默认 10（中国版桌面端）",
          'QODER_CLIENT_TYPE", "10"' in src)
    check("活动查询接口正确", "/sash/api/v1/me/campaigns" in src)
    check("领取接口正确", '/sash/api/v1/me/campaigns/%s/claim' in src)
    check("基址为中国版 openapi", "openapi.qoder.com.cn" in src)
    check("支持 DRY_RUN", "QODER_DRY_RUN" in src and "DRY_RUN" in src)
    check("有机器身份缺失的早退分支", "no_machine_identity" in src)
    check("机器身份缺失时会先启动一次 CLI 自举（避免先有鸡还是先有蛋）",
          "启动一次 CLI 让它生成" in src)
    check("机器身份会记录来源（便于排查读的是哪一份）",
          "机器身份来源" in src and "read_machine_identity" in src)
    check("未登录账号会提前退出（不白跑三分钟启 CLI + 抓包）",
          "is_logged_in" in src and "not_logged_in" in src)
    check("内存扫描每轮重新解析 pid（CLI 两段式启动会让旧 pid 变死进程）",
          "find_cli_pid() or pid" in src)
    check("残留失败原因会写进 RESULT 便于体检定位",
          '"reason": "取不到有效令牌' in src)
    check("设了账号就不回落全局配置",
          'if not ACCOUNT:' in src and "/root/.qoder-cn/umid-cache.json" in src)

    runsh = open(os.path.join(HERE, "run.sh"), encoding="utf-8").read()
    check("run.sh 加载账号 env 时用了 set -a（否则变量不会传给子进程）",
          "set -a" in runsh and "set +a" in runsh)
    check("run.sh --inspect 会导出 QODER_* 变量（供服务器自测验证 set -a 链路）",
          "env | grep '^QODER_'" in runsh)
    check("run.sh 用 flock 做每账号互斥", "flock -n 9" in runsh)
    check("run.sh 检测到 systemd 会压缩过大抖动", "INVOCATION_ID" in runsh)

    srv = open(os.path.join(HERE, "selftest-server.sh"), encoding="utf-8").read()
    check("服务器自测覆盖 set -a 链路", "marker-abc-123" in srv)
    check("服务器自测带反向验证", "反向验证" in srv)
    check("服务器自测会检查 OnCalendar 只有一个", "TimersCalendar=" in srv and "NCAL" in srv)

    aud = open(os.path.join(HERE, "audit-accounts.sh"), encoding="utf-8").read()
    # bash 里 UID 是只读内置变量，赋值会报 "UID: readonly variable" 并中断循环
    check("audit-accounts.sh 没有用 UID 当变量名（bash 只读内置）",
          not re.search(r"^\s*UID=", aud, re.M))
    check("audit-accounts.sh 用 LoadState 判断定时器是否存在",
          "LoadState" in aud)
    check("audit-accounts.sh 显示 Credits 余额（入账硬证据）",
          "Credits余额" in aud and "addon_remaining" in aud)
    check("audit-accounts.sh 显示今日领取状态", "TODAY" in aud and "已领" in aud)

    src = open(os.path.join(HERE, "qoder_claim.py"), encoding="utf-8").read()
    check("主脚本会查 Credits 余额并写进 RESULT",
          "def quota_of(" in src and "addOnQuota" in src and '"quota": q' in src)
    check("余额查询可关闭且失败不影响主流程",
          "QODER_QUOTA_PROBE" in src and "不影响领取" in src)
    check("代码里明确标注顶层 claimable 不可信（把 VIEW_DETAILS 也算进去）",
          "claimable" in src and "VIEW_DETAILS" in src and "不可信" in src)
    check("只领 actionType=CLAIM_BENEFIT 的活动",
          'c.get("actionType") != "CLAIM_BENEFIT"' in src)


# ---------------------------------------------------------------- 3. 文件完整性

REQUIRED = ["qoder_claim.py", "run.sh", "login-cli.sh", "audit-accounts.sh",
            "precheck.sh", "install.sh", "accounts.conf",
            "systemd/qoder-claim@.service", "systemd/qoder-claim@.timer",
            "README.md", "协议合规核查.md", ".gitignore"]


def test_files():
    section("3. 文件完整性与权限意图")
    for f in REQUIRED:
        p = os.path.join(HERE, f.replace("/", os.sep))
        check("存在 %s" % f, os.path.isfile(p))
    sh_files = ["run.sh", "login-cli.sh", "audit-accounts.sh", "precheck.sh", "install.sh"]
    for f in sh_files:
        p = os.path.join(HERE, f)
        if not os.path.isfile(p):
            continue
        txt = open(p, encoding="utf-8", errors="replace").read()
        first = txt.splitlines()[0].strip() if txt else ""
        check("%s 有 shebang" % f, first.startswith("#!"))
        # audit/precheck 是有意不带 -e 的（要跑完所有检查项再汇总），只要求 -u + pipefail
        check("%s 设了 -u 与 pipefail" % f, "set -uo pipefail" in txt or "set -euo pipefail" in txt)
        check("%s 使用了严格模式（-e）或在预期白名单" % f,
              "set -euo pipefail" in txt or f in ("audit-accounts.sh", "precheck.sh"),
              "非白名单脚本应加 -e")

    # login-cli.sh 的两条硬要求：识别 5 分钟过期、自动换链
    lg = open(os.path.join(HERE, "login-cli.sh"), encoding="utf-8").read()
    check("login-cli.sh 感知 device flow 5 分钟硬超时",
          "Device flow timed out" in lg and "5 分钟" in lg)
    check("login-cli.sh 会自动换链（多轮 + URL_FILE 覆盖写）",
          "seq 1 \"$ROUNDS\"" in lg and "URL_FILE" in lg and "login.url" in lg)
    check("login-cli.sh 每轮结束会清掉旧 tmux 会话",
          "tmux -L \"$SESSION\" kill-server" in lg)
    check("login-cli.sh 已登录时短路退出（不重复折腾）",
          "已登录，无需重新授权" in lg)


# ---------------------------------------------------------------- 4. shell 语法

def test_shell_syntax():
    section("4. shell 脚本语法（bash -n）")
    for f in ["run.sh", "login-cli.sh", "audit-accounts.sh", "precheck.sh", "install.sh"]:
        p = os.path.join(HERE, f)
        if not os.path.isfile(p):
            continue
        try:
            r = subprocess.run(["bash", "-n", p], capture_output=True, text=True, timeout=30)
            check("bash -n %s" % f, r.returncode == 0, r.stderr.strip()[:200])
        except FileNotFoundError:
            check("bash -n %s" % f, True, "（本机无 bash，已跳过）")
            break


# ---------------------------------------------------------------- 5. systemd 要点

def test_systemd():
    section("5. systemd 单元要点")
    svc = open(os.path.join(HERE, "systemd", "qoder-claim@.service"), encoding="utf-8").read()
    tmr = open(os.path.join(HERE, "systemd", "qoder-claim@.timer"), encoding="utf-8").read()

    check("service 用 oneshot", "Type=oneshot" in svc)
    check("service 有 TimeoutStartSec", "TimeoutStartSec=" in svc)
    check("service 内没有 sleep（避免占用 TimeoutStartSec）",
          not re.search(r"^\s*ExecStart.*\bsleep\b", svc, re.M))
    check("service 的 ExecStartPre 是软失败（带 -）", "ExecStartPre=-" in svc)
    check("timer 使用 RandomizedDelaySec", "RandomizedDelaySec=" in tmr)
    check("timer 精度到秒", "AccuracySec=1s" in tmr)
    check("timer 开启 Persistent", "Persistent=true" in tmr)
    check("timer 关联 %i 服务", "Unit=qoder-claim@%i.service" in tmr)

    m = re.search(r"OnCalendar=\*-\*-\* (\d\d):(\d\d):00", tmr)
    check("timer 默认窗口起点在 10:00 之后", bool(m) and int(m.group(1)) >= 10,
          "起点=%s" % (m.group(1) + ":" + m.group(2) if m else "?"))


# ---------------------------------------------------------------- 6. install 窗口分配

def test_install_windows():
    section("6. install.sh 的窗口分配规则（多账号不重叠）")
    src = open(os.path.join(HERE, "install.sh"), encoding="utf-8").read()
    check("基准时间 10:20（活动 10:00 刷新后）", "WINDOW_BASE_HOUR=10" in src and "WINDOW_BASE_MIN=20" in src)
    check("窗口长度 4 小时", "WINDOW_SECONDS=14400" in src)
    check("抖动 = 窗口大小", "RANDOMIZED_DELAY=14400" in src)
    check("账号间窗口顺延", "WINDOW_OF" in src and "WINDOW_END_OF" in src)
    check("窗口用纯算术计算（不用 date -d，避免 +0 被当 UTC 偏移）",
          "TOTAL_MIN" in src and "$(date -d" not in src,
          "发现实际调用了 date -d" if "$(date -d" in src else "")
    check("drop-in 先清空 OnCalendar（systemd 列表型设置是累加，不清会一天跑两次）",
          bool(re.search(r"^OnCalendar=\s*$\n^OnCalendar=\*-\*-\*", src, re.M)))
    check("用 install -m 复制并处理同文件情形", "install_file()" in src and "源即目标" in src)
    check("账号 env 权限 600", "chmod 600 \"$ENVF\"" in src)
    check("配置目录权限 700", "chmod 700 \"$CFGD\"" in src)

    # 模拟窗口计算：起点 + i*4h
    def slot(i):
        total = 10 * 60 + 20 + i * 240
        return "%02d:%02d" % (total // 60, total % 60)
    w = [slot(i) for i in range(3)]
    check("3 个账号窗口依次为 10:20 / 14:20 / 18:20",
          w == ["10:20", "14:20", "18:20"], "实际 %s" % w)
    check("窗口均落在 10:00 之后 22:20 之前（在活动窗口内）",
          all(10 <= int(x[:2]) <= 22 for x in w))


# ---------------------------------------------------------------- 7. 脱敏

SENSITIVE = [
    ("真实服务器 IP", "118.190.151.100"),
    ("真实账号名", "ran_qian"),
    ("Qoder acct2 真实用户名", "nick7250728677"),
    ("真实手机号", "18606190017"),
    ("真实手机号前缀", "1860619"),
    ("真实 uid 前缀", "0aca0ef2"),
    ("真实 uid 前缀2", "1720a463"),
    ("Qoder acct1 uid 前缀", "019ed098"),
    ("Qoder acct2 uid 前缀", "019f7e9a"),
    ("真实 machineCode", "a49821eb84"),
    ("真实 machineToken", "P1gAFmBr"),
    ("真实 dt 令牌", "dt-5MEJ"),
    ("登录链接里的 machine_token", "machine_token=P1gAFmBr"),
]

# 这些文件本身就在记录/检测敏感值，跳过扫描
SKIP_SCAN = {"selftest.py", "请勿上传-真实信息备查.md"}


def test_desensitized():
    section("7. 脱敏检查（交付文件不得含真实敏感值）")
    scanned = 0
    hit = False
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", ".workbuddy")]
        for fn in files:
            if fn in SKIP_SCAN or fn.endswith((".pyc", ".zip", ".png", ".jpg", ".xlsx")):
                continue
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, HERE)
            try:
                txt = open(p, encoding="utf-8", errors="replace").read()
            except Exception:
                continue
            if ".git" in rel.split(os.sep):
                continue
            scanned += 1
            for label, needle in SENSITIVE:
                if needle in txt:
                    hit = True
                    check("%s 不含 %s" % (rel, label), False, "命中：%s" % needle)
    check("扫描了 %d 个文件且未发现真实敏感值" % scanned, not hit)


# ---------------------------------------------------------------- 主流程

def main():
    print("Qoder 自动领取 —— 本地自测")
    print("目录：%s" % HERE)
    test_token_patterns()
    test_config()
    test_files()
    test_shell_syntax()
    test_systemd()
    test_install_windows()
    test_desensitized()

    print()
    print("=" * 66)
    print("结果：%d 通过 / %d 失败" % (len(PASS), len(FAIL)))
    if FAIL:
        print()
        for name, detail in FAIL:
            print("  失败：%s   %s" % (name, detail))
        print("=" * 66)
        return 1
    print("全部通过 ✅")
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
