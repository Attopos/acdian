# acdian 1.2.7

黑粉配色的本地 Mac Markdown 阅读器与实时编辑器。

## 使用

将 `acdian.app` 放入“应用程序”后双击打开，也可从 Spotlight 搜索 acdian 启动，无需从工程目录或命令文件打开。当前这台 Mac 已安装到 `/Applications/acdian.app`。
acdian 自动准备本地页面的保存位置，打开后即可使用，无需选择文件夹。已有页面沿用原保存位置；启动和升级不会移动或删除原 Markdown、图片和 PDF。
启动后主区域留空；从侧栏 Pages（页面）选择内容，或按 ⌘N 开始新页面。
需要 Apple Silicon Mac，macOS 14 或更新版本。当前本机安装使用有效的本地签名；向其他 Mac 分发时可使用 Developer ID 签名与 Apple 公证。

- 点击正文直接编辑，无需切换模式。
- 左下角语言图标可切换 English、Español、简体中文；默认英语，自动记住选择。隐藏侧栏后，图标仍可从底部状态栏访问。界面和插入菜单立即更新。
- 标题、粗体、斜体、引用、链接、代码块和表格在光标进入或选中时保持排版，Markdown 标记持续隐藏；Markdown 分隔空行不再额外占一行；正文连续排列，标题仅保留轻微留白。
- 输入 `* `、`- ` 自动显示项目符号；回车续写，空项目再回车退出。
- 输入 `--- ` 即时显示分割线；选中后仍显示分割线，按删除键可移除。
- 在行首输入 `/` 打开插入菜单，支持文本、一至四级标题、引用、待办、有序／无序列表、代码块和提示块；可输入中英文关键词搜索，用方向键选择，回车或 Tab 插入，Esc 关闭。菜单仅显示图标与元素名称。
- 标题、粗体、斜体、任务、图片等随输入显示。表格直接点击单元格编辑，Tab／⇧Tab 切换单元格；末格 Tab 或回车新增行。
- ⌘点击内部或外部链接可打开；普通点击进入编辑。
- 新建页面：⌘N 直接打开空白页面，不再弹出命名窗口。标题处显示淡色 `New Page` 占位，点击即可填写标题，下方直接输入正文。
- 输入后自动保存，短暂停止输入约半秒即写入；切换页面、关闭窗口或退出前会补存最新内容，不再询问是否保存。新页面有标题或正文后自动创建文件，空白未编辑页面不产生文件。⌘S 仍可立即保存，全文搜索用 ⌘F。
- 插入附件：工具栏回形针，或 ⇧⌘I
- 目录：工具栏列表按钮，或 ⇧⌘L
- 右键侧栏中的文件或文件夹可移到应用内垃圾桶。打开侧栏“垃圾桶”，可在删除后 15 天内恢复。acdian 运行时会自动彻底删除到期内容；关闭期间到期的内容，会在下次打开时清理。恢复时若原位置已有同名内容，会添加编号，避免覆盖。
- 刷新页面：⌘R
- PDF：点击文件或页面里的 PDF 链接；在窗口内翻页和缩放。

直接读写原始 UTF-8 Markdown，标题与正文均自动保存。保存不会中断光标、中文输入或撤销记录。
保存前检查磁盘内容，发现外部修改则拒绝覆盖，可在右上角菜单重新载入。
隐藏的配置目录不显示。非 Markdown、图片、PDF 文件可用系统默认应用打开。
支持常用 Markdown/GFM、Wiki 双向链接、图片嵌入、表格、提示块、高亮和块公式；不运行外部插件、Dataview 或 Mermaid。

## 构建

安装 Xcode Command Line Tools 后，在本目录执行 `./build.sh`。
不需要网络，渲染依赖与字体均已包含，许可证在 `Resources/vendor`。
产物写入本目录的 `dist`（可用 `ACDIAN_OUTPUT_DIR` 指定），临时签名的构建缓存位于 `/private/tmp/acdian-build-<UID>`。

## 验证

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
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/EditorSnapshotTests.swift -o .build/snapshot-tests
.build/snapshot-tests
```

新页面与首次自动保存验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/NewPageTests.swift -o .build/new-page-tests
.build/new-page-tests
```

输入后自动保存与退出补存验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/AutosaveTests.swift -o .build/autosave-tests
.build/autosave-tests
```

自动保存位置与旧页面原位沿用验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/PagesStorageTests.swift -o .build/pages-storage-tests
.build/pages-storage-tests
```

语言偏好与编辑状态验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/LocalizationTests.swift -o .build/localization-tests
.build/localization-tests
```

垃圾桶保留期限、恢复与页面删除验证：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/PageTrash.swift Tests/PageTrashTests.swift -o .build/page-trash-tests
.build/page-trash-tests
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/TrashModelTests.swift -o .build/trash-model-tests
.build/trash-model-tests
```

侧栏拖动排序与移动验证（顺序保存在页面根目录的隐藏文件 `.acdian-order.json`）：

```sh
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/VaultCore.swift Sources/Localization.swift Sources/PagesStorage.swift Sources/PageTrash.swift Sources/AppModel.swift Tests/PageOrderTests.swift -o .build/page-order-tests
.build/page-order-tests
```

测试通过独立的 `Fixtures/Vault` 或临时页面目录运行，不修改个人页面或保存偏好。
