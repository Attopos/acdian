# ACdian 1.4.0

黑粉配色的本地 Mac Markdown 阅读器与实时编辑器。

## 使用

将 `ACdian.app` 放入“应用程序”后双击打开，也可从 Spotlight 搜索 ACdian 启动，无需从工程目录或命令文件打开。当前这台 Mac 已安装到 `/Applications/ACdian.app`。
ACdian 自动准备本地页面的保存位置，打开后即可使用，无需选择文件夹。已有页面沿用原保存位置；启动和升级不会移动或删除原 Markdown、图片和 PDF。
启动后主区域留空；从侧栏 Pages（页面）选择内容，或按 ⌘N 开始新页面。
需要 Apple Silicon Mac，macOS 14 或更新版本。当前本机安装使用有效的本地签名；向其他 Mac 分发时可使用 Developer ID 签名与 Apple 公证。

- 点击正文直接编辑，无需切换模式。
- 侧栏左下角齿轮打开设置：图标可选粉底黑字（默认）或黑底粉字，Dock 与 Finder 图标随之更换；语言可切换 English、Español、简体中文，默认英语，自动记住选择；外观可选跟随系统、浅色或深色。隐藏侧栏后，语言图标仍可从底部状态栏访问。
- 拖动侧栏右边缘可调整宽度（200–420，双击恢复默认），宽度会被记住。正文始终在整个窗口的水平正中，不随侧栏、目录或右侧评论栏移动；窗口太窄放不下时贴近侧栏。侧栏顶部不再常驻搜索框，按 ⌘F 时才出现，Esc 或清空后收起。
- 标题、粗体、斜体、引用、链接、代码块和表格在光标进入或选中时保持排版，Markdown 标记持续隐藏；Markdown 分隔空行不再额外占一行；正文连续排列，标题仅保留轻微留白。
- 输入 `* `、`- ` 自动显示项目符号；回车续写，空项目再回车退出。
- 输入 `--- ` 即时显示分割线；选中后仍显示分割线，按删除键可移除。
- 在行首输入 `/` 打开插入菜单，支持文本、一至四级标题、引用、待办、有序／无序列表、代码块、提示块、表格、分割线（插入 `--- `，上一行有字时自动先空一行）和图片；可输入中英文关键词搜索，用方向键选择，回车或 Tab 插入，Esc 关闭。菜单仅显示图标与元素名称。
- 标题、粗体、斜体、任务、图片等随输入显示。表格直接点击单元格编辑，Tab／⇧Tab 切换单元格；末格 Tab 或回车新增行。
- 新建表格：输入 `/表格`（或 `/table`），菜单旁出现 8×8 网格，指针移上去选行列数，点击插入；直接回车插入 3×3。第一行是表头，光标停在第一格。指针放在表格上时，下方和右侧出现 + 条，点击加一行或一列；所在行的左侧、所在列的上方出现小把手，拖动把手可调整行列顺序（粉色线标出落点，表头固定在第一行），点击后选“删除行”或“删除列”（删表头时下一行变成表头，删掉最后一行或一列时整张表删除，⌘Z 可撤销）。
- 块拖动（仿飞书）：指针停在任意段落、标题、代码块、引用／提示块、分割线、表格或列表项的高度时，正文左侧出现 ⋮⋮ 把手。拖动把手移动整个块，粉色线标出落点，靠近窗口上下边缘时自动滚动；子列表跟着所在的列表项一起移动。点击把手打开块菜单：转换为文本、标题、引用、待办、列表、代码块、提示块，在下方添加，复制，删除。块之间的空行自动整理，不会把段落并进列表或把上一行变成标题。
- 页内查找替换：⌘F 在当前页查找（右上角浮出查找框，显示“第几个／共几个”，↩ 下一个、⇧↩ 上一个，可区分大小写、用正则），⌥⌘F 同时打开替换；搜索全部页面改为 ⇧⌘F。
- 输入 `[[` 弹出页面列表，边打边筛选，选中后补全成 `[[页面名]]`；不同文件夹里同名的页面写成带路径的形式。
- ⌥⇧↑ / ⌥⇧↓ 把光标所在的块上移或下移一个块，光标留在原处。
- ⌘[ / ⌘] 后退、前进到上一个／下一个看过的页面（像浏览器，跨标签页；“视图”菜单里也有）。点页面链接跳过去后，⌘[ 就能回到原来的页面。列表缩进用 Tab／⇧Tab。
- 指针停在空行上时，左侧出现 +，点击在这里打开插入菜单。行中输入“空格 /”也能打开插入菜单：选标题、列表等会把这一行转成该格式，选表格、分割线、图片、折叠块会插到这一行下方。
- 粘贴网址时先原样插入，取到网页标题后自动变成 `[标题](网址)`，⌘Z 可退回原网址；选中文字再粘贴网址，会把选中的文字变成链接。
- 图片说明：单独一行的图片下方，指针移上去出现“添加图片说明”，点击直接输入，回车保存（写成 `![[图|宽度|说明]]` 或 `![说明|宽度](图)`）。
- 折叠块：`/折叠块` 插入一个可展开收起的块（`> [!toggle] 标题`，下面的 `> ` 行是内容），点左侧箭头展开或收起；写成 `[!toggle]-` 时默认收起。
- 单击链接直接打开：页面链接在 ACdian 里打开，网址用系统默认浏览器打开；裸网址（`https://…`、`www.…`）和 `<https://…>` 也可以点。选中文字时单击不跳转，⌘点击总是打开。
- 新建页面：⌘N 直接打开空白页面，不再弹出命名窗口。标题处显示淡色 `New Page` 占位，点击即可填写标题，下方直接输入正文。
- 打开页面会在新标签页中显示，不关闭已打开的页面；已打开的页面直接切换到它的标签页。⌘W 或标签右侧 × 关闭标签页。重新打开 ACdian 时恢复上次未关闭的标签页并停留在上次的页面。后台标签页 30 分钟没用会自动关闭（当前标签页和分屏页面不关，关闭前已保存）。
- 切换标签页时保留各自的滚动位置、光标和撤销记录，切换即时显示。
- 输入后自动保存，短暂停止输入约半秒即写入；切换页面、关闭窗口或退出前会补存最新内容，不再询问是否保存。新页面有标题或正文后自动创建文件，空白未编辑页面不产生文件。⌘S 仍可立即保存，全文搜索用 ⌘F。
- 评论：选中文字后点浮动工具栏的评论按钮，或按 ⇧⌘M，在窗口右侧单独一栏添加评论（栏头显示评论数，» 可收起，收起后右上角按钮再展开；评论栏没有底色，正文的宽度和位置始终不变）；不选文字时为整页评论。同一处可连续追加多条，双击或点铅笔编辑，清空保存即删除；✓ 解决后可在侧栏底部找回。正文右侧放不下评论栏时改为行尾小气泡，点开浮出卡片。评论存在页面旁的隐藏文件 `.页面名.md.comments.json`，Markdown 正文不变；页面重命名、移动、进垃圾桶和恢复时随之迁移。被评论的文字删掉后评论不会消失，留在栏顶并标“原文已删除：……”，⌘Z 撤销时回到原文上，只有删掉卡片才会删除；其他程序改过页面后，按原文和上下文重新找回位置，找不到也照样保留。评论不丢的保障：每次改动前把上一版存进 `~/Library/Application Support/acdian/Comment History`（每页最近 60 版），“视图 › 恢复本页之前的评论”可找回；评论文件损坏时保留坏文件并显示最近一份完好的；iCloud 的冲突副本按条合并；在 Finder 或其他程序里改名、移动页面后，评论按文件、原文或文件名自动找回页面。
- 插入附件：工具栏回形针，或 ⇧⌘I
- 目录：正文左侧的一列长短线（越长层级越高，粉色是正在读的部分），指针移上去弹出标题列表，点击跳转；目录从不推挤正文。工具栏列表按钮或 ⇧⌘L 显示／隐藏。
- 正文栏最宽 840（含左右各 58 留白）。
- 链接：选中文字后点浮动工具栏的 🔗（或 ⌘K）添加链接。选中带链接的文字（包括 `[[页面]]`）时 🔗 亮起，再点一次取消链接、保留文字；⌘K 编辑链接地址。
- 右键和长按不弹出 Apple 自带的菜单（Mac 编辑器、分屏、阅读页、交互块、PDF；iPhone／iPad 不显示系统编辑气泡）。图片右键菜单和侧栏菜单是 ACdian 自己的，照常可用。
- 右键侧栏中的文件或文件夹可移到应用内垃圾桶。打开侧栏“垃圾桶”，可在删除后 15 天内恢复。ACdian 运行时会自动彻底删除到期内容；关闭期间到期的内容，会在下次打开时清理。恢复时若原位置已有同名内容，会添加编号，避免覆盖。
- 刷新页面：⌘R
- PDF：点击文件或页面里的 PDF 链接；在窗口内翻页和缩放。

直接读写原始 UTF-8 Markdown，标题与正文均自动保存。保存不会中断光标、中文输入或撤销记录。
保存前检查磁盘内容，发现外部修改则拒绝覆盖，可在右上角菜单重新载入。
隐藏的配置目录不显示。非 Markdown、图片、PDF 文件可用系统默认应用打开。
支持常用 Markdown/GFM、Wiki 双向链接、图片嵌入、表格、提示块、高亮和块公式；不运行外部插件、Dataview 或 Mermaid。

页面文件夹可以放在 iCloud 里：所有写入都经过 NSFileCoordinator；还没下载的页面仍以真名显示，打开时状态栏显示下载中，搜索先跳过读不到的正文；只要有页面读不到，就不判定附件没被引用；垃圾桶到期的内容在 iCloud 同步完成前不会删除。iCloud 文件夹存在时，设置里出现“移到 iCloud”：复制整个页面文件夹（含隐藏文件和垃圾桶），逐个校验 SHA-256，再切换到 iCloud 里的这份。原文件夹原样保留作为备份，路径显示在设置里；目标文件夹不是空的就拒绝。

## 构建

安装 Xcode Command Line Tools 后，在本目录执行 `./build.sh`。
不需要网络，渲染依赖与字体均已包含，许可证在 `Resources/vendor`。路线图的图标取自开源的 Lucide（ISC 许可）。
压缩包写入本目录的 `dist`（可用 `ACDIAN_OUTPUT_DIR` 指定），可直接打开的 `ACdian.app` 位于 `/private/tmp/acdian-build-<UID>`，每次构建都会覆盖。

安装到本机请执行 `./install.sh`：构建后退出正在运行的 ACdian，用新版替换 `/Applications/ACdian.app`，再重新打开，然后删除 `/private/tmp/acdian-build-<UID>` 构建目录并打印剩余磁盘空间（Swift 模块缓存保留，以加快下次构建）。本机只保留这一份，不留旧版本和备份；旧版本可从 git 重新构建。

## iPhone 与 iPad

`iOS/` 是只读阅读器（iPhone 与 iPad 同一个应用，iOS 17+），和 Mac 共用 `Sources/` 里的六个核心文件和 `Resources/` 里的网页编辑器。页面来自 iCloud Drive 的 ACdian 文件夹（Mac 上是 `~/Library/Mobile Documents/iCloud~com~acdian~reader/Documents`）；iCloud 不可用时显示应用自己的 Documents 文件夹。应用不会写入、移动或删除页面文件夹里的任何内容。

iPad 上可以编辑（iPhone 仍然只读）：同一个网页编辑器，自动保存，切到后台时补存；侧栏新建页面、重命名、移动、移到垃圾桶和恢复；键盘上方有格式按钮；可从“照片”或“文件”插入附件。和 Mac 共用 `Sources/AppModel.swift`，系统相关的部分在 `PlatformServices` 后面。另一台设备同时改过的页面在保存时三方合并，冲突的段落两边都保留在提示块里。触屏专用的输入修正在 `Resources/touch-input.js`，只在 iOS 应用里启用：拼音等输入法组词、智能破折号、系统撤销手势。

iPad 编辑的界面测试：在 iPad 模拟器里把 fixtures 副本放进应用的 Documents，以 `--local-pages` 启动，运行 `ACdianUITests/EditorTour`。触屏输入的单元测试：`npx esbuild Tests/touch-input-tests.mjs --bundle --platform=node --format=esm --outfile=.build/touch-input-tests.mjs && node .build/touch-input-tests.mjs`。

需要完整的 Xcode 和 `xcodegen`（`brew install xcodegen`）。`./ios-build.sh` 构建并安装到所有已连接、已解锁的 iPhone 和 iPad；`--simulator` 改为构建模拟器版（不安装）；`--keep` 保留构建结果（比如要跑界面测试），用完运行 `./ios-build.sh clean`。不加 `--keep` 时，脚本无论成功、失败还是被 Ctrl-C 中断都会清理：关掉所有模拟器、退出 Simulator，删除 `/private/tmp/acdian-ios-build-*`、`/private/tmp/acdian-ios-phone-*`、生成的 `ACdian.xcodeproj` 和本项目的 DerivedData，最后打印剩余磁盘空间。模拟器系统和设备、页面文件夹都不会动。工程文件由 `project.yml` 生成，不提交。Mac 版仍由 `build.sh` 构建，不依赖这个工程。

## 模块

页面文件夹里的每个顶层文件夹是一个模块，像启动台里的应用一样以圆角图标显示。侧栏顶部常驻一排不带文字的模块图标（像浏览器里固定的网站）：指针停留显示名称，点击进入该模块，当前模块的图标提亮，再点一次回到所有模块（首页侧栏只显示模块图标）；拖动图标调整顺序，把页面或文件夹拖到图标上可移进该模块，最后一格“+”新建模块。没有打开页面时主区域显示所有模块；点开模块后，侧栏、搜索和 ⌘N 新页面都只在该文件夹内。右键模块可编辑名称、图标和颜色，隐藏或从启动台移除（文件夹保留），或删除模块：文件夹和其中的页面移到垃圾桶，15 天内恢复后模块随之回来（Attachments 模块不能删除）。点“新建模块”新建。模块列表保存在页面文件夹的 `.acdian-modules.json`。

Attachments 模块集中显示所有图片和视频及其引用页面。在页面中删掉图片或视频后，若没有其他页面引用，10 秒后自动移到垃圾桶（保留 15 天）；重新写入同名链接会自动恢复。

## 知识路线图

组件市场里的「知识路线图」把一个文件夹里的页面连成一张图：每个阶段一幅示意图，下面的知识点是图标，流程里的阶段用箭头相连。悬停图标看名称，放大后图标下显示名称；单击选中，画出它直接相关的关系线并打开详情（一句话摘要、原理图、要点、页面），双击打开页面，要点跳到对应小节；⌘F 搜索，⌘0 适合窗口。「编辑」里可以拖动节点、从节点右侧的圆点拉线、双击空白新建节点、把未挂靠的页面拖到节点上，⌘Z 撤销。节点的 `glyph` 字段填 Lucide 图标名。数据全在那个 `.acdian` 文件里，页面本身不改。在 `.acdian-modules.json` 给模块加 `"home": "<组件文件路径>"`，模块首页就换成这张图。

## 验证

路线图验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/RoadmapTests.swift -o .build/roadmap-tests
.build/roadmap-tests
node Tests/roadmap-tests.cjs
```

核心测试：

```sh
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift CoreTests.swift -o .build/core-tests
.build/core-tests
```

编辑器源码重建：`npm ci`，然后 `npm run build:editor`。仅重建编辑器时需要 Node.js 22+ 和 npm；运行应用不需要。

编辑器测试：`npm ci && npm run test:editor`。
真实浏览器测试：另行安装 `playwright` 并下载 Chromium，再运行 `npm run test:browser`；也可用 `ACDIAN_PLAYWRIGHT` 与 `ACDIAN_BROWSER_EXECUTABLE` 指定已有测试环境。

原生快照测试：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/EditorSnapshotTests.swift -o .build/snapshot-tests
.build/snapshot-tests
```

评论不丢失（历史版本、坏文件、找回改名移动的页面、恢复）验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/PageTrash.swift Tests/CommentSafetyTests.swift -o .build/comment-safety-tests
.build/comment-safety-tests
```

iCloud 同步（未下载的页面、等待的清理、移到 iCloud）验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/CloudSyncTests.swift -o .build/cloud-sync-tests
.build/cloud-sync-tests
```

新页面与首次自动保存验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/NewPageTests.swift -o .build/new-page-tests
.build/new-page-tests
```

输入后自动保存与退出补存验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/AutosaveTests.swift -o .build/autosave-tests
.build/autosave-tests
```

自动保存位置与旧页面原位沿用验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/PagesStorageTests.swift -o .build/pages-storage-tests
.build/pages-storage-tests
```

语言偏好与编辑状态验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/LocalizationTests.swift -o .build/localization-tests
.build/localization-tests
```

垃圾桶保留期限、恢复与页面删除验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/PageTrash.swift Tests/PageTrashTests.swift -o .build/page-trash-tests
.build/page-trash-tests
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/TrashModelTests.swift -o .build/trash-model-tests
.build/trash-model-tests
```

侧栏拖动排序与移动验证（顺序保存在页面根目录的隐藏文件 `.acdian-order.json`）：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/PageOrderTests.swift -o .build/page-order-tests
.build/page-order-tests
```

侧栏新建文件夹与重命名的原地改名框验证（离屏窗口，临时页面，独立偏好；需要图形会话；设置 `ACDIAN_SNAPSHOT=路径.png` 可保存改名状态截图）：

```sh
sed 's/^@main struct AcdianApp/struct AcdianApp/' Sources/AcdianApp.swift > .build/AcdianApp-nomain.swift
mkdir -p .build/new-folder-tests
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/NewFolderFieldTests.swift -o .build/new-folder-tests/new-folder-tests
.build/new-folder-tests/new-folder-tests
```

标签页与真实 WebKit 编辑器验证（离屏窗口，临时页面，独立偏好；需要图形会话）：

```sh
sed 's/^@main struct AcdianApp/struct AcdianApp/' Sources/AcdianApp.swift > .build/AcdianApp-nomain.swift
mkdir -p .build/editor-tab-tests && cp -R Resources/. .build/editor-tab-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/EditorTabTests.swift -o .build/editor-tab-tests/editor-tab-tests
.build/editor-tab-tests/editor-tab-tests
```

交互动画块验证（`acdian-interactive`，离屏窗口，临时页面；`ACDIAN_DEMO=页面.md` 另存该页截图到 `ACDIAN_SNAPSHOT`）：

```sh
mkdir -p .build/interactive-tests && cp -R Resources/. .build/interactive-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/InteractiveBlockTests.swift -o .build/interactive-tests/interactive-tests
.build/interactive-tests/interactive-tests
```

插入图片验证（粘贴、拖入的存储与链接；第二组在真实 WebKit 编辑器里粘贴和拖放，会临时使用并恢复系统剪贴板）：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Sources/AttachmentPasteboard.swift Tests/AttachmentInsertTests.swift -o .build/attachment-insert-tests
.build/attachment-insert-tests
mkdir -p .build/image-tests && cp -R Resources/. .build/image-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/ImageInsertWebKitTests.swift -o .build/image-tests/image-tests
.build/image-tests/image-tests
```

分屏验证（右键“在分屏中打开”后的第二个编辑器：自动保存、左右互换后两栏等宽且标签栏对齐、分屏内链接、移入主编辑器、改名跟随与关闭；离屏窗口，临时页面；可传一个文件夹保存截图）：

```sh
sed 's/^@main struct AcdianApp/struct AcdianApp/' Sources/AcdianApp.swift > .build/AcdianApp-nomain.swift
mkdir -p .build/split-tests && cp -R Resources/. .build/split-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/SplitViewTests.swift -o .build/split-tests/split-tests
.build/split-tests/split-tests
```

富文本渲染验证（跨行公式、不配对的 $$、行内 HTML、代码高亮、Mermaid、HTML 块、Callout、折叠、脚注；离屏窗口，临时页面；传一篇笔记的路径则只报告它的公式和错误）：

```sh
sed 's/^@main struct AcdianApp/struct AcdianApp/' Sources/AcdianApp.swift > .build/AcdianApp-nomain.swift
mkdir -p .build/rich-tests && cp -R Resources/. .build/rich-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/RichTextTests.swift -o .build/rich-tests/rich-tests
.build/rich-tests/rich-tests
```

链接按钮验证（真实 WebKit，离屏窗口，临时页面：🔗 亮起、再点取消链接并保存、右键不弹系统菜单；远程会话里离屏窗口拿不到键盘焦点，测试会模拟焦点）：

```sh
sed 's/^@main struct AcdianApp/struct AcdianApp/' Sources/AcdianApp.swift > .build/AcdianApp-nomain.swift
mkdir -p .build/link-tests && cp -R Resources/. .build/link-tests/
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache -target arm64-apple-macos14.0 $(ls Sources/*.swift | grep -v AcdianApp) .build/AcdianApp-nomain.swift Tests/LinkToolbarTests.swift -o .build/link-tests/link-tests
.build/link-tests/link-tests
```

版面和换行检查（`Tests/LayoutAudit.swift`：11 种窗口尺寸，配合侧栏、目录、分屏开关，检查标题和正文是否对齐居中；`Tests/WrapAudit.swift <文件夹>`：把一个文件夹里的文字按 10 种宽度排版，报告标点落单、单词被切开和超出版心；只读）。编译方式同上，把测试文件和资源目录换成对应的即可。

模块与附件清理验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Sources/Modules.swift Sources/Components.swift Sources/Roadmap.swift Tests/ModuleTests.swift -o .build/module-tests
.build/module-tests
```

模块界面截图：同样方式用 `Tests/ModuleSnapshot.swift` 构建，运行 `module-snapshot <页面文件夹副本> <输出文件夹> [zh-Hans]`。

打开与切换耗时：同样方式用 `Tests/TabSwitchBenchmark.swift` 构建（加 `-O -D ACDIAN_HOST`）；去掉 `-D ACDIAN_HOST` 可对照 1.2.8 源码测量。

侧栏拖动耗时：同 `Tests/SplitViewTests.swift` 的方式（加 `-O`）构建 `Tests/DragMoveBenchmark.swift`，运行 `drag-move-benchmark <页面文件夹副本> <模块> <页面或文件夹> <目标文件夹> [open]`，会来回移动多次，请用副本。

测试通过独立的 `Fixtures/Vault` 或临时页面目录运行，不修改个人页面或保存偏好。

## 备份

`Backup` 是 iCloud 页面文件夹的完整副本，删除也会同步过去。`scripts/backup-sync.py` 负责同步：被删掉或被覆盖的旧文件先移到 `Backup-deleted/<日期>`，保留 7 天后清除。遇到以下情况会停下，不做任何改动：iCloud 文件夹看起来是空的或没挂载；有页面还只在 iCloud 里、下载不下来；要删的文件超过备份的 5%。加 `--dry-run` 只列出将要做的改动。目前需要手动运行，还没有设成每天自动运行。
