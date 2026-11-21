# 状态

更新：2026-11-21

## 现在

Mac 和 iOS 版 1.7.1（iOS 构建号从 1 起，TestFlight 每次上传后自动加一）。
- 「知识路线图」组件（`roadmap`，CS 模块首页 `CS/CS 路线图.acdian`）：一个 `.acdian` 文件存流程、阶段、节点和关系，页面不加字段。画布是 `Resources/roadmap/` 里的网页（内置 d3），写文件全在 `AppModel.saveRoadmap`，按条目的 `updated` 合并。
- 布局是流程图：`flows` 里每条流程一列，阶段（`domains`，带 `flow` 和顺序）自上而下排、标序号、相邻阶段画流程箭头；第一条流程占左列，其余流程叠在右列。阶段内节点按前置关系排在前面，每行四个。节点的 `topic` 记原来的知识领域，面板里作标签。
- CS 路线图分三条：一次 API 调用（客户端与网络 → 入口 → 鉴权 → 限流预扣 → 路由到上游 → 流式返回 → 结算 → 账本账单 → 日志指标压测）、构建与发布、工程方法。
- 能看、能学、能编：语义缩放、聚焦前置链、占三分之二宽、分区的详情面板、悬停看节点摘要和连线说明（高亮画在单独的浮层，拖动缩放时隐藏）、搜索、小地图；不显示学习进度；英文名为主、中文名在下对照；阶段之间的连线走侧边走廊合并成地铁线。
- iOS / iPadOS：`iOS/RoadmapScreen.swift` 用同一张网页画布（触屏模式）。iPad 走共享的 AppModel；iPhone 走 ReaderStore，只读。手机（含横屏，最短边 <500pt）和窄分屏（<700pt）是单列可滚动布局，竖屏详情在底部、横屏在右侧；iPad 竖屏详情是底部面板，横屏是右侧面板（约一半宽）；iPad 开屏直接看第一条流程。触屏上没有悬停。页面右上角有「在路线图中的位置」。
- 内置组件共用一套：网页侧 `Resources/kit/kit.js`（通信、主题、多语言），App 侧 `ComponentBridge`（Mac `ComponentWebHost`、iOS `ComponentCanvas`）。加新组件照 `docs/COMPONENTS.md`。

## 下一步

- 真机上试 iPhone / iPad 路线图（等用户连 iPhone）；Mac 版还没有「在路线图中的位置」按钮（`AppModel.showInRoadmap` 已有）。
- 待写节点等页面写出来后挂上；页面里 18 处坏链接待用户决定怎么改。
- 编辑器（`live-editor.js`，CodeMirror 打包）还用自己的 `acdianSetDocument` 等接口，以后可迁到 kit。

## 注意

- 路线图在 Mac / iPad 宽屏非编辑状态下用分块位图画（`Resources/kit/svg-raster.js`：SVG 留作数据和点击层，透明；512pt 一块，在 DOM 外画好转成图片；拖动、捏合、按钮缩放期间只挪和缩放现成图片，停下才换清晰度、切语义缩放档）；编辑和 iPhone 仍是 SVG。改 SVG 后要 `repaint()`。
- Swift 测试编译要带上 `Sources/Roadmap.swift`；`TabTests`、`EditorSnapshotTests` 各有一处在 main 上本来就失败。网页测试 `node Tests/roadmap-tests.cjs` 只在有 Playwright 的环境跑。
- 旧版本 App 改模块设置会写掉 `home`；旧版本保存路线图会写掉 `flows`、`topic`。
