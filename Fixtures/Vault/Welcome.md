---
title: acdian 验证笔记
tags: [fixture, 中文]
---

# 欢迎使用 acdian

这是测试用笔记，不包含任何用户数据。粉色强调色应当与深色背景保持清楚的对比。

## 常用 Markdown

段落支持 **粗体**、*斜体*、~~删除线~~、`行内代码` 和 [外部链接](https://example.com)。

> 引用中的中文、English 和 emoji 🌸 应当正常显示。

- [x] 已完成任务
- [ ] 未完成任务
- 普通列表
  - 嵌套列表

1. 第一项
2. 第二项

| 功能 | 预期 |
| --- | --- |
| 编辑 | 保存后保留内容 |
| 图片 | 使用仓库内的附件 |
| PDF | 在窗口内部打开 |

```javascript
const greeting = "<script>不应被执行</script>";
console.log(greeting);
```

## 图片

Markdown 相对路径：

![粉色示例图片](Attachments/pink-sample.png)

Obsidian 图片嵌入：

![[pink-sample.png]]

带显示宽度的图片：

![[pink-sample.png|160]]

中文和空格路径：

![中文附件](Attachments/粉色%20示例.png)

SVG 附件：

![[Attachments/safe-diagram.svg]]

## 内部导航

- [[Notes/Nested/Deep Note|深层笔记]]
- [Markdown 相对链接](Notes/Nested/Deep%20Note.md)
- [[研究/中文笔记]]
- [[Notes/Same|Notes 中的同名笔记]]
- [[Archive/Same|Archive 中的同名笔记]]
- [[Notes/Nested/Deep Note#第二节|跳转到标题]]
- [[不存在的笔记|缺失链接应友好显示]]

## PDF

[打开 PDF](Attachments/sample.pdf)

![[Attachments/sample.pdf]]

![[Attachments/sample.pdf#page=2]]

## 分隔线

---

最后一段用于检查滚动、保存及再次打开后的内容一致性。
