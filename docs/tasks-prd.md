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
