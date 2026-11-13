# 决策记录

只追加，不改旧条目；推翻旧决定时写一条新的并注明推翻了哪条。

## 2026-11-13 文档进仓库，用 Atlas 汇总

- 背景：希望换 AI 工具后能从断掉的地方立即续上。
- 决定：规则写在 `AGENTS.md`（`CLAUDE.md` 只引用它），进度写在 `STATE.md`，取舍写在 `DECISIONS.md`，和代码一起提交；git hook 督促同步，并自动汇总到 atlas-ac 和 ACdian 的只读 Atlas 模块。
- 放弃的方案：把规则留在某个 AI 工具的设置里（迁移时最容易丢）；在 acdian 里手动维护副本（会和原件不一致）。

## 2026-11-13 模块支持 readOnly

- 背景：Atlas 模块的内容由同步脚本从各项目生成，在 App 里改了也会被下次同步冲掉。
- 决定：`.acdian-modules.json` 的模块可写 `"readOnly": true`。编辑器对其中页面关闭编辑；保存、删除、改名、移入、新建文件夹、导入附件都在 AppModel 里拦下。只有为 true 时才写进 JSON，其他模块的记录不变。
- 放弃的方案：只靠同步覆盖、不改 App（能改但会丢，容易误以为保存了）。

## 2026-11-13 规则只保留仓库里的一份

- 背景：`~/Developer/acdian/CLAUDE.md` 是 Atlas 之前手写的规则副本，和仓库 `AGENTS.md` 并存，读错路径时拿到旧规则；Claude Code 还会同时加载上级目录的 CLAUDE.md，两份规则会互相矛盾。
- 决定：删掉外层副本，规则只写在仓库 `AGENTS.md`，并在其中写明从外层目录开工时去哪读。
- 放弃的方案：外层留一行 `@Project/work/acdian/AGENTS.md` 引用（在仓库里开工时会被重复加载）。
