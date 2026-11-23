# 状态

更新：2026-11-23

## 现在

Mac 和 iOS 版 1.7.1（iOS 构建号 2 待上传）。
- Mac 侧栏改成筛选式（Kombai 方案 C 的样式）：顶部常驻「筛选」框（⇧⌘F 聚焦），下面是模块、类型、标签（取自标题开头的【】）、修改时间四组，后三组可收起；有筛选时侧栏下半部列出结果（按修改时间），没有筛选时进入模块仍是原来的文件树，可在标题行切到「按修改时间列出」。代码在 `Sources/SidebarFacets.swift`，筛选状态和结果在 `AppModel`（`facetKinds`、`facetTags`、`facetAge`、`filteredFiles`）。
- ⌘O「跳转到页面」（方案 B 的样式）：`Sources/QuickJump.swift`。标题命中按被链次数排序，每条显示「最常链到它的页 → 页面 → 它最常链到的页」，下面是正文提到的页；Tab 切换全部模块 / 当前模块，⌥↵ 在分屏打开。链接统计 `AppModel.linkFacts` 从搜索缓存里的 `[[ ]]` 算出。
- iPhone 首页（方案 A 的样式）：顶部横排模块切换，下面是当前模块的文件夹和页面，搜索框跳转全库。iPad 不受影响。
- 页面编辑器手感（2026-11-23）：空行和段落同高、离开行时版面不动、只含空格的行照常显示；左右键一次走一个看得见的字（隐藏的 ** ` [ ] 不再多占一次按键，光标不消失），上下键不跳行、能进表格；行首回车把标题/列表整块下推，退格跨过隐藏空行直接合并，代码块边缘的退格不再破坏围栏。
- 知识路线图（CS 模块首页 `CS/CS 路线图.acdian`）改成地铁图（Kombai 方向 R1）：Mac 上流程横排、阶段成列；只有选中节点时才画它自己的关系线；顶部搜索直接列出结果（节点 / 要点里提到 / 页面），点结果落到节点或打开页面；详情面板 380 宽，关系按「依赖 / 被依赖 / 用到 / 用在 / 相关」中性列出，不再有学习路径、图例和计数。iPhone 仍是单列布局。

## 下一步

- iPhone 新首页还没在真机上看过（需要连上并解锁 iPhone，或者上传 TestFlight）。
- 路线图网页测试 `node Tests/roadmap-tests.cjs` 已按新布局改了断言，但本机没有 Playwright，没跑。
- 页面里 18 处坏链接待用户决定怎么改。

## 注意

- 编辑器里 ⌘K 仍是编辑链接，所以跳转用 ⌘O。
- 编辑器浏览器测试 `node --test live-editor-integration-tests.cjs`（176 项）要 Playwright：本机可用 `playwright-core` 加 `chromium-headless-shell`，用 `ACDIAN_PLAYWRIGHT` 和 `PLAYWRIGHT_BROWSERS_PATH` 指过去；WebKit 也能下，App 里的行为以 WebKit 为准。
- Swift 测试编译要带上 `Sources/Roadmap.swift`；`TabTests`、`EditorSnapshotTests` 各有一处在 main 上本来就失败。
- 旧版本 App 改模块设置会写掉 `home`；旧版本保存路线图会写掉 `flows`、`topic`。
