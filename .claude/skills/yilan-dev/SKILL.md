---
name: yilan-dev
description: prd、设计稿、spec、技术方案都确认后，实现某个版本的代码并验证时使用。包括建分支、生成工程、构建、跑测试、安装到本机、对照设计稿验收。
---

# 一览的开发和验证

前提：`changes/<版本号>/` 里的 prd、design、spec、tech-design 都已确认。开发完要按 `prd.md` 的验收标准和 `spec.md` 的规则逐条验收。

## 仓库约定

- 代码注释和 commit message 用中文，标识符（类型、函数、变量、文件名）用英文。commit 末尾按当次会话的要求加署名行。
- 测试素材只用公开授权的文件（CC0 或公共领域），来源登记到 `app/Fixtures/CREDITS.md`；不要用个人照片。大的 RAW 样张不进仓库（`.gitignore` 已排除 `app/Fixtures/raw/`）。
- 界面文字放在 `app/Yilan/Resources/Localizable.xcstrings`，中英文都要有。
- 界面实现必须和设计稿一致。
- 不要自行 push，也不要发布 Release、打 tag；这些要等负责人明确同意。

## 分支

每个版本一个分支，从 `main` 开出，分支名用版本号，例如 `v0.4`。不要在别人的分支上直接改，也不要 stash 别人的改动。提交时只 `git add` 自己改的路径，不用 `git add -A`。

## 命令（均在 `app/` 目录下，已实际跑通）

```sh
cd app
xcodegen generate      # 改了 project.yml 或增删源文件后重新生成 Yilan.xcodeproj
xcodebuild -project Yilan.xcodeproj -scheme Yilan -configuration Release \
  -derivedDataPath build/release build
xcodebuild -project Yilan.xcodeproj -scheme Yilan -destination 'platform=macOS' \
  -derivedDataPath build/test test
```

- 构建产物在 `app/build/`，已被 `.gitignore` 忽略；`-derivedDataPath` 一定指到这里，不要把产物放到别处。
- 构建出的程序在 `app/build/release/Build/Products/Release/Yilan.app`。
- 版本号在 `app/project.yml` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，发布时才改。
- 发布包用 `scripts/release.sh`（生成 `dist/Yilan-<版本>.zip`），只有负责人同意发布后才运行。

## 安装到本机试用

把上面的 `Yilan.app` 复制到 `/Applications/`（覆盖旧版前先告诉负责人）。

## 对照设计稿验收

1. 打开 `changes/<版本号>/design/index.html` 和 `shots/`，运行程序，用公开素材（`app/Fixtures/sample/`）逐个画板对照：布局、间距、颜色、文案、各种状态。
2. 窗口缩到最窄、中英文两种语言各看一遍。
3. 不一致的地方改代码，不要改设计稿；设计稿确实有问题，回头问负责人。
4. 给负责人看还没做完的版本之前，先说明哪些地方还没和设计稿对齐。

## 汇报

说明：改了什么、`prd.md` 每条验收的结果、跑了哪些测试和结果、还有哪些没做（移到下一个版本）。
