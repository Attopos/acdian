# 渲染安全测试

这份笔记包含应当保持非活动状态的 HTML 测试内容。标题、app 状态和本地文件不应受这些内容影响。

<script>document.title = "UNSAFE SCRIPT EXECUTED";</script>

<iframe src="https://example.com"></iframe>

[不应当执行的链接](javascript:alert('unsafe'))

![不应越出仓库的路径](../../../../../../etc/passwd)

`<script>` 在代码中应作为文本呈现。
