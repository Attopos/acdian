# ACdian

黑粉配色的本地 Markdown 阅读器与实时编辑器，Mac 版加 iOS / iPadOS 版。资料库在 iCloud，每个 `.md` 是一页，顶层文件夹是模块。

开工前先读 `docs/STATE.md`（做到哪、下一步）；需要背景时读 `docs/DECISIONS.md`。功能和验证记录见 `README.md`、`TESTING.md`。

## 位置

- 源码就是本仓库（GitHub `Attopos/acdian`，分支 `main`），位于 `~/Developer/acdian/Project/work/acdian`。
- App 实际使用的资料库在 iCloud：`~/Library/Mobile Documents/iCloud~com~acdian~reader/Documents`。`~/Developer/acdian/Backup/` 是它的同步备份（`scripts/backup-sync.py` 同步，旧文件暂存在 `Backup-deleted/`），不要在那里改内容。
- 资料库的写作规范见资料库根目录的 `AGENTS.md`。

## 开发

- 改完代码直接 build 并 push，不用先问。Mac 版用 `install.sh` 构建并安装到 `/Applications/ACdian.app`。
- 不用模拟器，直接装真机测试；每次 build 或测试后立即关闭模拟器、删除构建中间文件。
- commit 和 PR 里不加 Co-Authored-By、Claude-Session 等署名行。
- 代码里尽量不写注释，除非是特别关键的功能。

## 资料库

- 文件夹名一律用英文（项目目录和资料库里都是）；文件名（页面标题）可以用中文。
- 新增模块：在资料库根目录建文件夹，并在 `.acdian-modules.json` 和 `.acdian-order.json` 里登记。
- 模块可以设 `"readOnly": true`：页面能打开，不能编辑、新建、删除或移入。Atlas 模块就是这样，内容由 `~/Developer/atlas-ac/tools/atlas.py sync` 写入。
- Teaching 模块：用户提问时，用直观、信息量充足的交互动画（`acdian-interactive`）回答。
- Antifragile 模块：记录抗风险的网络和金融基础设施，框架见 `Antifragile/总纲.md`。不写密码、恢复码、卡号、助记词等秘密，只写存放位置。

## 文档同步

- 每次修改在同一个提交里更新 `docs/STATE.md`；做了取舍就在 `docs/DECISIONS.md` 末尾追加一条。纯格式化、依赖升级等可在提交说明里写 `[skip-state]`。
- 这三份文档会自动同步到 Atlas（`~/Developer/atlas-ac`，github.com/Attopos/atlas-ac）和 ACdian 的 Atlas 模块，那边只读，只在这里改。
- 出了错或被纠正，把教训补进本文件的规则。
