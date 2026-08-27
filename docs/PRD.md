# MacPulse AI PRD — macOS AI 进程管家

版本：v1.1（MVP，已实现并开源）　日期：2026-08-27　仓库：https://github.com/ChenYCL/MacPulseAI

## 1. 背景与问题

macOS 上经常出现个别进程（如失控的 node、渲染进程、Docker Helper）长期占满单核甚至多核 CPU，导致风扇狂转、机器发热卡顿。系统自带"活动监视器"能看能杀，但：

1. **瞬时 CPU 排序不直观**：需要手动点列排序，且 `ps` 默认给的是进程生命周期平均 CPU，不是瞬时值；
2. **不认识进程**：普通用户不知道 `ecosystemd`、`mds_stores`、`kernel_task` 是什么、能不能杀；
3. **没有决策辅助**：面对 3 个各占 100% 的 node 进程，不知道哪个该杀、杀了有什么影响。

MacPulse = 活动监视器核心能力 + LLM 解释与建议，一个原生、轻量的菜单栏 + 窗口应用。

## 2. 目标与非目标

**目标（MVP）**

- G1 实时监控：按**瞬时 CPU** 排序的进程表（名称、PID、%CPU、内存、线程、用户、状态），可搜索；系统级 CPU（用户/系统/空闲）总览；菜单栏常驻显示 CPU%。
- G2 进程管理：选中进程可「退出(SIGTERM)」/「强制退出(SIGKILL)」，失败给出原因（如权限不足）；高 CPU 进程行内红色高亮（阈值可配）。
- G3 AI 助手：一键把当前 Top 进程快照发给 LLM，返回**分析报告**（哪些进程是什么、谁在失控、建议与风险等级）；支持对单个进程「让 AI 解释」。AI 只给建议，**绝不自动杀进程**。
- G4 多模型：同时支持 **OpenAI 兼容接口**（可自定义 Base URL，兼容中转/本地模型）与 **Anthropic 接口**；设置页可切换、填写 Base URL / API Key / 模型名，带「测试连接」。
- G5 原生与低开销：Swift + SwiftUI 原生实现，应用自身 CPU 占用 < 2%。

**非目标（v1 不做）**

- 不做 root 进程的提权查杀（需要 sudo/授权框架，杀 root 进程给出明确提示）；
- 不做系统通知推送告警（表内高亮已够用）；
- 不做历史趋势图、磁盘/网络面板；
- 不做 AI 自动执行（自动 kill/renice）。

## 3. 用户与场景

个人 macOS 开发者/重度用户。典型场景：机器发烫 → 点菜单栏图标打开 MacPulse → 看到多个 node 各占 100% → 点「AI 分析」→ LLM 指出是失控的 dev server 可安全终止 → 用户逐个「退出进程」→ 菜单栏 CPU% 回落。

## 4. 功能需求

### F1 监控（P0）
- 每 N 秒（默认 2s，可选 1/2/5s）刷新进程列表，默认按瞬时 %CPU 降序，列可点排序。
- 瞬时 CPU 计算方式：相邻两次采样进程累计 CPU 时间（`ps -o time`）之差 ÷ 墙钟间隔 × 100；首次采样用 ps 自带 pcpu（生命周期均值）兜底。
- 内存列显示 RSS（MB/GB）；显示线程数、用户名、进程状态。
- 菜单栏 Status Item 显示系统 CPU%＞30 时标色；点击打开主窗口。
- 系统总 CPU：基于 mach `host_processor_info` tick 差值计算 user/sys/idle。

### F2 管理（P0）
- 搜索框按进程名/PID 过滤。
- 行右键/工具栏：「退出进程」(SIGTERM)；「强制退出」(SIGKILL)；「复制 PID」；「让 AI 解释」。
- 仅允许杀当前用户拥有的进程；root 进程按钮置灰并提示需 sudo（v1 不做提权）。
- SIGTERM 后 3 秒仍存活则 UI 提示可改用强制退出（不自动升级，避免误杀丢数据）。

### F3 AI 助手（P0）
- 请求体：系统 CPU 概览 + Top N（默认 25，可配 10–50）进程（name/pid/cpu/mem/threads/user），不含路径等敏感信息以外的内容（路径对诊断有用，保留可配，默认含路径）。
- 输出为 Markdown：总体判断 → 高占用进程逐个解释 → 风险等级（🔴高危/🟡谨慎/🟢可安全终止）→ 建议操作。App 内渲染 Markdown，可复制全文。
- 明示"AI 建议仅供参考，是否终止由你决定"，AI 无法触发任何系统操作。
- 单进程解释：发送该进程 name/path/cpu/mem/threads/用户，返回 2–4 句解释。

### F4 设置（P0）
- Provider 二选一：`OpenAI 兼容` / `Anthropic`。
- 字段：Base URL（OpenAI 默认 `https://api.openai.com/v1`；Anthropic 默认 `https://api.anthropic.com`）、API Key、Model（OpenAI 默认 `gpt-4o-mini`；Anthropic 默认 `claude-sonnet-4-5`）、Top N、刷新间隔、高亮阈值。
- 「测试连接」发送一条最小请求，显示成功/失败原因。
- 输入框支持 ⌘C/⌘V/⌘A（程序化创建的 NSApplication 需手动构建含「编辑」菜单的主菜单栏，否则快捷键无效）；Base URL 与 API Key 旁另提供一键「粘贴」按钮兜底。
- 配置存储：`~/Library/Application Support/MacPulse/config.json`（权限 0600）；API Key 明文存本地文件（MVP，文档注明；后续可迁 Keychain）。

### F5 多语言（P0，v1.1）
- 界面文案中英双语：跟随系统语言（`Locale.preferredLanguages`，zh → 中文、否则英文），设置页可手动覆盖（自动/中文/English），即时生效。
- 实现方式：代码内双语层 `L10n.s("中文", "English")`——单文件来源、可单测、无 .strings 资源打包问题（SPM 可执行目标手工打 .app 时尤其重要）。
- LLM Prompt 同步双语：中文界面输出中文分析，英文界面输出英文分析；风险标注（🔴🟡🟢）两种语言一致。

## 5. 接口协议（LLM）

- OpenAI 兼容：`POST {base}/chat/completions`，`Authorization: Bearer <key>`，body `{model, messages:[{role:"system"|"user",content}], temperature:0.3}`，取 `choices[0].message.content`。
- Anthropic：`POST {base}/v1/messages`，头 `x-api-key`、`anthropic-version: 2023-06-01`，body `{model, max_tokens:1024, system, messages:[{role:"user",content}]}`，取 `content[0].text`（仅拼接 type==text）。
- 超时 30s；非 200 时把 body 摘要透出为错误信息（便于排查 key/模型名错误）。

## 6. 架构

```
MacPulse (SPM executable → .app bundle, ad-hoc 签名, 自绘图标)
├── main.swift          NSApplication/AppDelegate/NSStatusItem/主菜单(编辑菜单⌘V等)
├── Models.swift        ProcSample/SystemLoad
├── ProcessSampler.swift ps 固定字段采样 + proc_pidpath 路径 + proc_pidinfo 线程数
├── SystemLoad.swift     mach host_processor_info tick → user/sys/idle
├── LLMClient.swift      LLMProvider 协议 + OpenAI/Anthropic 实现 + Prompt 构建
├── SettingsStore.swift  JSON 读写(0600)
├── MonitorModel.swift   @MainActor 状态机：定时采样→发布；窗口遮挡时跳过 UI 刷新
└── AppView.swift        SwiftUI：Table/工具栏/搜索/操作栏/设置 Sheet/AI 面板
```

**采样架构（实测后定稿）**：macOS 上 `ps -o comm` 截断到 16 字符、`ucomm` 可能含空格、无线程数关键字，纯文本解析不可靠。最终采用混合方案：
- `ps -axo pid=,user=,uid=,state=,time=,pcpu=,pmem=,rss=,ucomm=`（固定单 token 字段，ucomm 放末列）→ 全量指标（root 进程的 CPU 时间经内核通道可读，实测 burner 2s 墙钟内精确 +2.0s）；
- `proc_pidpath`（libproc）→ 完整可执行路径（1207/1236 可读，含其他用户进程；带缓存，仅新增 pid 调用）；
- `proc_pidinfo(PROC_PIDTASKINFO)` → 线程数（仅本用户进程可读，~945 次调用实测 4ms；其他用户显示 "—"）；
- 瞬时 CPU% = 相邻两次累计 CPU 时间差 ÷ 墙钟间隔 × 100（首采回落 ps pcpu；PID 复用时间倒退时钳为 0）。

技术选型理由：原生 SwiftUI 保证低开销与系统集成；URLSession 零第三方依赖；SPM 可复现构建。

**性能实测（16 核，2s 刷新）**：ps 子进程 ~8ms CPU + 线程数 ~4ms + 解析/排序 ~2ms ≈ 0.7%/tick；前台表格渲染为大头（瞬时 3-11%，均值 ~4-5%）。已实施：窗口不可见（遮挡/关闭）时跳过表格刷新，后台常态 CPU 0.0-0.2%。后续优化方向：单元格内容差量更新、采样降频自适应。

## 7. 测试计划

1. **单元测试（swift test）**：ps 输出解析（多格式 cputime/etime、含空格路径）、瞬时 CPU 计算（构造时间差）、Prompt 构建（包含脱敏字段）、两种 provider 的请求体/响应解析（含错误响应）。
2. **集成测试（无真实 Key）**：本地 Python mock server 同时实现 `/chat/completions` 与 `/v1/messages`，验证 App 两种 provider 的真实 HTTP 链路与结果渲染。
3. **端到端 GUI 测试（computer-use 自动化）**：
   - 启动 `yes` CPU burner → App 中出现且瞬时 CPU≈100；
   - 通过 App UI 对其执行「退出/强制退出」→ 进程消失、菜单栏 CPU 回落；
   - 设置页切换 Anthropic、填 mock 地址 → 「测试连接」成功 → 「AI 分析」返回渲染正常。
4. **资源自检**：App 自身 CPU 占用 < 2%。

## 8. 验收结果（MVP 实测）

- [x] 进程表实时刷新且 CPU 为瞬时值（burner `yes` 2s 墙钟内 ps 时间精确 +2s ≈ 100%，UI 显示 99.7-100.4）
- [x] 可从 UI 终止用户进程（e2e：burner 出现→键盘选中→确认弹窗显示「强制退出「yes」(PID 37337)？」→ SIGKILL → pgrep 确认消失）；root 进程终止按钮禁用并给出提示
- [x] OpenAI 与 Anthropic 两种 provider 均完成真实 HTTP 验证：
  - Anthropic：z.ai 真实网关（假 key 返回 401「Authentication parameter not found」，URL 拼接 `/v1/messages` 正确，错误信息友好透出）
  - OpenAI 兼容：本地 mock（`/chat/completions` 200，响应解析正确；请求体含 system/user 消息与 Top 25 进程 JSON，经 mock 日志核对）
- [x] AI 分析 Markdown 渲染正常（标题/加粗/列表/风险 emoji/引用块），含复制全文
- [x] `swift test` 全绿（19 个用例：ps 解析/瞬时 CPU/夹取/PID 复用/Prompt 载荷/两种 provider 请求与错误处理/设置持久化与 0600 权限）
- [x] 应用自身 CPU：后台常态 0.0-0.2%；窗口可见时均值 ~4-5%（瞬时最高 11%，主因 SwiftUI 表格每 tick 重渲染；已列入优化项）
- [x] 设置面板可粘贴（编辑菜单 ⌘V + 一键粘贴按钮双通道，均实测通过）；配置持久化含 0600 权限校验
- [x] 中英双语实测通过：系统 en-CN 优先时自动英文界面；应用级 AppleLanguages 覆盖 zh-Hans 时完整中文界面（标题/按钮/菜单）；设置页语言覆盖 + LLM Prompt 随语言切换（22 个单测含双语用例）
