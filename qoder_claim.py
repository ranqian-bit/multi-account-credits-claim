#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Qoder CN 每日 100 Credits 自动领取 —— 主脚本

设计要点
--------
1. **渠道伪装**：服务端按请求头 `Cosy-ClientType` 决定是否下发活动。
   `5`=国际版 CLI、`6`=中国版 CLI（都不下发），**`10`=中国版桌面端（下发）**。
2. **令牌获取三级降级**（日常不需要抓包）：
     L1 读上次成功用的令牌缓存      —— 秒级，绝大多数时候走这条
     L2 扫 CLI 进程内存 + 实时校验  —— 无外部依赖；扫不到就"戳"CLI 再扫
     L3 mitmdump 抓 CLI 自身流量    —— 兜底，需 mitmproxy（可用 QODER_ENABLE_PROXY_FALLBACK=0 关掉）
3. **幂等**：活动有 `claimStatus`，已领取则跳过；重复 POST 也不会重复发放（返回 replayed=true）。
4. **多账号隔离**：靠 `QODER_CONFIG_DIR` 指向每账号独立目录（连 `.auth` 一起隔离）。
   设置 `QODER_ACCOUNT` 后**只认该账号落点，绝不回落全局配置**。

退出码
------
0 成功（领取成功 / 今日已领取）   2 机器身份缺失   3 取不到令牌
4 活动查询失败                    5 领取失败       1 其他错误
"""
import os
import re
import sys
import json
import time
import uuid
import subprocess
import urllib.error
import urllib.request

# ------------------------------------------------------------------ 配置

CFG = os.environ.get("QODER_CONFIG_DIR", "/root/.qoder-cn")
ACCOUNT = os.environ.get("QODER_ACCOUNT", "").strip()
CLI = os.environ.get("QODER_CLI", "/root/.local/bin/qoderclicn")
CLIENT_TYPE = os.environ.get("QODER_CLIENT_TYPE", "10")   # 10 = 中国版桌面端
CLIENT_VERSION = os.environ.get("QODER_CLIENT_VERSION", "0.4.8")
BASE = os.environ.get("QODER_API_BASE", "https://openapi.qoder.com.cn")
TIMEOUT = int(os.environ.get("QODER_HTTP_TIMEOUT", "25"))

SESS = os.environ.get("QODER_SESSION", "qoder-claim")
LOCK_FILE = os.environ.get("QODER_LOCK_FILE", "")
LOG_FILE = os.environ.get("QODER_SIGNIN_LOG", "")
TOKEN_CACHE = os.environ.get("QODER_TOKEN_CACHE", os.path.join(CFG, ".dt-token"))

ENABLE_PROXY = os.environ.get("QODER_ENABLE_PROXY_FALLBACK", "1") not in ("0", "no", "false")
MITMDUMP = os.environ.get("QODER_MITMDUMP", "/root/mitmenv/bin/mitmdump")
MITM_CA = os.environ.get("QODER_MITM_CA", "/root/.mitmproxy/mitmproxy-ca-cert.pem")
MITM_PORT = os.environ.get("QODER_MITM_PORT", "8080")
RUNDIR = os.environ.get("QODER_RUNDIR", "/run/qoder-signin")
MITM_ADDON = os.path.join(RUNDIR, "token-addon.py")
MITM_CAPTURE = os.path.join(RUNDIR, "token-capture")

DRY_RUN = (os.environ.get("QODER_DRY_RUN", "0") not in ("0", "no", "false")
           or "--dry-run" in sys.argv)

# 每次运行顺带查一次 Credits 余额 —— 这是"钱到底到没到"的唯一硬证据。
# 只读、失败不影响主流程，可用 QODER_QUOTA_PROBE=0 关掉。
QUOTA_PROBE = os.environ.get("QODER_QUOTA_PROBE", "1") not in ("0", "no", "false")

# 令牌形态：dt- + 24 个 base64url 字符 = 27 字符。
# 注意内存里有形如 dt-audit-data-xxxx(21 字符) 的噪音，长度闸门专门用来排除它。
RE_TOKEN = re.compile(r"^dt-[A-Za-z0-9_\-]{20,80}$")
RE_TOKEN_MIN_LEN = 27
PAT_BEARER = re.compile(rb"Bearer[ \t\x00]{1,4}(dt-[A-Za-z0-9_\-]{20,80})")
PAT_QUOTED = re.compile(rb"[\"'](dt-[A-Za-z0-9_\-]{20,80})[\"']")
PAT_ANY = re.compile(rb"(dt-[A-Za-z0-9_\-]{24,48})")

# ------------------------------------------------------------------ 日志

_log_fh = None


def _open_log():
    global _log_fh
    if LOG_FILE and _log_fh is None:
        try:
            d = os.path.dirname(LOG_FILE)
            if d:
                os.makedirs(d, exist_ok=True)
            _log_fh = open(LOG_FILE, "a", encoding="utf-8")
        except Exception:
            _log_fh = None
    return _log_fh


def log(msg, level="INFO"):
    """人读的一行 + 落盘一行 JSON"""
    line = "[%s] %s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), level, msg)
    print(line, flush=True)
    fh = _open_log()
    if fh:
        try:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                 "level": level, "account": ACCOUNT or "-",
                                 "msg": msg}, ensure_ascii=False) + "\n")
            fh.flush()
        except Exception:
            pass


# ------------------------------------------------------------------ 工具

def sh(cmd, timeout=180):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


def rss_of(pid):
    try:
        v = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                           capture_output=True, text=True).stdout.strip()
        return int(v or 0)
    except Exception:
        return 0


def find_cli_pid():
    """pgrep -f 会命中 tmux 包装层，所以取 RSS 最大的那个才是 CLI 主体"""
    out = subprocess.run(["pgrep", "-x", "qoderclicn"], capture_output=True, text=True).stdout
    pids = [int(x) for x in out.split() if x.strip().isdigit()]
    if not pids:
        out = subprocess.run(["pgrep", "-f", "qoderclicn"], capture_output=True, text=True).stdout
        pids = [int(x) for x in out.split() if x.strip().isdigit()]
    return max(pids, key=rss_of) if pids else None


def kill_cli():
    sh("tmux -L %s kill-server 2>/dev/null; pkill -x qoderclicn 2>/dev/null; true" % SESS)


def tmux_start(inner):
    sh("tmux -L %s new-session -d -s %s -x 220 -y 50 \"%s\""
       % (SESS, SESS, inner))
    time.sleep(2)
    sh("tmux -L %s send-keys -t %s Enter 2>/dev/null; true" % (SESS, SESS))


def poke_cli():
    """戳一下 CLI，逼它发一次带 Authorization 的请求（令牌随后会留在堆里）"""
    sh("tmux -L %s send-keys -t %s '/claim' Enter 2>/dev/null; true" % (SESS, SESS))


# ------------------------------------------------------------------ 机器身份

_IDENTITY_CACHE = os.path.join(CFG, ".machine-identity.json")


def read_machine_identity():
    """umid-cache.json 是明文；设了 QODER_ACCOUNT 就绝不回落全局配置

    返回 (身份字典, 来源说明)。来源说明会写进日志，方便排查"到底读的哪份"。
    """
    candidates = [("账号目录", os.path.join(CFG, "umid-cache.json")),
                  ("账号缓存", _IDENTITY_CACHE)]
    if not ACCOUNT:
        candidates.append(("全局回落", "/root/.qoder-cn/umid-cache.json"))
    for label, p in candidates:
        try:
            with open(p) as f:
                j = json.load(f)
            info = j.get("info", j)
            if info.get("machineCode"):
                return {
                    "Cosy-MachineCode": info.get("machineCode", ""),
                    "Cosy-MachineToken": info.get("machineToken", ""),
                    "Cosy-MachineType": info.get("machineType", ""),
                    "Cosy-MachineOS": "x86_64_linux",
                }, "%s %s" % (label, p)
        except Exception:
            continue
    return {}, None


# ------------------------------------------------------------------ HTTP

def api(method, path, token, mid, body=None, client_type=None):
    h = {
        "Accept": "application/json",
        "Authorization": "Bearer " + token,
        "Cosy-ClientType": str(client_type or CLIENT_TYPE),
        "Cosy-Version": CLIENT_VERSION,
        "User-Agent": "Qoder",
        "X-Request-ID": str(uuid.uuid4()).upper(),
    }
    h.update(mid or {})
    data = json.dumps(body).encode() if body is not None else None
    if data is not None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, repr(e)


def validate_token(token, mid):
    """拿令牌打一次活动查询接口，200 才算有效"""
    st, _ = api("GET", "/sash/api/v1/me/campaigns", token, mid)
    return st


def quota_of(token, mid):
    """查 Credits 余额（只读）。

    ⚠️ 这是"钱到没到"的唯一硬证据 —— 领取接口返回 200 只说明**受理**了，
    真进账要看 `addOnQuota.remaining` 有没有上去。所以每次运行都记一笔。

    失败一律返回 None，绝不影响主流程。
    """
    if not QUOTA_PROBE:
        return None
    st, body = api("GET", "/api/v2/quota/usage", token, mid)
    if st != 200:
        log("余额查询失败 HTTP %s（不影响领取）" % st, "WARN")
        return None
    try:
        j = json.loads(body)
    except Exception:
        return None
    addon = j.get("addOnQuota") or {}
    return {
        "addon_total": addon.get("total"),
        "addon_used": addon.get("used"),
        "addon_remaining": addon.get("remaining"),
    }


# ------------------------------------------------------------------ 令牌 L1：缓存

def load_cached():
    try:
        with open(TOKEN_CACHE) as f:
            t = f.read().strip()
        return t if RE_TOKEN.match(t) else None
    except Exception:
        return None


def save_cached(t):
    try:
        d = os.path.dirname(TOKEN_CACHE)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(TOKEN_CACHE, "w") as f:
            f.write(t)
        os.chmod(TOKEN_CACHE, 0o600)
    except Exception:
        pass


# ------------------------------------------------------------------ 令牌 L2：内存扫描

def scan_bytes(chunks):
    """在若干字节块里找令牌候选并按可信度排序（抽出来便于自测）

    三种模式加权：`Bearer ` 锚点最可信(100)，引号次之(20)，裸串垫底(1)；
    裸串还要过长度闸门，排除 dt-audit-data-xxx 这类噪音（21 字符）。
    """
    weights, counts = {}, {}
    for data in chunks:
        for pat, w in ((PAT_BEARER, 100), (PAT_QUOTED, 20), (PAT_ANY, 1)):
            for m in pat.finditer(data):
                g = m.group(1) if m.groups() else m.group(0)
                t = g.decode("latin-1")
                if not RE_TOKEN.match(t):
                    continue
                if pat is PAT_ANY and len(t) < RE_TOKEN_MIN_LEN:
                    continue
                weights[t] = weights.get(t, 0) + w
                counts[t] = counts.get(t, 0) + 1
    ranked = sorted(weights.items(), key=lambda kv: (-kv[1], -counts[kv[0]]))
    return [(t, w, counts[t]) for t, w in ranked]


def mem_scan(pid):
    """只扫匿名段 / 堆段（令牌是运行期堆字符串），跳过 .so 与可执行映射"""
    chunks = []
    try:
        with open("/proc/%d/maps" % pid) as f:
            regions = []
            for line in f:
                p = line.rstrip("\n").split(None, 5)
                if len(p) < 2 or "r" not in p[1]:
                    continue
                path = p[5] if len(p) > 5 else ""
                if path and not (path.startswith("[heap") or path.startswith("[anon")):
                    continue
                a, b = p[0].split("-")
                regions.append((int(a, 16), int(b, 16)))
        with open("/proc/%d/mem" % pid, "rb", buffering=0) as mem:
            for (s, e) in regions:
                size = e - s
                if size <= 0 or size > 512 * 1024 * 1024:
                    continue
                try:
                    mem.seek(s)
                    chunks.append(mem.read(size))
                except Exception:
                    continue
    except Exception as e:
        log("内存扫描失败: %r" % e, "WARN")
        return []
    return scan_bytes(chunks)


def token_via_memscan(pid, mid, attempts=6, gap=6):
    tried = []
    for a in range(attempts):
        # 每轮重新解析 pid：CLI 可能是"启动器退出、主体接管"的两段式，
        # 原来的 pid 会变成死进程，导致 /proc/<pid>/maps 打不开。
        cur = find_cli_pid() or pid
        if not cur:
            tried.append("%d:CLI 进程已消失" % (a + 1))
            return None, "cli_gone", tried
        cands = mem_scan(cur)
        tried.append("%d:%s" % (a + 1, ",".join("%s(w=%d,c=%d)" % (t[:8], w, c)
                                                for t, w, c in cands[:4]) or "空"))
        for t, w, c in cands[:6]:
            if validate_token(t, mid) == 200:
                return t, "memscan(w=%d,c=%d,attempt=%d)" % (w, c, a + 1), tried
        if a < attempts - 1:
            poke_cli()
            time.sleep(gap)
    return None, "memscan_failed", tried


# ------------------------------------------------------------------ 令牌 L3：代理抓包

ADDON_SRC = '''# -*- coding: utf-8 -*-
"""把 openapi 的 Authorization 头写出来（mitmdump -s 加载）"""
import os
from mitmproxy import http
OUT = os.environ.get("QODER_MITM_CAPTURE", "/run/qoder-signin/token-capture")


def response(flow: http.HTTPFlow) -> None:
    if "openapi.qoder.com.cn" not in flow.request.pretty_host:
        return
    a = flow.request.headers.get("authorization", "")
    if a.startswith("Bearer dt-"):
        try:
            with open(OUT, "w") as f:
                f.write(a.split(" ", 1)[1].strip() + "\\n")
        except Exception:
            pass
'''


def token_via_proxy(mid, timeout=120):
    if not ENABLE_PROXY:
        return None, "disabled"
    if not os.path.exists(MITMDUMP):
        return None, "mitmdump_missing(%s)" % MITMDUMP
    kill_cli()
    sh("pkill -x mitmdump 2>/dev/null; sleep 1; true")
    try:
        os.makedirs(RUNDIR, exist_ok=True)
        with open(MITM_ADDON, "w") as f:
            f.write(ADDON_SRC)
    except Exception as e:
        return None, "addon_write_failed:%r" % e
    try:
        os.remove(MITM_CAPTURE)
    except Exception:
        pass
    proxy = "http://127.0.0.1:%s" % MITM_PORT
    sh("QODER_MITM_CAPTURE=%s nohup %s -q --listen-port %s -s %s >/dev/null 2>&1 &"
       % (MITM_CAPTURE, MITMDUMP, MITM_PORT, MITM_ADDON))
    time.sleep(6)
    tmux_start("QODERCN_CONFIG_DIR=%s HTTPS_PROXY=%s https_proxy=%s "
               "NODE_EXTRA_CA_CERTS=%s NODE_TLS_REJECT_UNAUTHORIZED=0 %s"
               % (CFG, proxy, proxy, MITM_CA, CLI))
    tok = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(3)
        try:
            with open(MITM_CAPTURE) as f:
                t = f.read().strip()
            if RE_TOKEN.match(t):
                tok = t
                break
        except Exception:
            pass
    sh("pkill -x mitmdump 2>/dev/null; true")
    return tok, ("ok" if tok else "capture_timeout")


# ------------------------------------------------------------------ 业务

def start_cli_and_wait(max_wait=90):
    kill_cli()
    tmux_start("QODERCN_CONFIG_DIR=%s %s" % (CFG, CLI))
    deadline = time.time() + max_wait
    while time.time() < deadline:
        time.sleep(3)
        logdir = sh("ls -td %s/logs/runs/*/ 2>/dev/null | head -1" % CFG).strip()
        if not logdir:
            continue
        n = sh("grep -a -c 'operation=' %s/qodercli.log 2>/dev/null" % logdir).strip()
        try:
            if int(n or 0) >= 5:
                return True
        except ValueError:
            pass
    return False


def is_logged_in():
    """账号目录下有没有凭据文件。没有就一定拿不到令牌，早点退出省得白跑。"""
    return os.path.isfile(os.path.join(CFG, ".auth", "user"))


def get_token(mid):
    cached = load_cached()
    if cached:
        if validate_token(cached, mid) == 200:
            log("L1 缓存令牌有效")
            return cached, "cache"
        log("L1 缓存令牌已失效，回落 L2", "WARN")
    else:
        log("L1 无缓存令牌")

    # 没有凭据文件就一定拿不到令牌 —— 别浪费三分钟去启 CLI 和抓包
    if not is_logged_in():
        log("账号目录下没有 .auth/user，该账号尚未登录", "ERROR")
        log("→ 请执行：login-cli.sh %s" % (ACCOUNT or "<账号名>"), "ERROR")
        return None, "not_logged_in"

    authed = start_cli_and_wait()
    log("CLI 认证完成=%s" % authed)
    pid = find_cli_pid()
    if pid:
        log("CLI pid=%d" % pid)
        t, why, tried = token_via_memscan(pid, mid)
        for line in tried:
            log("  内存扫描 %s" % line)
        if t:
            log("L2 命中：%s" % why)
            return t, why
        if why == "cli_gone":
            log("CLI 启动后进程即消失，通常意味着该账号未登录或凭据已失效", "WARN")
        log("L2 未取到有效令牌，回落 L3", "WARN")
    else:
        log("未找到 CLI 进程，跳过 L2", "WARN")

    t, why = token_via_proxy(mid)
    log("L3 抓包结果：%s" % why)
    if t:
        return t, "proxy_capture"
    return None, why


def run_claim(mid):
    token, source = get_token(mid)
    if not token:
        return 3, {"token_source": source,
                   "reason": "取不到有效令牌（%s）" % source,
                   "hint": "若为 not_logged_in，请先执行 login-cli.sh %s" % (ACCOUNT or "<账号名>")}

    save_cached(token)
    log("令牌来源=%s 长度=%d" % (source, len(token)))

    st, body = api("GET", "/sash/api/v1/me/campaigns", token, mid)
    if st != 200:
        log("活动查询失败 HTTP %s：%s" % (st, body[:200]), "ERROR")
        return 4, {"token_source": source, "campaigns_http": st}

    try:
        obj = json.loads(body)
    except Exception:
        log("活动响应无法解析：%s" % body[:200], "ERROR")
        return 4, {"token_source": source, "campaigns_http": st, "parse_error": True}

    log("活动：showCampaign=%s claimable=%s 数量=%d"
        % (obj.get("showCampaign"), obj.get("claimable"), len(obj.get("campaigns") or [])))

    # ⚠️ 顶层 claimable **不可信**：它把 actionType=VIEW_DETAILS 之类的"看看详情"活动也算进去，
    #    即使当天的 CLAIM_BENEFIT 已经领过，它照样可能是 true。
    #    判断"今天领没领"只认 campaigns[].claimStatus（且必须限定 actionType=CLAIM_BENEFIT）。
    kinds = {}
    for c in (obj.get("campaigns") or []):
        kinds[c.get("actionType")] = kinds.get(c.get("actionType"), 0) + 1
    if kinds:
        log("  活动构成：%s" % ", ".join("%s×%d" % (k, v) for k, v in sorted(kinds.items())))

    results, claimed, skipped = [], 0, 0
    for c in (obj.get("campaigns") or []):
        if c.get("actionType") != "CLAIM_BENEFIT":
            continue
        cid, status = c.get("campaignId"), c.get("claimStatus")
        item = {"campaignId": cid, "key": c.get("campaignKey"), "status_before": status}
        if status == "CLAIMED":
            item["action"] = "skip_already_claimed"
            skipped += 1
            log("  活动 %s 今日已领取，跳过" % c.get("campaignKey"))
        elif DRY_RUN:
            item["action"] = "dry_run"
            log("  [dry-run] 活动 %s 可领取，未提交" % c.get("campaignKey"))
        else:
            st2, b2 = api("POST", "/sash/api/v1/me/campaigns/%s/claim" % cid, token, mid, {})
            item["claim_http"] = st2
            try:
                j2 = json.loads(b2)
                item["status"] = j2.get("status")
                item["replayed"] = j2.get("replayed")
                item["amount"] = (j2.get("benefit") or {}).get("amount")
                item["expiresAt"] = j2.get("expiresAt")
            except Exception:
                item["raw"] = b2[:200]
            if st2 == 200:
                claimed += 1
                log("  活动 %s 领取成功：%s（replayed=%s，%s Credits，到期 %s）"
                    % (c.get("campaignKey"), item.get("status"), item.get("replayed"),
                       item.get("amount"), item.get("expiresAt")))
            else:
                log("  活动 %s 领取失败 HTTP %s：%s"
                    % (c.get("campaignKey"), st2, b2[:200]), "ERROR")
        results.append(item)

    if not results:
        log("当前没有可领取的 CLAIM_BENEFIT 活动（可能窗口未开始或已过期）", "WARN")

    code = 0 if all(i.get("claim_http", 200) == 200 for i in results) else 5

    q = quota_of(token, mid)
    if q:
        log("余额：Credits 共 %s，已用 %s，剩 %s"
            % (q.get("addon_total"), q.get("addon_used"), q.get("addon_remaining")))

    return code, {"token_source": source, "campaigns_http": st,
                  "uid": obj.get("uid"),
                  "showCampaign": obj.get("showCampaign"), "claimable": obj.get("claimable"),
                  "claimed": claimed, "skipped": skipped, "campaigns": results,
                  "quota": q}


# ------------------------------------------------------------------ 入口

def main():
    summary = {"account": ACCOUNT or "(default)", "config_dir": CFG,
               "client_type": CLIENT_TYPE, "dry_run": DRY_RUN}
    log("=" * 62)
    log("启动：账号=%s 配置目录=%s clientType=%s%s"
        % (summary["account"], CFG, CLIENT_TYPE, " [DRY-RUN]" if DRY_RUN else ""))

    mid, mid_src = read_machine_identity()

    # 机器身份是 CLI 首次启动时写进账号目录的，所以新账号可能"还没有"。
    # 这里启动一次 CLI 让它生成，再重新读一次（避免"没有身份就永远拿不到身份"的死循环）。
    if not mid.get("Cosy-MachineCode"):
        log("账号目录里还没有机器身份（umid-cache.json），启动一次 CLI 让它生成…", "WARN")
        start_cli_and_wait(max_wait=60)
        kill_cli()
        mid, mid_src = read_machine_identity()

    if not mid.get("Cosy-MachineCode"):
        log("仍取不到机器身份；请先执行 login-cli.sh %s 登录该账号" % (ACCOUNT or "<账号名>"), "ERROR")
        summary.update({"ok": False, "stage": "no_machine_identity",
                        "hint": "该账号可能从未登录过，umid-cache.json 未生成"})
        print("RESULT " + json.dumps(summary, ensure_ascii=False))
        return 2

    log("机器身份来源：%s" % mid_src)

    try:
        code, extra = run_claim(mid)
    except Exception as e:
        import traceback
        log("未捕获异常：%r" % e, "ERROR")
        log(traceback.format_exc()[-800:], "ERROR")
        code, extra = 1, {"reason": repr(e)}
    finally:
        kill_cli()

    summary.update(extra)
    summary["ok"] = code == 0
    summary["exit_code"] = code
    log("结果：ok=%s%s" % (summary["ok"],
                          "" if summary["ok"] else "（退出码 %d）" % code))
    print("RESULT " + json.dumps(summary, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
