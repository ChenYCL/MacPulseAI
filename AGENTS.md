# AGENTS.md — MacPulse AI 开发指南

给后续接手的人（和 AI agent）看的。读完这份再动代码，能省掉大部分「为什么它长这样」的往返。

---

## 1. 这是什么

原生 macOS 系统管理工具（Swift + SwiftUI，**零第三方依赖**），把活动监视器 / 清理 / 卸载 / 磁盘分析 / 安全体检合在一个应用里，并内置一个 AI Agent。

```
main.swift            NSApplication 启动、菜单栏 HUD、--pane 启动参数
AppView.swift         主视图：选择台 ↔ 工作台两种模式、六界路由、装备槽、状态页读数
CharacterSelect.swift 选择台（星轨 + 神兽 + 铭牌 + 底栏）
HeaderView.swift      顶栏（品牌 / 胶囊分段导航 / 读数簇）
Theme.swift           设计系统：Studio token + 通用控件 + 五行主题
MythChrome.swift      背景（含实时遥测层）、素材加载与降采样缓存
ProcessTable.swift    进程表（Equatable，独立于 AppView 重绘）
SkillStore.swift      技能：内置 + 用户导入
Clean/Software/Optimize/Analyze/SecurityView.swift   五个工作页
ChatSession / LLMClient / AgentAction / ShellGuard / SafetyGuard   AI 与安全闸门
```

---

## 2. 三条不能破的原则

### 2.1 安全：没有静默的破坏性操作

- **删除一律进废纸篓**，代码里不存在物理删除通道。新增删除路径必须走 `trashItem`。
- 所有破坏性操作（删除 / 清理 / 维护 / 终止 / shell）执行前过 `SafetyGuard`：路径黑名单、运行中占用保护、规模异常需人工确认，并写审计日志。
- AI 提议的动作 **一律是 HITL 确认卡**，用户点了才执行。模型不能绕过这层。
- shell 命令过 `ShellGuard`：只读命令自动执行并回灌输出，写操作需确认，危险命令硬拦截。
- **技能（Skill）只是提示词**。导入一个 `.json` 不会、也不能让它自己执行任何东西——它唯一能做的是「把这段话发给模型」，之后照旧走 HITL。任何想给技能加执行能力的改动，先想清楚这条边界。

### 2.2 诚实：界面不许假装

每一页都有 `safetyStatement`，事先声明「本页读什么、会改什么」，显示在工作台页眉和选择台底栏。

**能点的东西必须真的做事。** 这条是踩过坑的：早期版本的 SKILLS 是一排圆图标，长得跟旁边的真按钮一模一样，实际只有 tooltip——那是在骗点击。现在技能是带文字的真按钮，点了就发给 AI。同理，装备槽（LOADOUT）四格必须各自接到不同的实际调用，不许三格都调 `enter(pane)` 凑数。

不确定的信息要说不确定；跳过的操作要说明跳过原因（见 `OptimizeView` 的「已跳过：…」）。

### 2.3 性能：常驻应用不许空转

这是个开着不关的窗口，空闲时的每一个百分点都会被用户感知成「卡」。已经踩过的坑，别再踩回去：

| 反模式 | 代价 | 正确做法 |
|---|---|---|
| `TimelineView` 驱动 idle 动画 | 每帧重跑整棵子树，11–20% CPU | 隐式 `repeatForever` 动画，渲染服务插值，body 不重跑 |
| 根节点 `.animation(value:)` | 切页时把上千行表格 + Markdown 一起做补间，卡顿 + 残影 | 切页瞬时；动画只挂在真正需要的小范围 |
| 排序/过滤写在 `AppView.body` | 任一 `@Published` 变化都重排上千个进程 | 拆成 `Equatable` 子视图（见 `ProcessTable`） |
| 直接把原图喂给小尺寸视图 | 每帧重采样 900px 大图 | `MythAsset.image(_:fitting:)` 桶缓存降采样副本 |
| 不看页面就全速采样 | 每 2s fork 一次 `ps` | 表格不在屏幕上时降频（`setProcessDetailNeeded`） |

**改完 UI 一定要量**：`top -pid <pid> -l 8 -s 1 -stats cpu`。目标是空闲 0–1%，采样瞬时 ≤5%。
注意 `ps -o %cpu` 是衰减均值，刚启动时虚高，别拿它下结论。

---

## 3. 设计系统（Studio）

参考 [mole.fit](https://mole.fit) 的质感：暖白纸底 + 海军蓝墨色 + 衬线标题 + 全圆角胶囊。
**所有颜色、圆角、字体走 `Studio` token，不要硬编码。**

```swift
Studio.canvasTop/Mid/Bottom   暖白背景纸（不是冷灰）
Studio.surface / surfaceMuted / surfaceSunken
Studio.hairline / hairlineStrong
Studio.ink / inkSecondary / inkTertiary   海军蓝墨，不是纯黑
Studio.accent                             中性强调（导航、非行色场合）
Studio.radiusPanel 22 / radiusCard 20 / radiusSlot 14 / radiusChip 胶囊
Studio.display(_:)  New York 衬线，标题用
Studio.figure(_:)   衬线 + 等宽数字，大读数用
Studio.microLabel(_:)  全大写微标 + 大字距
```

现成控件：`StudioPanel`、`StudioButtonStyle`（primary/secondary/quiet/danger，全胶囊）、
`SlotButton`、`SkillChip`、`StatReadout`、`MetricCard`、`SectionLabel`、`BeastAvatar`。
**先找有没有现成的再写新的。**

### 五行主题

六界各配一位守护神兽，行色只做点缀（圆点 / 细条 / 小标签 / 主按钮），不做大面积底色：

| 界 | 行 | 神兽 | 资源名 |
|---|---|---|---|
| status 状态 | 火 | 朱雀 | fire |
| clean 清理 | 金 | 白虎 | metal |
| software 软件 | 木 | 青龙 | wood |
| optimize 优化 | 土 | 麒麟 | earth |
| analyze 分析 | 水 | 玄武 | water |
| security 安全 | 門 | 门神 | gate |

`theme.primary` 是**亮底上可读**的行色（不是发光色）；`secondary`/`glow` 只用于辉光；`soft` 是极淡底。

---

## 4. 界面结构

### 选择台（Roster，启动落点）

六只神兽排在一条椭圆轨道上（`OrbitRing` + `BeastFigure`）。轨道最前那只放大居中 = 当前选中的界，
左右两侧是相邻的两只；点侧边的兽、按左右箭头、或横向拖拽都能转轨。铭牌在下方给出名字 + 界别 + 四项实时读数。
底栏三段：**装备**（四个真动作）· **技能**（AI 任务，可导入）· **安全声明 + 进入/AI/设置**。

### 工作台（Workspace）

顶栏胶囊分段导航直达六界。页眉是「神兽头像 + 名 + 界别 + 安全声明 + 本页动作」，接住选择台的角色感。
右侧是可拖拽宽度的 AI 对话面板（可 Pin 常驻）。

### 背景

`StudioBackdrop` = 暖白渐变 + 行色柔光 + 暗角 + **实时遥测层**（`TelemetryLayer`：底部负载波形、
内存弧、进程密度点）。遥测画的是真数据，但刻意压到几乎看不见——它是氛围不是仪表盘，
所以没有任何刻度和标签。要读数值有顶栏和状态页。

---

## 5. 技能系统

```json
{
  "id": "port-hog",
  "name": "端口体检",
  "detail": "逐个端口说明是否该对外监听",
  "icon": "network",
  "pane": "security",
  "prompt": "逐个检查当前监听端口……"
}
```

- `pane` 为空 = 每一界都出现；非法值会被收敛成空。
- 导入走 `NSOpenPanel`（只收 `.json`），单个对象或数组都收。
- 落盘在 `~/Library/Application Support/MacPulse/Skills/`，删除进废纸篓。
- 校验在 `Skill.validated`：字段缺失 / prompt 超 4000 字 / 图标不存在 / id 带路径分隔符，都在这里被挡掉。
- 内置技能每界两个（`SkillStore.builtIn`），不可删、不写盘，和导入技能**走完全相同的执行路径**——没有隐藏能力。

---

## 6. 开发流程

```bash
swift build                     # 编译
swift test                      # 88 个单元测试，必须全绿
./scripts/build_app.sh          # 打出 build/MacPulse.app
open build/MacPulse.app

./scripts/shot.sh out.png       # 按窗口 ID 截当前窗口
./scripts/sweep.sh /tmp/shots   # 每页冷启动 + 截图（用 --pane 参数，可复现）
swift scripts/cutout.swift      # 从 art/hero-*.jpg 重新生成去背立绘
```

**截图不要用坐标点击顶栏**——窗口一挪坐标就全错，而且 `open -a` 会把窗口提到前台、可能误触发默认按钮。
用 `--pane <raw>` 启动参数落到目标页。

### 素材分层

- `art/` — 暗底原画（`hero-*.jpg`、废弃的 `bg-*.jpg`）。**不进 .app**，只是 `cutout.swift` 的输入。
- `Sources/MacPulse/Resources/` — 随包发布的：圆形徽章 `<element>.jpg`、去背立绘 `char-*.png`、菜单栏图标。

有个测试（`testMythAssetMissAndHitAreStable`）会反向断言 `hero-*` **不在** bundle 里，防止有人又把原画塞回去。

---

## 7. 已知的坑

- `AppView.body` 会被任何一个 `@Published` 拖着重跑。往里加计算前先想：这东西该不该拆成 Equatable 子视图。
- SwiftUI `Button` + `.buttonStyle(.plain)` + 自定义 label **不会**自动暴露辅助功能名，必须显式 `.accessibilityLabel`。
- `GeometryReader` 没有固有尺寸。放进 `HStack` 和另一个弹性视图抢空间时会被吃光——要显式给宽度。
- 半透明卡片叠在一起会把后面那张的文字透到前面来。要「融进场景」用柔和描边和接地投影，不要用透明度。
- 程序化创建的 `NSApplication` 没有主菜单，`⌘C/⌘V` 会失效——`setupMainMenu()` 是必需的，别删。
- `NSStatusItem` 左键弹 HUD、右键弹菜单：不要挂 `item.menu`，否则左键会被菜单抢走。
- SSE 的 `finalize()` **必须先判 stopReason 再判有没有正文**。写成 `if !text.isEmpty { return text }`
  打头的话，只要模型吐过一个字，截断判定和流中错误判定就永远够不着——被 max_tokens 砍在半句的
  回答会被当成完整答案交出去，不报错也不重试。已有回归测试
  （`testTruncatedAfterPartialTextRetriesWithLargerBudget`）钉住这个顺序。
- 流式重试前必须调 `onReset` 让调用方清空占位消息，否则第二轮的增量会接在第一轮后面变成重复。
- `.onChange(of:)` **对视图诞生时就带着的值不触发**。深链（如 SecurityView 的 `Request`）
  必须 `onAppear` + `onChange` 双管：`enter(pane)` 和 `request = ...` 是同一次 SwiftUI 更新，
  目标视图是「带着请求被创建出来」的。只挂 onChange = 那个入口是死的。
- `ForEach` 的元素别用 `let id = UUID()`。这些结构每次 body 都重建，UUID 会让 SwiftUI
  每拍换一批身份，把子视图连同 `@State`（悬停高亮之类）一起拆掉重建。用内容派生的稳定 id。
- `Equatable` 视图比较排序器时要比整个 `KeyPathComparator`，不能只比 `.order`——
  换列时 order 往往不变，只比 order 会把表头点击整个吞掉。
- 给 `@Published` 加字段前想清楚发布频率。一个每拍都变的数组会把周围所有
  「值没变就不发布」的守卫全部作废。需要高频数据就用非 published 缓冲 + 节流的 tick。
- 测试文件里多一个花括号，后面的 `func test` 会变成文件作用域函数，XCTest **不会报错也不会运行**。
  改完对一下 `grep -c "func test"` 和 `swift test` 报的条数——曾经有 9 个测试
  （含全部 ShellGuard 危险命令拦截）这样静默失联，掩盖了一个真 bug。

---

## 8. 提交约定

Angular 风格（`feat:` / `fix:` / `docs:` / `refactor:`）。正文写**为什么**，不要复述 diff 写了什么。
默认分支是 `main`；不要直接往 `main` 上提交，开 feature 分支再合。
