# AGENTS.md

给在本仓库工作的 AI 助手和协作者的说明。

## 需求开发流程

每个版本的文档放在 `changes/<版本号>/`，按下面的顺序推进，上一步由项目负责人确认后再做下一步：

1. `prd.md`：需求。做什么、为什么、不做什么、验收标准。
2. `design/`：设计稿。`index.html` 是本体，`shots/` 是画板截图。
3. `spec.md`：功能规格。把需求和设计稿落成逐条可测试的行为规则。
4. `tech-design.md`：技术方案。怎么实现、改哪些模块、风险怎么防。
5. 开发，并按 `prd.md` 和 `spec.md` 逐条验收。
6. `release-notes-<版本号>.md`：更新说明。格式固定（应用内「查看更新说明」读它），负责人同意后才发布。

规则：

- 范围有变化，先改 `prd.md`，再同步其他文档。
- 版本发布后，它的目录不再修改；后续改动写进下一个版本的目录。
- 界面实现必须和设计稿一致。
- 给负责人看的文档用中文。

详细说明和各版本状态见 `changes/README.md`。

## 项目技能（Skills）

`.claude/skills/` 里有六个技能，对应版本流程的每一步，做到哪一步就用哪一个：

| 技能 | 什么时候用 |
| --- | --- |
| `yilan-prd` | 写或修改 `prd.md`（版本开始、范围变化） |
| `yilan-design` | PRD 确认后，做 `design/index.html` 和 `shots/` |
| `yilan-spec` | 设计稿确认后，写 `spec.md` |
| `yilan-tech-design` | 开发前，写 `tech-design.md` |
| `yilan-dev` | 方案确认后，写代码、构建、测试、安装、对照设计稿验收 |
| `yilan-release` | 验收完成后，写更新说明、打发布包、发布到 GitHub、发布后检查 |
