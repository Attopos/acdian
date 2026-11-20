# 状态

更新：2026-11-20

## 现在

Mac 版 1.4.x，iOS 版纯计数构建号（1.5.0 起）。

- 新增「知识路线图」组件（`roadmap`）：一个 `.acdian` 文件存领域、节点、关系和学习状态，页面不加任何字段。画布是 `Resources/roadmap/` 里的网页（内置 d3，不联网），只发改动；写文件全在 `AppModel.saveRoadmap`，按条目的 `updated` 合并。
- 能看、能学、能编：固定网格布局（领域成片、从左到右由浅入深），三种关系线，远中近三档语义缩放，聚焦点亮前置链，详情面板（摘要、原理图、要点跳到小节、学习路径、状态），搜索，小地图；编辑模式可拖动、连线（成环拒绝）、新建节点、挂页面、撤销。
- 模块可设 `home`（`.acdian-modules.json`），用组件代替模块首页；CS 模块的首页是 `CS/CS 路线图.acdian`。页面改名、移动后节点里的页面路径跟着改。
- 之前的编辑体验（查找替换、块把手、表格、评论永不丢失等）不变。

## 下一步

- iOS：`.acdian` 路线图文件目前仍按卡片索引打开，要加 `iOS/RoadmapScreen.swift`；页面面包屑里加「在路线图中的位置」反向入口（`focus` 消息网页端已支持）。
- 路线图里 13 个「待写」节点等对应页面写出来后挂上；页面里 18 处指向旧标题的坏链接待用户决定怎么改（清单在 2026-11-20 的 TESTING 记录）。
- 之前遗留：在 App 里试评论跟随改名；飞书对标剩余项（见 DECISIONS 2026-11-15）。

## 注意

- 所有 Swift 测试的编译命令都要带上 `Sources/Roadmap.swift`（`AppModel.swift` 用到它）。
- 旧版本 App 改模块设置时会把 `home` 字段写掉；iOS 更新前不要在 iOS 上改模块。
- `Tests/TabTests.swift` 在“Saving over the outside change is refused as a conflict”处失败，892fe98 起就这样。
- 离屏测试窗口没有键盘焦点、不跑 requestAnimationFrame；WebKit 测试要模拟焦点、手动摆浮层。
