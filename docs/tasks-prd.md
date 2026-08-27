# MacPulse AI v2 任务 PRD —— 对标 Mole (mole.fit) 的磁盘与维护能力

日期：2026-08-27　前置版本：v1.1（进程监控 + AI 对话 HITL，已开源 github.com/ChenYCL/MacPulseAI）

## 1. 竞品调研结论：Mole (mole.fit)

tw93 出品的 macOS 效率工具（开源 CLI `mo` + 原生 App，$19 买断 2 台机），定位替代 CleanMyMac/AppCleaner/DaisyDisk/iStat：

| 能力域 | Mole 的做法 |
|---|---|
| 磁盘清理 | 清除系统/应用**缓存与日志**；**Review-first**：先展示候选文件再删，系统自有数据交给 macOS；**删除进废纸篓**（可恢复）；支持 dry-run |
| 应用卸载 | 完整卸载 + 扫描 `~/Library`（Application Support/Caches/Preferences/Containers）**残留文件**一并清除 |
| 应用更新 | 软件页内检查并安装更新 |
| 磁盘分析 | **Treemap** 可视化磁盘占用，看清谁占了存储 |
| 系统维护 | **flush DNS 缓存**、**purge 内存/磁盘缓存** 等维护动作 |
| 系统监控 | 实时 CPU/内存状态、风扇控制 |

## 2. 差距对比（MacPulse AI vs Mole）

| 能力 | MacPulse v1.1 | Mole | 结论 |
|---|---|---|---|
| 进程瞬时 CPU 监控/查杀 | ✅ 更精细（双采样瞬时值） | ⚠️ 有 monitor | 保持优势 |
| AI 解释/对话/HITL | ✅ 独有 | ❌ | 保持优势 |
| 磁盘缓存/日志清理 | ❌ | ✅ review-first | **本轮补齐 F6** |
| 应用卸载+残留清理 | ❌ | ✅ | 规划 v2.1（F7） |
| 磁盘占用分析 | ❌ | ✅ treemap | 本轮做轻量版 F9（Top 目录统计） |
| 系统维护动作 | ❌ | ✅ DNS flush/purge | **本轮补齐 F8** |
| AI 与清理/维护联动 | ❌ | ❌（无 AI） | **独有机会：AI 建议清理并由 HITL 确认** |

## 3. 本轮任务（v2.0 范围）

### F6 磁盘管家（P0）
- 主窗口新增「磁盘」标签页：一键扫描以下**可再生的**缓存/日志类别（不碰用户文档）：
  - 应用缓存 `~/Library/Caches/*`
  - 应用日志 `~/Library/Logs/*`
  - 开发缓存：Xcode `DerivedData`、`~/.npm`、`~/.gradle/caches`
- Review-first：展示每类 Top 条目（路径+大小），总可释放量汇总；**所有删除均移入废纸篓**（可恢复）；开发缓存提供直删选项。
- 大小计算与移动均在后台线程，不阻塞 UI。

### F7 系统维护动作（P0）
- 清空废纸篓（osascript 走 Finder，带系统确认）
- 释放内存/磁盘缓存（`/usr/sbin/purge`，无需 root）
- 刷新 DNS 缓存（`dscacheutil -flushcache` + `killall -HUP mDNSResponder`，弹管理员授权框提权执行）
- 所有维护动作走统一 Runner（shell 可注入），便于测试与审计。

### F9 磁盘概况轻量版（P1 随 F6 附带）
- 磁盘页头部显示卷剩余空间与本次扫描可释放合计；不做 treemap（列入后续）。

### F10 AI 友好整合（P0，MacPulse 差异化）
- HITL 动作协议扩展：模型除 `quit/force_kill` 外可提议
  - `<action action="clean" target="app_caches|logs|dev_caches"/>`
  - `<action action="maintenance" task="purge_memory|flush_dns|empty_trash"/>`
  - 全部经既有 HITL 卡片由人确认后执行，**AI 永远不直接执行**。
- 上下文增强：实时上下文与分析载荷中加入磁盘剩余空间，使 AI 能结合"磁盘快满 + 存在 3GB 开发缓存"给出建议。
- Agent system prompt 双语更新（枚举可用动作与约束）。

### 规划到 v2.1（不在本轮）
- F7' 应用卸载器（Bundle ID 关联扫描 + 废纸篓）
- Treemap 可视化、浏览器缓存清理、 brew cleanup 集成

## 4. 非目标
- 自动化无人值守清理（违背 review-first/HITL 原则）
- 下载态浏览器缓存等高风险数据的清理
- 网络监控面板

## 5. 测试计划
- 单测：DiskCleaner 大小统计与分类扫描（临时目录注入 home）、移动至废纸篓目录的落点校验、维护 Runner 命令拼装（注入不真执行）、Agent 动作解析新增 kind、system prompt 合约、contextSummary 含磁盘信息。
- 集成/GUI：mock LLM 回复含 `<action action="clean" .../>` → 面板出现 HITL 卡片 → 确认执行 → 目标类别真实进入废纸篓。

---

## v2.1 用户声音驱动的追加任务（2026-08-27 追加）

### 用户声音收集（GitHub / Twitter / Reddit / 知乎 / CSDN）

| 痛点 | 来源 | 对应动作 |
|---|---|---|
| "Address already in use"→ lsof+grep+kill 三步太繁琐，npx kill-port 因此流行 | GitHub Gist / CSDN / Zhihu 高频 | ✅ F11 端口占用查杀标签 |
| CleanMyMac「订阅贵、终身版缩水、臃肿误删」 | Reddit r/MacOS、知乎、V2EX | 已有定位：开源免费 + review-first + HITL，写入 README |
| 风扇狂转但活动监视器"抓不到元凶"、kernel_task 占 CPU | r/osx、Apple Discussions、Medium | ✅ 瞬时 CPU 双采样 + AI 解读已在 v1；kernel_task 保护提示在 Agent prompt |
| AI 输出 Markdown 表格渲染成管道符纯文本 | 用户反馈（本仓库） | ✅ F12 MarkdownView 完整渲染 |

### F11 端口占用查杀（P0，本轮实现）
- 新「端口」标签：`lsof -nP -iTCP -sTCP:LISTEN` 扫描解析（lsof 输出可注入便于测试），支持按端口/进程/PID 过滤。
- 行内操作：终止进程（HITL 确认弹窗）、「AI 解释」复用对话解释该 PID。

### F12 Markdown 渲染（P0，本轮实现）
- 自研 `MarkdownView`：标题/无序有序列表/表格/代码块(带语言标签)/引用/分隔线/**粗体**/`行内代码`。
- 替换原先 inline-only 的 AttributedString 渲染——AI 输出的 GFM 表格此前渲染成"|进程|判断|"字面量。

### F13 Agent 工具环（P0，本轮实现）
- 协议：模型可在回复中输出 `<tool name="snapshot"/>` 请求最新实时数据；应用拦截后回填 fresh 进程/系统/磁盘摘要并让模型续答（每轮最多一次，防循环）。
- 这是受 opencode/codex 等 agent runtime 启发的最小落地：模型驱动 + 应用侧工具执行。

### F14 内存压力显示（P1，本轮实现）
- 顶部概览新增「内存 xx%」（active+wire+compressor 页 × 页大小）与「交换 xxxM/G」（sysctl vm.swapusage）chip；swap 进入 GB 区间标红。

### 探索项：外部 Agent Runtime（v3 评估中）
考虑过打包 opencode/codex 运行时作为本地 agent 引擎。v2.1 未采用的原因：
1. 我们的 HITL 安全模型要求所有副作用经应用内确认卡；引入任意 shell 执行 runtime 会破坏这一保证；
2. 二进制体积/签名/分发复杂度显著上升。
演进路线：保持应用内轻量工具环（新增只读工具如 ports/snapshot 已具备），若未来需要深度开发代理能力，评估以"外接 OpenAI 兼容 agent 服务"形式可选启用，而非捆绑分发。

---

## v2.2 安全加固与剪贴板查毒（用户安全需求追加，2026-08-27）

### 需求来源（用户原话）
"整体不要自动化 auto rm -rf 等高危操作，需要安全 hook 拦截，等人处理，并介绍发生什么问题和会做什么，避免发生惨案"；"异常扫描剪贴板、AI 查毒"；"重复软件升级历史包清理"。

### F15 SafetyGuard 安全钩子（P0，本轮实现）
- 所有破坏性操作（移入废纸篓/清理/维护/终止）执行前统一裁决：
  - **路径黑名单**：系统前缀（/System、/usr、/Library…）、敏感家目录（.ssh/.gnupg/Keychains/Documents 等）、home 本体——直接拦截；
  - **越界拦截**：清理范围限定在 home 内，卷外路径拒绝；
  - **运行中占用**：目标目录含运行中进程的可执行文件 → 需人工显式确认（AI 动作则直接跳过等人处理）；
  - **异常规模**：单次 >300 项或 >80GB → 需人工显式核对；
  - **直删通道已移除**：删除统一走废纸篓（可恢复），代码中不再存在静默物理删除入口。
- 每次裁决生成「会发生什么 / 影响 / 如何恢复」三段说明卡（如清空废纸篓明示不可恢复）。
- 审计日志：安全页展示最近 100 条裁决记录。

### F16 剪贴板安全体检 + AI 查毒（P0，本轮实现）
- 新「安全」标签：本地模式匹配识别 PEM 私钥、常见 API Key 前缀（sk-/ghp_/AKIA/xox…）、以太坊/比特币地址、超长十六进制、**高危 shell 命令**（rm -rf/dd of=/dev/curl|sh/chmod -R 777 //diskutil erase）。
- 体检全本机完成，零数据外发；发现项脱敏展示（首 6 末 4）。
- 「AI 查毒」按钮：仅点击后才把**脱敏后**内容发模型复审恶意性；密钥类替换为 [REDACTED:*]、命令保留原文供分析。
- 一键清空剪贴板。隐私说明明确：macOS 不允许应用追溯剪贴板读取者。

### F17 历史版本包清理（P0，本轮实现）
- 磁盘页新增「历史版本包」类别：扫描 CLI 工具升级残留（claude/cursor-agent/opencode 的 versions 目录、.claude/local）。
- 语义版本比较只保留最新版；**运行中占用的版本自动排除**（进程可执行路径前缀匹配）；非版本名条目不标记。

### 痛点盘点（对照用户提问"之前的痛点是否解决了"）
| 痛点 | 状态 |
|---|---|
| 端口占用查杀繁琐 | ✅ 已解决（端口标签 + HITL 终止 + AI 解释） |
| 活动监视器抓不到元凶/瞬时值误导 | ✅ 已解决（双采样瞬时 CPU + AI 解读） |
| CleanMyMac 订阅贵/臃肿/误删 | ✅ 定位差异化（开源免费 + review-first + HITL + 本轮 SafetyGuard 进一步防误删） |
| AI 输出表格渲染成纯文本 | ✅ 已解决（MarkdownView GFM 渲染） |
| 开发缓存难找难清 | ✅ 已解决（磁盘管家 + dev_caches + 历史版本包） |
| 内存压力/Swap 不可见 | ✅ 已解决（header chip） |
| 高危操作误删风险 | ✅ 本轮 SafetyGuard 钩子（废纸篓统一 + 黑名单 + 需人确认 + 审计日志） |
| 剪贴板劫持/恶意粘贴/查毒 | ✅ 本轮剪贴板体检 + AI 查毒 |
| 应用卸载器、Treemap | ⏳ v2.2 规划中（未实现，诚实标注） |
