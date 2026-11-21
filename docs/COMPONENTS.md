# 内置组件（表单）怎么加

组件是放在资料库里的 `.acdian` 文件，打开时由一张内置网页画出来。路线图是第一个这样做的组件，新组件照同一套来。

## 网页侧

- 放在 `Resources/<kind>/<kind>.html`，先加载 `../interactive/theme.css`（颜色变量）和 `../kit/kit.js`，再加载自己的脚本。
- `kit.js` 提供 `window.AcdianKit`：
  - `mount(kind, handlers, api)`：注册 `window.acdian<Kind>.receive`，收到的消息带 `theme` / `language` 时自动切换，再按 `type` 调 `handlers`。
  - `ready()`：页面准备好后调用一次，App 才会发 `load`。
  - `post(message)`：发给 App（测试里没有 WebKit 时存进 `window.__posted`）。
  - `strings(table)`：返回 `T(key, ...args)`，中文原文作 key，`%1` 占位。
  - `onTheme` / `cssVar(name, el)`：主题切换回调和按主题缓存的 CSS 变量。
  - `$`、`esc`、`fold`、`dur`、`reduced`：常用小工具。
- 大画布可以用 `kit/svg-raster.js`：SVG 照常画，`SvgRaster` 把它转成分块图片显示。

## App 侧

- `Sources/ComponentBridge.swift`（Mac 和 iOS 共用）：`ready → load → update` 握手、去重、`send`、导航白名单。宿主只要给它 `state`、`payload`、`handle`、`savedView` 四个闭包。
- Mac 用 `ComponentWebHost(page:)`（`Sources/RoadmapView.swift`），iOS 用 `ComponentCanvas(page:configure:stateKey:)`（`iOS/RoadmapScreen.swift`）。
- 新组件：`ComponentKind` 加一个 case，模型里写 payload 和消息处理，视图里用上面的宿主；`project.yml` 给 `Resources/<kind>` 加文件夹引用。
