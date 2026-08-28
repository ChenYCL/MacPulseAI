# 技能文件

放一个 `.json` 在这里，用选择台底栏「技能 · SKILLS」里的**导入**按钮选中它即可。

```json
{
  "id": "唯一 id，会变成磁盘上的文件名",
  "name": "按钮上显示的短名（≤24 字）",
  "detail": "悬停提示（≤160 字）",
  "icon": "SF Symbol 名，认不出来会退回 sparkles",
  "pane": "status | clean | software | optimize | analyze | security；留空 = 每一界都出现",
  "prompt": "点这个按钮时发给模型的话（≤4000 字）"
}
```

单个对象或一个数组都收。导入后落盘在 `~/Library/Application Support/MacPulse/Skills/`，
在技能上右键可以移除（进废纸篓）。

**技能只是一段提示词。** 导入技能不会、也不能让它自己执行任何操作——它唯一能做的是把这段话
连同本界上下文发给模型。模型之后提议的终止 / 清理 / shell 动作，仍旧逐条走人工确认卡与
ShellGuard 裁决，和你自己在对话框里打字完全一样。所以从别人那儿拿一份技能回来导入，
最坏情况是浪费一次 token。
