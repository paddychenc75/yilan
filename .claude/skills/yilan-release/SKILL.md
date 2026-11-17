---
name: yilan-release
description: 一个版本开发并验收完成后，写更新说明、打发布包、发布到 GitHub 并做发布后检查时使用。应用内的更新提醒读的是 GitHub 上最新的正式发布和它的正文，tag、标题、正文格式任何一处错了，用户都会直接看到。
---

# 一览的更新说明和发布

第一部分（准备）可以直接做。第二部分（打包、push、打 tag、建 GitHub Release）必须等负责人明确同意，同意一次只管这一个版本。发布后发现问题先告诉负责人，不要自行删除或重建 Release 和 tag。

## 更新说明的固定格式（应用依赖它）

文件是 `changes/v<主.次>/release-notes-<完整版本号>.md`（0.3.1 也放在 `changes/v0.3/`），从 `changes/release-notes-template.md` 复制开始。它的全文就是 GitHub Release 的正文，不要在网页上另写一份。

- 三个段落，名字和顺序不能改：`## 中文`、`## English`、`## 安装 / Install`。应用按界面语言只显示中文段或英文段，安装段只在 GitHub 页面显示。
- 中文段和英文段用小标题分组，没有内容的小标题整个删掉：新功能 / New、改进 / Improved、修复 / Fixed、升级须知 / Upgrade notes。两种语言的小标题数量、条目数量、顺序一一对应。
- 每条以加粗短名字开头，站在用户角度写：`- **评星**：按 1 到 5 给照片打星，按 0 清除。`修复类先写用户当时看到的现象，再写现在怎样。不写内部名词（模块名、分支名、重构）和用户感觉不到的改动。
- 只用三级标题、无序列表、加粗、行内代码、链接。不用图片、表格、HTML、一级标题（标题由 Release 的标题提供）。
- 内容来源：`changes/<版本>/prd.md` 的功能清单和这个版本的提交记录。PRD 里「尽量做」但最后没做的不写。

## 第一部分：准备（不需要同意）

1. 改版本号：`app/project.yml` 的 `MARKETING_VERSION` 改成完整版本号（如 `0.3.0`），`CURRENT_PROJECT_VERSION` 在上一次发布的基础上加 1（0.2.0 是 2，0.2.1 是 3）。然后 `cd app && xcodegen generate`，把 `project.yml` 和 `Yilan.xcodeproj/project.pbxproj` 一起提交。
2. 跑测试（命令见 `yilan-dev`），必须全部通过。`scripts/release.sh` 不跑测试。
3. 更新 `README.md` 和 `README.zh-CN.md`：功能列表补上这个版本的新功能；界面有变化就重拍 `docs/screenshots/` 里的截图，`zh-` 和 `en-` 两套画面保持一致，只用公开素材。
4. 写更新说明，SHA-256 先留模板里的占位。这时运行 `scripts/check-release-notes.sh <完整版本号>`，除了「SHA-256 还没有填」不应有别的报错。
5. 把更新说明和待发布内容给负责人看，请求同意发布。

## 第二部分：发布（负责人同意后，按顺序）

1. 运行 `scripts/release.sh`，得到 `dist/Yilan-<版本>.zip` 和 SHA-256（脚本会做隐私检查，失败就停，不要绕过）。把 SHA-256 填进更新说明；之后只要重新打过包，就要重新填。
2. 运行 `scripts/check-release-notes.sh <完整版本号>`，必须通过。提交更新说明，`git status` 里不应再有属于这个版本的未提交改动。
3. 把版本分支合并进 `main` 并 push `main`。tag 必须打在 `main` 上、包含版本号改动和更新说明的那个提交。
4. 打带说明的 tag 并 push，名字是 `v` 加完整版本号，和 `MARKETING_VERSION` 完全一致：

   ```sh
   git tag -a v0.3.0 -m "v0.3.0" && git push origin v0.3.0
   ```

5. 建 Release。标题固定为「一览 Yilan v<版本号>」，附件只有这一个 zip，正文用更新说明文件。不要加 `--draft` 和 `--prerelease`（应用只认正式发布，草稿和预发布不会触发更新提醒）：

   ```sh
   gh release create v0.3.0 dist/Yilan-0.3.0.zip --verify-tag \
     --title "一览 Yilan v0.3.0" --notes-file changes/v0.3/release-notes-0.3.0.md
   ```

## 发布后检查（每项都要实际看到结果）

```sh
gh release view v0.3.0 --json tagName,name,isDraft,isPrerelease,assets \
  --jq '{tagName,name,isDraft,isPrerelease,assets:[.assets[]|{name,digest}]}'
gh api repos/paddychenc75/yilan/releases/latest --jq .tag_name
```

- `isDraft` 和 `isPrerelease` 都是 false；附件名是 `Yilan-<版本>.zip`，`digest` 等于 `sha256:` 加更新说明里的值。
- 第二条命令返回的正是新版本的 tag（应用内更新提醒看的就是它）。
- 打开 Release 页面看一眼正文：三段都在，格式没有错乱。README 的下载链接指向 Releases 列表页，不用改。
- 在 `changes/README.md` 的版本状态表里注明这个版本已发布（表里目前没有发布这一列，第一次用时加一列）。发布后这个版本的目录不再修改，补丁版本的更新说明除外。
- 向负责人汇报：Release 链接、上面几项检查的结果。
