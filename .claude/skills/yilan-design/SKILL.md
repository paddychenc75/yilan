---
name: yilan-design
description: PRD 确认后，制作某个版本的设计稿 changes/<版本号>/design/（index.html 加 shots/ 截图）时使用。也用于修改设计稿、重拍画板截图。
---

# 做一览的设计稿

前提：`changes/<版本号>/prd.md` 已由负责人确认。流程和状态表见 `changes/README.md`。

## 产出

- `changes/<版本号>/design/index.html`：独立的单个页面，是设计稿本体。
- `changes/<版本号>/design/shots/`：每个画板一张 PNG 截图。
- 保真度对齐现有设计稿：先看 `design/yilan-design.html` 的样式变量和章节写法，以及 `changes/v0.3/design/index.html`。画面要精致完整，不是粗糙原型；每个画板要有标题和一句说明。
- 其他版本的目录和 `design/` 根目录下的旧设计稿不要改，除非负责人明确要求。

## 照片

- 引用仓库里 `design/photos/` 的素材（Unsplash License，来源见 `design/photos/CREDITS.md`），页面里用相对路径，例如 `../../../design/photos/p1043.jpg`。
- 不复制照片到版本目录，不使用任何个人照片。

## 风格硬规则

- 只有深色界面，不做浅色。
- 品牌色：teal `#128A80`、jade `#3FC4B0`、tealDeep `#0E3B3B`、sun `#FFE2A0`、tealNight `#061717`。永远不要蓝紫色调。
- 品牌色只用在非照片的界面上（空状态、拖入遮罩、图标等）；控件颜色跟随系统强调色。
- 玻璃（Liquid Glass）元素的描边统一为 1pt 一圈，粗细一致。
- 信息面板浮在照片上面，不把照片挤到一边。
- 界面文字同时考虑中文和英文两种语言下的长度。

## 方案选择

有真实取舍的地方，把「推荐」和「备选」并排放在同一画板里，各自标出名称，并写明推荐的理由。没有取舍的地方不要凑备选。

## 截图和自查

- 用无头浏览器渲染（本机有 `/Applications/Google Chrome.app`，`design/intro-video-export.mjs` 里有用 `--headless=new` 和调试协议的例子），把每个画板单独截成 `shots/NN-名称.png`。
- 汇报前必须逐张看过每个画板截图：有没有文字被截断、重叠、图片没加载、颜色跑偏。发现问题先改。
- 每个 PRD 的功能编号都要在某个画板里能找到对应画面。

## 写完之后

- 在 `changes/README.md` 的状态表里更新 design 一列。
- 给负责人看时说明哪些画板有「推荐 / 备选」需要他选。确认前不要写 spec 和 tech-design。
