# Qoder 每日 100 Credits 自动领取

> ⚠️ **合规声明（请先读这一段）**
>
> 本项目通过**自动化脚本**完成 Qoder 官方活动的每日领取动作。活动规则明文写的是
> 「领取渠道仅限 Qoder CN **桌面端**」「**须主动领取**」，因此**用脚本自动领取属于违反活动规则**，
> 同时通常也触犯其服务协议中关于「不得使用自动化程序/外挂访问服务」的条款。
>
> - **性质**：民事违约，**不是犯罪**。后果可能是**回收 Credits、封禁账号**，订阅费不退。
> - **风险分水岭**：是否**提供给他人使用**、是否**获利**。仅自用、只跑自己的账号、凭据不外传，风险相对可控。
> - **本项目不提供任何绕过风控的承诺**。服务端识别到异常（例如虚拟机、高频访问）随时可能调整策略。
>
> 条款出处与逐条比对见 [`协议合规核查.md`](协议合规核查.md)。
> **如果你不能接受上述风险，请不要部署。**

---

## 一、这是什么

在**无图形界面的 Linux 服务器**上，为**多个 Qoder 账号**自动完成每日 100 Credits 的领取。

核心机制一句话：**活动页说的"仅限桌面端"是服务端按请求头强制判定的，而那个请求头我们自己能写。**

| 项目 | 值 |
|---|---|
| 奖励 | 每账号每天 **100 通用 Credits** |
| 刷新时间 | 每日 **10:00（UTC+8）** 开新一轮，**次日 09:59** 截止，错过不补领 |
| 有效期 | 每笔自领取起 **30 天** |
| 渠道 | 仅桌面端（**服务端按 `Cosy-ClientType` 判定**） |
| 资格 | 个人版（团队版/企业版不参与） |

### 关键发现

服务端根据请求头 `Cosy-ClientType` 决定**是否下发活动**。实测枚举 1–11：

| 值 | 含义 | 是否下发活动 |
|---|---|---|
| `5` | 国际版 CLI | ❌ |
| `6` | 中国版 CLI（CLI 默认值） | ❌ |
| `8` | 另一种客户端 | ✅ |
| **`10`** | **中国版桌面端** | ✅ **完整活动** |

所以本项目用 `Cosy-ClientType: 10` 发请求 —— 这就是全部"魔法"。

---

## 二、快速开始

服务器上以 **root** 执行（把整个文件夹传上去，或者 `git clone` 到本地再 `scp`）：

```bash
cd <项目目录>
./install.sh
```

`install.sh` 会：装/检查官方 CLI → 建目录 → 铺程序 → 生成账号配置 → 装 systemd 定时器 → 自检。

然后**给每个账号登录一次**：

```bash
/opt/qoder-signin/login-cli.sh acct1
```

脚本会打印一条授权链接，在浏览器里打开、选账号、确认即可。

> ⏱️ **授权链接只有 5 分钟有效期**（服务端下发的 device flow 硬限制，CLI 没有参数可调）。
> 所以脚本做成了**自动换链**：一轮超时立刻重新发起一条新链接并打印出来，默认连做 6 轮。
> 随时可以用 `cat /var/log/qoder-signin/<账号名>.login.url` 取到**当前有效**的那条链接。

> ⚠️ **第二个及以后的账号，务必用无痕窗口打开授权链接。**
> 否则浏览器会复用旧会话，导致「两个账号其实是同一个人」——
> 这是本项目最容易踩的坑，且表面上完全看不出来（令牌不同 ≠ 账号不同）。

最后体检 + 试跑：

```bash
/opt/qoder-signin/audit-accounts.sh                 # 核对登录态、uid、今日领取状态与余额
/opt/qoder-signin/run.sh acct1 --dry-run            # 只查活动，不领取
/opt/qoder-signin/run.sh acct1                      # 真实领取
```

体检输出形如：

```
账号   登录身份      uid(前8)  令牌缓存 活动查询 今日 Credits余额 结论
acct1    user-a           1a2b3c4d   有(600)  200   已领 96.0/100.0   正常
acct2    user-b           5e6f7a8b   有(600)  200   已领 100.0/100.0  正常
```

> **`Credits余额` 这一列才是"钱到没到"的硬证据** —— 领取接口返回 200 只说明受理了。
> 主脚本每次运行都会顺手查一次余额（只读、失败不影响领取，`QODER_QUOTA_PROBE=0` 可关）。

> ⚠️ 判断"今天领没领"**只看 `CLAIM_BENEFIT` 那条的 `claimStatus`**。
> 顶层 `claimable` 字段不可信：它把 `actionType=VIEW_DETAILS`（如"Pro 首月翻倍"推广，
> 不发任何 Credits）也算进去，所以领完之后它照样可能是 `true`。

---

## 三、工作原理

### 3.1 领取三步

```
启动 Qoder CN CLI（负责认证 / 刷新令牌）
      ↓  取到 dt- 令牌
Cosy-ClientType: 10 伪装桌面端
      ↓
GET  /sash/api/v1/me/campaigns                    查活动
POST /sash/api/v1/me/campaigns/{id}/claim         领取（幂等）
```

领取接口是**幂等**的：当天已领过会返回 `status: CLAIMED, replayed: true`，不会重复发放。

### 3.2 令牌从哪来 —— 三级降级

日常运行**不需要抓包**：

| 级别 | 手段 | 依赖 | 耗时 |
|---|---|---|---|
| **L1** | 读上次成功用的令牌缓存（`<账号目录>/.dt-token`，600） | 无 | 秒级 |
| **L2** | 扫 CLI 进程内存（`/proc/<pid>/mem`），带**实时校验**；扫不到就"戳"CLI 再扫 | 无 | 几秒~1 分钟 |
| **L3** | mitmdump 抓 CLI 自身流量，用 addon 把 `Authorization` 头写出来 | mitmproxy | 约 1 分钟 |

L1 失效（令牌过期）→ 自动回落 L2；L2 取到候选会**逐个真的去打一次接口**，200 才算命中；
都不行才走 L3。L3 可以关掉：账号 env 里设 `QODER_ENABLE_PROXY_FALLBACK="0"`。

**L2 的两个要点**（都是踩过坑换来的）：

1. 内存里除了真令牌，还有形如 `dt-audit-data-…`（**21 字符**）的噪音。
   真令牌是 **27 字符**（`dt-` + 24）。所以用 `Bearer ` / 引号做**锚点加权**（100 / 20 / 1），
   裸串再套一道**长度闸门**（< 27 直接丢）。
2. 只扫**匿名段 / 堆段**（令牌是运行期堆字符串），跳过 `.so` 与可执行映射，快一个量级。

### 3.3 多账号隔离

靠 **`QODER_CONFIG_DIR`** 指向每账号独立目录即可完整隔离（连 `.auth` 凭据一起隔离）：

```
/opt/qoder-signin/accounts/<账号名>/
├── .auth/user            ← 凭据（加密 base64，服务器侧不可读）
├── umid-cache.json       ← 机器身份（明文：machineCode / machineToken / machineType）
├── .dt-token             ← 令牌缓存（600）
└── ...                   ← 日志、模型、插件等
```

每账号的资源是分开的，靠 `run.sh <账号名>` 串起来：

| 资源 | 路径 |
|---|---|
| 配置目录 | `/opt/qoder-signin/accounts/<账号名>` |
| 账号配置 | `/etc/qoder-signin/accounts/<账号名>.env`（600） |
| 锁文件 | `/run/qoder-signin/<账号名>.lock`（**不分开会互相阻塞**） |
| 日志 | `/var/log/qoder-signin/<账号名>.log` |
| tmux 会话 | `qoder-login-<账号名>`（独立 socket，避免误杀别的账号） |

> 安全防线：设了 `QODER_ACCOUNT` 之后，脚本**只认该账号落点，绝不回落全局配置**
> （防止两个账号写同一份凭据）。

### 3.4 定时窗口（重点）

活动每日 10:00 刷新、次日 09:59 截止，所以**窗口必须落在 10:00 之后**。
本项目给每个账号一个 **4 小时、互不重叠**的随机窗口：

| 账号 | 窗口 |
|---|---|
| 第 1 个 | `[10:20, 14:20)` |
| 第 2 个 | `[14:20, 18:20)` |
| 第 3 个 | `[18:20, 22:20)` |

实现方式是 systemd timer：

```ini
OnCalendar=*-*-* 10:20:00
RandomizedDelaySec=14400     # 窗口大小 = 抖动
AccuracySec=1s
Persistent=true
```

> ⚠️ **随机性绝不能放在服务进程里 `sleep`** —— 那会占用 `TimeoutStartSec=900`，超时被 SIGTERM。
> `run.sh` 里的 `QODER_JITTER_SECONDS` **只给 cron 降级路径用**，且检测到 systemd 环境
> （`INVOCATION_ID`）会自动压缩到 600 秒并告警。

这样做的目的：**避免固定钟点这个最容易从服务端日志里认出来的机器特征。**

---

## 四、文件说明

| 文件 | 作用 |
|---|---|
| `qoder_claim.py` | 主脚本：取令牌（三级降级）+ 查活动 + 领取 |
| `run.sh` | 多账号入口：`run.sh <账号名> [--dry-run\|--inspect]`，负责加锁 / 抖屏 / 调主脚本 |
| `login-cli.sh` | 生成登录授权链接并等待完成；链接 5 分钟过期，**超时自动换链**（`<账号名> [轮数] [每轮秒数]`） |
| `audit-accounts.sh` | 体检：登录态 / uid 是否重复 / 令牌缓存 / 接口可达 / **今日领没领** / **Credits 余额** / 定时窗口 |
| `precheck.sh` | systemd `ExecStartPre` 调用的诊断脚本（永不影响主流程） |
| `install.sh` | 一键部署 / 卸载 |
| `accounts.conf` | 账号清单（决定窗口分配顺序） |
| `selftest.py` | **本地**自测：令牌识别、文件完整性、shell 语法、systemd 要点、脱敏 |
| `selftest-server.sh` | **服务器**自测：账号隔离、锁文件、`set -a` 生效、反向验证 |
| `systemd/qoder-claim@.{service,timer}` | systemd 模板单元 |
| `可行性分析.md` | 技术破译过程与实测证据 |
| `协议合规核查.md` | 逐条对照服务协议/活动规则 |
| `部署记录.md` | 实际部署过程与验证结果 |

---

## 五、日常运维

### 看日志

```bash
tail -f /var/log/qoder-signin/acct1.log
journalctl -u qoder-claim@acct1.service -n 100
```

日志里会明确写出**本次令牌来自哪一级**：

```
[2026-10-15 16:31:00] [INFO] L1 缓存令牌有效
[2026-10-15 16:31:00] [INFO] 令牌来源=cache 长度=27
[2026-10-15 16:31:00] [INFO]   活动 act-20261013-847 今日已领取，跳过
[2026-10-15 16:31:00] [INFO] 结果：ok=True
```

### 看定时器

```bash
systemctl list-timers 'qoder-claim@*'
systemctl cat qoder-claim@acct1.timer
```

### 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `取不到有效令牌` | 凭据过期 / CLI 未登录 | `./login-cli.sh <账号名>` |
| `活动查询失败 HTTP 401` | 令牌失效且降级链都没取到 | 看日志里 L2/L3 的输出去定位 |
| `audit` 报**同号** | 两个账号其实是同一个人 | 用**无痕窗口**重登其中一个 |
| 内存被 OOM 杀掉 | 这台机器内存小 | `systemctl status` 看是否 OOM；CLI 单进程要 200MB+ |
| 领到了但 `replayed: true` | 当天已经领过（幂等） | 正常，无需处理 |
| `replayed: false` | **当天首次领取成功** | 正常，这是最好的结果 |
| 领取返回 200 但**余额没涨** | 需复核是不是发到了 `addOnQuota` 之外 | 看日志里 `余额：Credits 共…` 那行；再看 `/var/log/qoder-signin/<账号名>.log` |
| `今日` 列显示「可领」但显然领过了 | 顶层 `claimable` 不可信 | 看 `campaigns[]` 里 `actionType=CLAIM_BENEFIT` 那条的 `claimStatus` |
| 定时器没跑 | 窗口未到 / 未 enable | `systemctl list-timers` |

### 手动补跑

```bash
/opt/qoder-signin/run.sh acct2
```

---

## 六、添加新账号

1. 往 `accounts.conf` 追加一行账号名；
2. 重跑 `./install.sh`（**已存在的账号配置不会被覆盖**）；
3. `./login-cli.sh <新账号名>` 登录（记得**无痕窗口**）；
4. `./audit-accounts.sh` 核对 uid 不与已有账号重复。

### cron 降级路径（不用 systemd 时）

```cron
# 10:20 启动，内部随机抖动最多 4 小时
20 10 * * * /opt/qoder-signin/run.sh acct1 >> /var/log/qoder-signin/acct1.cron.log 2>&1
```

对应地在 `/etc/qoder-signin/accounts/acct1.env` 里设 `QODER_JITTER_SECONDS="14400"`。

---

## 七、卸载

```bash
./install.sh --uninstall            # 停定时器、删程序，保留账号数据
./install.sh --uninstall --purge    # 连账号数据一起删
```

---

## 八、环境要求

- Linux + systemd（cron 亦可）
- Python 3.8+（**系统解释器固定为 `/usr/bin/python3.12`**，可用 `QODER_PYTHON` 覆盖）
  - 主脚本**只用标准库**，无需 pip 安装任何包
- 官方 CLI：`curl -fsSL https://qoder.cn/install | bash` → `/root/.local/bin/qoderclicn`
- 可选：mitmproxy（只有 L3 兜底需要，`--with-proxy` 自动装）

### 内存

CLI 单进程常驻约 200MB+，加上 Python 与 tmux，**建议至少留 512MB 可用内存**。
`precheck.sh` 会在可用内存低于 400MB 时告警。

---

## 九、免责

本项目仅供**个人学习研究**。使用者需自行承担因违反服务协议而产生的一切后果
（包括但不限于 Credits 被回收、账号被封禁）。
作者不对任何直接或间接损失负责。
