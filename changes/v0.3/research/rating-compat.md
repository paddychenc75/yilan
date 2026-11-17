# 星级兼容性调研：主流软件怎么读写图片和视频的星级

调研日期：2026-11-18。范围：一览 v0.3 计划把 0–5 星存成 `xmp:Rating`（XMP 是 Adobe 定的附加信息格式；sidecar 是放在文件旁边的 `.xmp` 小文件）。对照文件：`prd.md` 4.3、`spec.md` 第 4–5 节、`tech-design.md` 第 3 节。

## 读这份报告前先看四条规则

1. 每条结论后面的 `[n]` 对应文末的来源编号。来源分三档：「官方文档」（厂商文档或规范）、「官方论坛或工作人员答复」、「第三方 / 用户报告」。
2. 只写我真正打开读过的页面。只在搜索结果摘要里见过、没打开的，放在文末「只见搜索摘要」，正文不当依据。
3. 找不到可靠来源的地方，写「未找到可靠来源」，不猜。
4. 厂商帮助站有几个打不开（Capture One、DxO 的部分页面直接访问被拒绝，ExifTool 论坛当时停服）。我用一个公开的网页转文本服务读到了 Capture One 和 DxO 的官方文章正文；ExifTool 论坛页面始终没打开。

---

## 一句话结论

「RAW 旁边放小写 `basename.xmp`、JPEG/TIFF 写进文件内的 `xmp:Rating`」这条主线是对的，Adobe、Capture One、Photo Mechanic、FastRawViewer 都按这个读；但有三处要改：DNG 不能照 RAW 一样只信小文件，视频没有任何两个主流软件都读的星级格式（只有 Adobe 的 XMP 约定勉强算），HEIC / PNG 在大部分软件里几乎没有官方说法，必须实测。

---

## 兼容性矩阵

图例：
- 读 S = 读旁边的 .xmp 小文件；读 E = 读文件内嵌的 XMP；写 S / 写 E 同理。
- 不支持 = 有来源说明这类文件不处理星级或星级不外传。
- 未找到可靠来源 = 我没有找到官方或可靠的说法。
- 方括号数字是文末来源编号。

| 软件 | RAW | DNG | JPEG | HEIC/HEIF | TIFF | PNG | 视频 MP4/MOV |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Lightroom Classic | 读 S、写 S（需开「自动写入 XMP」或手动保存；导入后改动要手动「从文件读取元数据」）[11][12][31] | 读 E、写 E [11][18]；小文件较新时也会读 [16] | 读 E、写 E [11]；忽略小文件 [30] | 读 E、写 E（仅论坛用户说明，非官方）[17] | 读 E、写 E [11] | 写 E（仅论坛说明）[18]；读：未找到可靠来源 | 不支持（只存在目录库里，别的软件看不到）[13] |
| Lightroom（云端 / 桌面版） | 未找到可靠来源（第三方说明：本地存储的 RAW 星级写进 .xmp）[40] | 未找到可靠来源 | 第三方：本地存储写进文件 [40] | 同左 [40] | 未找到可靠来源 | 同左 [40] | 未找到可靠来源 |
| Adobe Bridge | 读 S、写 S [14] | 未找到可靠来源（官方只说「多数情况写进文件」）[14] | 读 E、写 E [14]；个别旧版本对某些 JPEG 误写 .xmp（ACR 17.0 / Bridge 15.0 修复）[50] | 未找到可靠来源 | 读 E、写 E [14] | 未找到可靠来源 | 未找到可靠来源 |
| Camera Raw / Photoshop | 读 S、写 S，或存在 Camera Raw 数据库 [15] | 默认写进 DNG 本身，可改成小文件；有「忽略 .XMP 小文件」选项 [15] | 永远写进文件 [15] | 未找到可靠来源 | 永远写进文件 [15] | 未找到可靠来源 | 未找到可靠来源 |
| Capture One | 读 S、写 S（「自动同步」选完全同步才写）[24] | 官方文章未区分；第三方说只读的 DNG 需要旁边有 .xmp [40] | 读 E、读 S；只有小文件会被更新，不改 JPEG 本身 [24] | 官方文章未区分格式，未找到可靠来源 | 同 JPEG [24]（未区分） | 未找到可靠来源 | 不支持（视频只能播放，不能评星）[25] |
| Photo Mechanic / Plus | 写 S（默认优先小文件）[32]；读：未找到可靠来源 | 写 E；不支持外部小文件 [33][34]（论坛 / 用户） | 写 E（XMP，默认还带 IPTC）[32] | 未找到可靠来源 | 写 E [32] | 未找到可靠来源 | 未找到可靠来源 |
| DxO PhotoLab | 读 S（v5 起读 .xmp，不再读 .dop）[26]；写：未找到可靠来源 | 官方文章未区分格式 [26] | 同左 [26] | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| darktable | 读 S（导入时读 Lightroom 风格 `basename.xmp`，只读不写）；自己写 `basename.ext.xmp` [27][28] | 同 RAW [27][28] | 读 E 里的 Exif 星级（可选忽略）[28]；写 S（自己的命名）[28] | 未找到可靠来源 | 同 JPEG [28] | 未找到可靠来源 | 未找到可靠来源 |
| digiKam | 写 S（默认 `文件名.扩展名.xmp`，可改成 `文件名.xmp`）[29] | 同 RAW [29] | 写 E 和 / 或 S，可选；星级通常同时写 Exif 和 XMP [29] | 未找到可靠来源 | 同 JPEG [29] | 未找到可靠来源 | 写 S（「只读项目」选项明确包含视频）[29]；开启 ExifTool 后另写 QuickTime 的 SharedUserRating [46] |
| RawTherapee / ART | 星级存在自己的 .pp3；读 E，不读 .xmp 小文件（RawTherapee 5.7，2019）[36] | 同左 [36] | 读 E（Exif / XMP）[36] | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源（ART 整体：未找到可靠来源） |
| ON1 Photo RAW | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| ACDSee（Mac） | 官方更新日志：2026-04 修复「在 ACDSee 里评的星别的软件读不到」，2026-05 修复 RAW 星级读错 [37] | 未找到可靠来源 | 未找到可靠来源 | 写 E（9.0 起元数据直接写进 HEIC，不用小文件）[37] | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| FastRawViewer | 读 S、写 S（命名可选 `名.xmp` 或 `名.ext.xmp`）[30] | 读 E 和 S，取较新的；改动写小文件 [30] | 默认写 S；可选写 E（Adobe 忽略 JPEG 小文件所以要嵌入）[30] | 默认关闭；开启后读 E、读 S、写 S [30] | 同 HEIC [30] | 同 HEIC [30] | 未找到可靠来源 |
| XnView MP | 写 S（用户反映不能写进 RAW 本身）[38]（仅用户 / 作者答复） | 未找到可靠来源 | 可选：只写 JPEG、只写小文件、或两者都写（1.9.x 起）[38] | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| Apple 照片（Photos） | 有星级功能（需打开「显示评星控件」）[43]；导入时是否读 .xmp / 内嵌星级：未找到可靠来源 | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| Finder / Spotlight / 预览 / 快速查看 | 未找到可靠来源 | 未找到可靠来源 | 第三方：预览显示了 JPEG 内 XMP 的 3 星 [47]（单个用户报告） | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| Windows 资源管理器 | 未找到可靠来源（微软文档只列 JPEG、TIFF）[7][8] | 同左 | 读 E、写 E：`xmp:Rating` 和 Exif 0x4746（五级），`MicrosoftPhoto:Rating` 和 Exif 0x4749（百分制）[7][8] | 微软文档没列 HEIC [7][8] | 读 E、写 E（同 JPEG）[7][8] | 微软文档没列 PNG [7][8] | 开发者称 Windows 11 能显示 digiKam 写的视频星级 [46]（第三方） |
| Windows 照片 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 | 未找到可靠来源 |
| ExifTool（参照读取器） | 读：不适用，它读任何位置的标签，见下节 [3][4][5] | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |
| Final Cut Pro | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 只有「收藏 / 拒绝 / 取消评级」，没有星级 [44]；读不读 XMP：未找到可靠来源 |
| DaVinci Resolve | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 论坛用户称不支持读写 XMP [48]（日期未取得）；星级：未找到可靠来源 |
| Premiere Pro（含 Bridge 视频） | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 星级存成 XMP「Basic」里的 Rating；格式支持内嵌时写进媒体文件，有的格式写小文件；只读目录才退回工程文件 [20]（2025-09，社区经理答复）。Bridge 视频：未找到可靠来源 |
| Kyno 等媒体管理器 | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | 不适用 | Kyno 自己存在隐藏目录 .LP_Store [42]；导出给 Premiere 时用 XMP「Basic > Rating」，给 Final Cut Pro X 时 1–5 星一律变成「收藏」[41]；Kyno 2021 年被收购后无更新 [42] |

---

## 逐个软件的说明

### 先说标准本身

- `xmp:Rating` 的定义：值为 -1 或 0–5；-1 表示「拒绝」，0 表示「未评星」；没有这一项时按 0 处理。[1]（官方规范，Adobe XMP 规范 Part 1，我读的是第三方镜像站上的 Adobe PDF）
- ExifTool 的标签表：XMP 的 Rating 是「0 到 5，或 -1 表示拒绝」；`RatingPercent` 标注为「非标准」。[3]（ExifTool 官方标签文档）
- Exif 里有两个旧标签：0x4746 `Rating`、0x4749 `RatingPercent`，都是 16 位整数。[4]
- QuickTime（MOV）的「Keys」表里有 `rating.user`，ExifTool 叫它 `UserRating`，可写；`ItemList` 里的 `rtng`（也叫 Rating）是内容分级（明确 / 干净），不是星级，别混用。[5]
- 小文件命名：规范说「在同一目录找主文件同名、扩展名 `.xmp` 的文件」。[2]（官方规范）

### Adobe Lightroom Classic

- 元数据写在哪：RAW 写 .xmp 小文件；JPEG、TIFF、PSD、DNG 写进文件本身。[11]（官方文档）论坛里的资深用户还补充 HEIC、PNG 也写进文件 [17][18]（第三方，不是 Adobe 员工）。
- 默认只写目录库：要让别的软件看到，必须开「编辑 > 目录设置 > 元数据 > 自动将更改写入 XMP」，或手动「元数据 > 保存元数据到文件」。[11][12]（官方文档）
- 读：别的软件改了之后，Lightroom 显示「元数据已被外部更改」图标，需要选「元数据 > 从文件读取元数据」才会覆盖目录库。[12]（官方文档）FastRawViewer 官方论坛里的答复也是同一步。[31]
- 小写扩展名：一位社区专家说 Lightroom 要小写 `.xmp`，Photo Mechanic 在 NAS 上写成了大写 `.XMP` 导致读不到。[19]（第三方，单个案例，但和我们的做法一致：写小写）
- DNG 读小文件：Adobe 工程师 Thomas Knoll 在 2022-09 的社区帖子里说，Lightroom 在 DNG 的小文件较新时读它「就 Adobe 而言是预期行为」；若小文件含 `photoshop:SidecarForExtension` 且不是 DNG，Adobe 软件会忽略它对 DNG 的作用。[16]（官方论坛或工作人员答复，2022 年，较旧）
- 视频：官方明说，在资料库里改视频元数据只存在目录库，别的软件看不到。[13]（官方文档）Canon R 系机内视频星级导入 Lightroom 会丢，社区专家说它存在 QuickTime:Rating，而 Lightroom 只读 Exif:Rating 和 XMP:Rating（2024-05）。[21]（第三方）
- Lightroom Classic 15.0（2025-10）起，繁重编辑另存 `.acr` 小文件，XMP 变轻。[10]（官方文档）对我们只写星级的小文件没有影响。
- JPEG 小文件：FastRawViewer 官方手册说 Adobe Bridge 和 Lightroom 忽略 JPEG 的小文件。[30]（厂商文档，旧版 1.7 手册，但与社区一致）

### Adobe Lightroom（云端 / 桌面版）

Adobe 官方没找到可靠说法。第三方（Pixelmator 的帮助页）说：本地存储的 RAW 星级写进 .xmp，JPEG、HEIC、PNG 通常直接写进文件；云存储的要用「导出并包含全部元数据」带出来。[40]（第三方，描述的更像 Classic 的本地模式，可信度中）

### Adobe Bridge

官方：元数据用 XMP 保存，「多数情况存在文件里，存不进去才用小文件」。[14]没有按格式的星级细节。个别旧版本（Camera Raw 16.3.1 期间）会给部分 JPEG 误写 .xmp，ACR 17.0 / Bridge 15.0 修复。[50]（社区答复，转载自问答站）

### Camera Raw / Photoshop

官方：RAW 的设置存在 Camera Raw 数据库或旁边的 .xmp（同名、扩展名 .xmp）；DNG 默认存在 DNG 本身，也可存小文件；TIFF、JPEG 永远存在文件本身；偏好里有「忽略 .XMP 小文件」，选上则 DNG 的所有调整留在 DNG 里。[15]（官方文档）这里说的是「调整设置」，星级是否同走这条路径没有单独说明。

### Capture One

官方文章「Metadata in XMP sidecar files」：[24]（官方文档，无日期）
- 能读四处：内嵌 Exif、内嵌 IPTC-IIM、内嵌 XMP、`.XMP` 小文件；「只有小文件能被更新」，不改文件内嵌的信息。
- 同名不同扩展名的文件共用一个小文件：`ImageName001.NEF` 和 `ImageName001.jpg` 对应同一个 `ImageName001.XMP`。
- 偏好 > 图像 > 元数据 > 「自动同步小文件 XMP」三档：完全同步（双向，没有小文件会新建）、载入（单向，只读）、无（只能手动「载入元数据」/「同步元数据」）。
- 另有「优先使用小文件 XMP 而非内嵌元数据」开关。
视频：官方社区版主答复，支持的视频只能播放，不能评星。[25]（官方论坛或工作人员答复，日期未取得）

### Photo Mechanic / Plus

官方文档：[32]
- JPEG、TIFF、PSD：XMP 一定写进文件，默认还写 IPTC。
- RAW：默认优先写小文件；基于 TIFF 的 RAW 可以勾选「允许修改 RAW」后改成内嵌。
- 论坛里有人（身份未确认）说：DNG 总是用内嵌 XMP，不写小文件。[33]
- 一位用户报告：Photo Mechanic 不支持 DNG 的外部小文件，给「锁定」的 DNG 评星时它改了 DNG，DNG 变得比小文件新，ACR 就忽略了小文件里的编辑。[34]（第三方）
视频：未找到可靠来源。

### DxO PhotoLab

官方支持文章（适用 v5 以后）：PhotoLab 从 .xmp 读星级，不再读 .dop；要在偏好 > 常规 > 元数据同步里开「始终同步」，或手动读写元数据；开着同步时按「谁新听谁的」，第三方改了的数据会覆盖数据库。[26]（官方文档，无日期）PhotoLab 自己写不写星级：未找到可靠来源。

### darktable

- 命名：darktable 自己的小文件叫 `名.扩展名.xmp`（例如 `DSC1234.NEF.xmp`）；导入时也找 Lightroom 风格的 `名.xmp`，读但从不写，之后另建自己命名的文件。[27]（官方手册 4.4）
- 能从 Lightroom 小文件读：标签、颜色标签、评星、GPS。[27]
- 偏好：「创建 XMP 文件」可选 从不 / 导入时 / 编辑后；「启动时查找已更新的 XMP 文件」可选。[28]（官方手册 5.6）
- 「复制并导入」不会读已有小文件；「添加到库」会重新读。[28]（官方手册）
- 导入窗口有「忽略 Exif 星级」，说明它读文件里的 Exif 星级。[28]

### digiKam

官方手册（Sidecars 页）：[29]
- 小文件读写可开关；写入三选一：只写小文件、同时写文件和小文件、只对只读项目（手册明说如视频、RAW）写小文件。
- 默认小文件名是 `文件名.扩展名.xmp`；打开兼容选项后改成 `image1.xmp` 这种「许多商业软件用的名字」。
- 星级「通常同时存在 Exif 和 XMP」。
视频：开发者在 2025-02 的缺陷单里说，开启 ExifTool 写入后，星级写到 XMP 和 QuickTime 容器的 SharedUserRating，报告者在 Windows 11 上看到星级正常。[46]（官方论坛或工作人员答复）

### RawTherapee / ART

2019-11 论坛帖（RawTherapee 5.7）：它读内嵌的 Exif 和 XMP 星级，不读 .xmp 小文件；回答的是论坛成员，不一定是开发者。[36]（第三方，较旧）ART：未找到可靠来源。

### ON1 Photo RAW

未找到可靠来源（只在搜索摘要里看到一篇约 2016 年的博客，没打开）。

### ACDSee（Mac）

官方更新日志：26.0.2（2026-04）修复「在 ACDSee 里评的星在别的软件读不到」；26.0.3（2026-05）修复「RAW 星级读不准」；9.0（2022-11）起元数据直接写进 HEIC，不再用小文件。[37]（官方文档）它写成哪个标签：未找到可靠来源。

### FastRawViewer

厂商手册（我打开的是 1.7 版页面，较旧，现行是 v2）：[30]
- 默认找小写 `.xmp`，再找大写 `.XMP`；偏好可选 `名.xmp` 或 `名.ext.xmp`。
- 星级 1–5；开启后可用 -1 拒绝。
- DNG：读内嵌和小文件，取 `xmp:MetadataDate` 较新的；有些程序不写这一项，要在偏好里选「总是用小文件」。
- JPEG 默认写小文件，可选改写进文件；写进文件时会删掉旧小文件。
- TIFF、PNG、HEIC：默认关闭，开启后读内嵌、读小文件、写小文件。
- 提醒：RAW 和 DNG 同名会抢同一个 `名.XMP`，有警告。

### XnView MP

作者（官方论坛）2025-05/06 答复：以前星级只能二选一写进 JPEG 或写进小文件，1.9.x 起「创建或更新 XMP 小文件」和「更新主文件」都勾上，则两处都写。[38]（官方论坛或工作人员答复）提问者的说法「Windows 只读 JPEG 内嵌星级、忽略小文件」是用户说的，不是来源。

### Apple 照片（Photos）

官方：照片有 1–5 星功能，要在「照片 > 设置 > 通用」勾「显示评星控件」。[43] iCloud.com 的照片也能评星。[45] 导入时读不读 `xmp:Rating`、内嵌星级、小文件：未找到可靠来源。

### Finder / Spotlight / 预览 / 快速查看

只有一个第三方单例：某 JPEG 的 XMP 里 `Rating: 3`，预览显示 3 星。[47]其余未找到可靠来源。

### Windows 资源管理器 / 照片

微软官方：[7][8][9]
- `System.SimpleRating`（0–5）：JPEG 读写 Exif 0x4746（即十进制 18246）和 `xmp:Rating`；TIFF 同理。
- `System.Rating`（1–99）：JPEG 读写 Exif 0x4749（18249）和 `MicrosoftPhoto:Rating`。
- 百分制和星的对应：1–12 为 1 星（写入 1），13–37 为 2 星（25），38–62 为 3 星（50），63–87 为 4 星（75），88–99 为 5 星（99）。[9]
- 两份策略页都只列「JPEG、TIFF」，没有 HEIC、PNG。
- 「不同来源的值会被协调」，没有说谁优先。
Windows 照片应用：未找到可靠来源。

### ExifTool

见「先说标准本身」。Phil Harvey 的论坛答复我没能打开，所以关于「各软件读哪个标签」的权威说明：未找到可靠来源。

### 视频软件小结

- Final Cut Pro：只有收藏 / 拒绝 / 取消评级。[44]
- Kyno 官方对照表（2019-11）：Kyno 的 1–5 星导出到 Final Cut Pro X 全变「收藏」；导出到 Premiere 是 XMP「Basic > Rating」。[41]
- Premiere：见矩阵；官方社区经理（2025-09）说星级是 XMP 元数据，跟媒体走，所以会改文件修改时间；只读目录时存进工程文件，同一素材在不同工程里星级可能不同。[20]
- Resolve：论坛用户说不支持读写 XMP。[48]（第三方，日期未取得，可能过时）CSV 元数据导入导出只在搜索摘要里看到，未打开。
- Lightroom Classic 把视频星级只留在目录库里。[13]
- Capture One 视频不能评星。[25]

### 相机机内星级

- ExifTool 的标签表里：Nikon 的 NCTG 表 0x1001「Rating（0 到 5 星）」；Sony 表 0x2002「Rating」；FujiFilm 表 0x1431「Rating」；Canon 表里没有叫 Rating 的星级标签。[6]（官方标签文档；NCTG 表属于 Nikon 的视频容器，不代表 NEF 照片）
- Canon R 系视频：社区专家说存在 QuickTime:Rating，Lightroom 不读。[21]（第三方）
- Fujifilm：Lightroom 用户报告 X100VI、X-T5 的 RAF 机内星级能导入，GFX100RF 的 RAF 不能（2025-07，Adobe 员工说在调查，无结论）；该用户称 ExifTool、Photo Mechanic、FastRawViewer 能读出星级。[22]（官方论坛，未解决）
- Canon、Nikon、Sony 机内评星在 RAW 里写哪个标签、哪些软件认：未找到可靠来源。你们自己的 ImageIO 实测（ARW、NEF、CR3 以 `xmp:Rating` 给出）是目前最好的证据，但样张星级都是 0。

---

## 回答 A–E

### A. RAW 用 `basename.xmp` 的 `xmp:Rating`，是不是兼容性最好的选择？DNG 呢？

RAW：是。Adobe（Camera Raw 的小文件是「同名 + .xmp」[15]）、Lightroom Classic [11]、Bridge [14]、Capture One [24]、Photo Mechanic（RAW 默认写小文件 [32]）、FastRawViewer（默认 `名.xmp` [30]）、DxO（读 .xmp [26]）都用或读这个命名；darktable 读但不写这个名字 [27]；digiKam 要打开兼容选项才用这个名字 [29]。例外：RawTherapee 不读小文件 [36]（2019，较旧）。把握高。

三个使用上的坑，都有来源：
1. 扩展名要小写 `.xmp`。[19]
2. Lightroom 导入后不会自动重读，要手动「从文件读取元数据」。[12]
3. Capture One 的「自动同步」选「无」时，也要手动载入。[24]

DNG：
- Lightroom Classic 把 DNG 当作「写进文件本身」的格式。[11][18]
- Adobe 工程师说：Lightroom 在 DNG 小文件较新时会读，这是预期行为；小文件里有 `photoshop:SidecarForExtension` 且不是 DNG 时则忽略。[16] Camera Raw 默认也认 DNG 的小文件，除非勾了「忽略」。[15]
- Photo Mechanic 总是把评星写进 DNG，且不写小文件。[33][34] 它改了 DNG 之后，DNG 比小文件新，ACR 会忽略小文件。[34]
- Capture One 对 DNG：官方文章没区分；第三方说只读 DNG 需要 .xmp 在旁边。[40]
所以「DNG 只写 `basename.xmp`」大体能被 Adobe 读到，但不是 Adobe 的主路径，而且谁后写谁赢。不改 DNG 又相对安全的做法：仍写小文件，但（1）读取时同时看内嵌和小文件，取较新的（FastRawViewer 的做法 [30]）；（2）小文件里写 `photoshop:SidecarForExtension="DNG"`（依据 [16]，把握中，具体值写法要实测）。想让所有 Adobe 软件稳妥读到，只有写进 DNG，这违背「RAW 绝不改写」，由你们决定，建议做成可选项。把握中。

### B. JPEG / HEIC / TIFF / PNG 要不要额外写 Exif Rating、RatingPercent、MicrosoftPhoto:Rating？

- 微软官方说 `System.SimpleRating` 对 JPEG、TIFF 既读 Exif 0x4746 也读 `xmp:Rating`。[8] 所以只写内嵌 `xmp:Rating`，在官方文档层面 Windows 能读到 JPEG、TIFF 的 0–5 星。资源管理器界面上的「评分」列实际用哪一个属性：未找到可靠来源，需实测。
- 微软的 `System.Rating`（百分制）读 Exif 0x4749 和 `MicrosoftPhoto:Rating`。[7] 如果想让只认百分制的旧软件也读到，才需要写它们。`MicrosoftPhoto:Rating` 可以放在 XMP 包里，不需要动 Exif。
- HEIC、PNG：微软两份策略页都没列。[7][8] Windows 能否读：未找到可靠来源（第三方说法互相矛盾，没打开原文）。
- 风险有来源：两处值不一致时，不同软件显示不同。digiKam 的缺陷单里有个 JPEG：Exif 0x4746 是 4，XMP 是 3，digiKam 显示 4，预览显示 3。[47]（第三方）所以不要只写一处。
- 在 Exif 里加标签要重写 Exif 段，会破坏 spec S-06 的「除 XMP 块以外字节不变」；tech-design 已记录过 ImageIO 重写 Exif 会改数值。
建议：默认不新增 Exif 标签；但写星级时，如果文件里已经有 Exif Rating / RatingPercent / `MicrosoftPhoto:Rating`，应该一并改成同一个值，避免文件里出现两个互相矛盾的星级。把握中。

### C. 视频

有哪些位置能存：
1. 旁边的 .xmp：Adobe 的 XMP 规范例子里，视频小文件就是「同基名 + .xmp」。[2]
2. 内嵌 XMP：MP4 放在顶层 `uuid` 盒子里（UUID 为 BE7ACFCB-97A9-42E8-9C71-999491E3AFAC，最多一个）；MOV 放在 `moov` 里 `udta` 里的 `XMP_` 原子。[2]（官方规范）
3. QuickTime 键 `rating.user` 等：ExifTool 能读写 [5]，但我没找到任何软件文档说读它。未找到可靠来源。

谁读什么：
- Premiere：官方社区经理说星级是 XMP「Basic」元数据，支持内嵌的格式写进文件，别的格式写小文件。[20]
- Kyno：导出到 Premiere 时用 XMP「Basic > Rating」。[41] 但 Kyno 已停更。[42]
- digiKam：视频写小文件，开 ExifTool 时还写 XMP 和 QuickTime SharedUserRating。[29][46]
- Windows：开发者说 Windows 11 能显示。[46]
- 只在自己库里存的：Lightroom Classic [13]、Final Cut Pro（只有收藏 / 拒绝）[44]、Capture One（不能评星）[25]。
- Resolve：用户说不支持 XMP。[48]
- 机内视频星级（Canon R）在 QuickTime 里，Lightroom 不读。[21]

有没有两个主流软件都读的视频星级互通格式？我的结论：没找到。最接近的是「Adobe 的 XMP 约定」（Premiere 读写，加 Kyno / digiKam 这类第三方能写），但另一个主流软件（Final Cut Pro、Resolve、Lightroom、Capture One）都没有文档说读它。把握中（缺的是「没有文档」，不等于「一定不读」，需实测 Resolve 和 Final Cut Pro）。

如果要写进视频文件，具体写什么：在 MP4 顶层追加 / 替换一个 XMP `uuid` 盒子；在 MOV 的 `moov > udta` 下写 `XMP_` 原子；包里写 `xmp:Rating`。风险：
- 文件修改时间会变，Premiere 就因此被用户投诉。[20]
- 要改 `moov`（视频索引）时可能要重写整个文件头部和偏移量；把盒子追加到文件末尾理论上不动偏移，但这是我的推断，没有来源。
- 实况照片的 MOV 里有配对标识；写入后是否破坏配对：未找到可靠来源。
- 可能要把原文件整体拷贝一次（大视频很慢），断电保护要靠「写临时文件再替换」。
所以建议：视频默认继续用小文件；要写进文件时做成显式的可选项，并先在一份拷贝上实测。把握低到中。

### D. 小文件命名

对 RAW：`basename.xmp`（见 A）。
对非 RAW：
- `basename.xmp` 被这些读：Adobe 约定 [15]、Capture One [24]、FastRawViewer 默认 [30]、darktable（只读）[27]、digiKam（兼容选项）[29]、Immich（备选）[39]。
- `basename.ext.xmp` 被这些读：darktable（自己的格式）[27]、digiKam 默认 [29]、Immich（优先）[39]、FastRawViewer（可选）[30]。
- Immich 官方文档：两种都认，优先 `IMG_0001.jpg.xmp`，两个都在时用 `.jpg.xmp`。[39]
- Capture One 的小文件是同基名共用的：RAW+JPEG 同名共用一个。[24] FastRawViewer 对 RAW、DNG 同名抢一个文件会警告。[30]
结论：你们现有规则（非 RAW 优先 `basename.xmp`，同名冲突改 `basename.ext.xmp`）两边都有软件支持，实况照片 `IMG_1.HEIC` + `IMG_1.MOV` 用 `IMG_1.MOV.xmp` 是合理的；读取时两种名字都要认（你们已经这么做）。注意：视频小文件目前只有 Immich、digiKam、darktable 这类软件会读，Adobe 软件不读（Lightroom 不处理视频小文件，Premiere 具体认哪个名字：未找到可靠来源）。把握中。

### E. 当前方案里有没有会「主动破坏」别的软件行为的地方

1. 读取优先级「小文件优先」（R4-02）对 DNG 不安全：Photo Mechanic 之类会把星级直接写进 DNG，DNG 变新，ACR 就忽略较旧的小文件。[34] 建议 DNG 取较新者。把握中。
2. 写小文件会让 Capture One 把它当作同名所有文件的小文件。[24] 例如 RAW+JPEG 同基名，RAW 的 `名.xmp` 也会被 Capture One 当作 JPEG 的。对星级本身一般无害，但要知道。
3. 保留原修改时间（spec 写入规则）可能让 Lightroom / Bridge 发现不了「文件被外部改了」，因为它们判断是否「外部更改」的依据我没找到文档。推断，没有来源。必须实测（见下）。把握低。
4. 「0 与 -1」：`-1` 在 XMP 规范里是「拒绝」。[1] 你们读取时把 -1 当作未评星，没问题；但用户按 0（清除）时，如果文件里原来是 -1，直接写 0 或删除 Rating 项，会悄悄抹掉别的软件设的「拒绝」。建议：-1 的文件，按 0 不动它（或明确提示）。把握中。
5. 内嵌写入后，Photo Mechanic 论坛里有人提醒「有的软件会因内嵌元数据而报文件损坏」。[33]（论坛，身份未确认）这是风险提示，不是证据。
6. 「照片」把改过的 JPEG 当作已编辑：未找到可靠来源。照片导入的是副本，实测前不下结论。
7. 没有发现「写 `basename.xmp` 让 Lightroom 忽略内嵌元数据」的证据；相反，Lightroom 对非 RAW 的小文件整体就是忽略的。[30]

---

## 建议对方案做的修改

按收益从大到小：

1. DNG 的读取改为「内嵌和小文件都读，取较新者」，并在小文件里加 `photoshop:SidecarForExtension`。依据：[16][30][34]。把握中。
2. 保持默认：RAW 写小写 `basename.xmp`；JPEG、TIFF 写内嵌 `xmp:Rating`。第一次创建 RAW 小文件时的提示卡片（T12/T13）里加一句：Lightroom 里要「元数据 > 从文件读取元数据」才会看到新星级。依据：[11][12][15][19][24][30][32]。把握高。
3. 写星级时，如果 JPEG / TIFF 里已经存在 Exif Rating（0x4746）、RatingPercent（0x4749）或 `MicrosoftPhoto:Rating`，把它们同步成同一个值，避免不同软件显示不同。依据：[7][8][47]。把握中。
4. 对「一律使用旁边的 .xmp 小文件」选项，在设置说明里写明：Adobe 软件（Lightroom、Bridge）会忽略 JPEG 的小文件，所以这个选项只对 darktable、digiKam、FastRawViewer、Immich 这类软件有用。依据：[30]。把握高。
5. 不要新增「清除 -1」的行为：星级为 -1 的文件，按 0 保持不动，避免抹掉别的软件设的「拒绝」。依据：[1]。把握中。
6. 视频默认继续写小文件；另提供「把星级写进 MP4 / MOV 文件（Adobe XMP 约定）」的可选项，默认关，并明确说明会改文件修改时间。收益只有 Premiere、digiKam 这类软件；Lightroom、Capture One、Final Cut Pro 都用不上。依据：[2][13][20][25][41][44]。把握低到中。
7. 写 `basename.xmp` 命名为非 RAW 默认；冲突时 `basename.ext.xmp`。保留。读取时两种名字、大小写都认。依据：[2][24][27][29][30][39]。把握中。
8. 可选：在 XMP 包里额外写 `MicrosoftPhoto:Rating`（百分制 1/25/50/75/99），不动 Exif，供 Windows 旧软件读。依据：[7][9]。把握低（Windows 实际表现要实测）。
9. 机内评星：读取 Fujifilm RAF 时，如果 ImageIO 读不到，再读 Fujifilm 厂商标签 0x1431 作补充。依据：[6][22]。把握低（只有 ExifTool 标签表和一个用户帖，没有读取实测）。

---

## 仍需实测

下面这些只能用真软件试。每条给出具体步骤。

1. Lightroom Classic 读一览写的最小小文件。
   步骤：准备一张 ARW，用一览评 4 星，生成只含 `xmp:Rating` 的 `名.xmp`；用 Lightroom Classic 导入到新目录库。看：星级是否为 4；开发参数是否保持默认；再在一览里改成 2 星，回到 Lightroom 看是否出现「元数据已被外部更改」图标，选「从文件读取元数据」后是否变 2 星。
2. 保留修改时间会不会让 Lightroom / Bridge 看不到变化。
   步骤：一张已导入 Lightroom 的 JPEG，用一览改星级并保留原修改时间；回到 Lightroom 看是否有「已被外部更改」图标；再用不保留修改时间的方式重复一次，对比。Bridge 同样测一遍（预览缓存是否更新）。
3. DNG 的小文件和内嵌谁赢。
   步骤：同一张 DNG，（a）内嵌星级 3、小文件星级 5、小文件较新；（b）反过来，DNG 较新；（c）小文件里加 `photoshop:SidecarForExtension`。分别在 Lightroom Classic、Bridge / Camera Raw、Capture One、FastRawViewer 里看显示。
4. Capture One 读 HEIC、PNG、TIFF 的内嵌 `xmp:Rating`；读视频小文件。
   步骤：各准备一张写好星级的文件，导入新目录库，看星级；视频文件放同名小文件，看是否能显示、能否评星。
5. Windows 读法。
   步骤：把一览写过星级的 JPEG、TIFF、HEIC、PNG、MP4 拷到 Windows 11，在资源管理器「详细信息」里看「评分」列；再对 JPEG 加写 `MicrosoftPhoto:Rating`，对比。再用 Windows 在资源管理器里给 JPEG 改星级，用 ExifTool（`exiftool -a -G1 -Rating* -XMP:Rating* 文件`）看 Windows 实际写了哪几个标签。
6. 「照片」app 导入。
   步骤：JPEG、HEIC 各一张带内嵌星级；另一张 RAW 配 `.xmp`；导入「照片」，看有没有星级、有没有被当作已编辑（「照片」里的「已编辑」标记）。再把文件拖到「照片」之外改星级后重新导入，看是否重复。
7. Finder / 预览 / 快速查看 / Spotlight。
   步骤：JPEG 写内嵌星级后，终端运行 `mdls -name kMDItemStarRating 文件`；打开预览的检查器（元数据 > IPTC / Exif）看是否显示；对 MP4 同样试。
8. Premiere 的实际行为。
   步骤：在 Premiere 里给一个 MP4 和一个 MOV 评星；用 `exiftool -a -G1 -XMP:Rating 文件` 看是否写进文件；看旁边是否出现小文件、叫什么名字（`名.xmp` 还是 `名.mp4.xmp`）。再把一览写的 `名.xmp` 放到视频旁，Premiere 是否读到。
9. DaVinci Resolve 和 Final Cut Pro 是否读视频的 XMP。
   步骤：给 MP4 写内嵌 `xmp:Rating` 和同名 `.xmp` 小文件两种，分别导入，看有没有星级、收藏标记；Final Cut Pro 看 1–5 星是否映射成收藏。
10. 机内评星。
    步骤：各用 Canon、Nikon、Sony、Fujifilm 机身评星拍几张 RAW 和 JPEG 以及一段视频；运行 `exiftool -a -G1 -s -*rating*` 看标签落在哪；再导入 Lightroom Classic、Capture One 看是否显示。顺便确认 Canon R 视频是 `QuickTime:Rating` 还是别的名字（ExifTool 的 `rtng` 是内容分级，不是星级）。
11. 视频写进 MP4 / MOV 文件的安全性。
    步骤：在一份拷贝上追加 XMP uuid 盒子，用 QuickTime Player、Final Cut Pro、Premiere、Resolve、`ffprobe`、照片（实况照片的 MOV）都打开；检查能否播放、是否破坏实况照片配对、文件大小和修改时间。
12. -1（拒绝）的往返。
    步骤：在 Lightroom 里把照片标成「拒绝」并保存到 XMP，看小文件里是 `xmp:Rating="-1"` 还是别的写法；再用一览按 0 清除，看 Lightroom 读回是什么。

---

## 来源清单

访问日期：2026-11-18。「级别」：官 = 官方文档；工 = 官方论坛或工作人员答复；三 = 第三方 / 用户报告。打开方式里「正文」指直接取得页面正文；「转文本」指通过公开的网页转文本服务取得正文。

| 编号 | 级别 | 来源和日期 | URL |
| --- | --- | --- | --- |
| 1 | 官（镜像） | Adobe XMP Specification Part 1（xmp:Rating 定义；镜像站托管的 Adobe PDF，版权页 2020–2022） | https://dl.photoprism.app/pdf/specifications/20120101-Adobe_XMP_Specification_Part_1.pdf |
| 2 | 官（镜像） | Adobe XMP Specification Part 3（小文件命名、MP4 / MOV 嵌入；Adobe 2020） | https://dl.photoprism.app/pdf/specifications/20120101-Adobe_XMP_Specification_Part_3.pdf |
| 3 | 官 | ExifTool XMP 标签表（Rating、RatingPercent） | https://exiftool.org/TagNames/XMP.html |
| 4 | 官 | ExifTool EXIF 标签表（0x4746、0x4749） | https://exiftool.org/TagNames/EXIF.html |
| 5 | 官 | ExifTool QuickTime 标签表（rating.user、rtng、rate） | https://exiftool.org/TagNames/QuickTime.html |
| 6 | 官 | ExifTool 厂商标签表：Nikon、Sony、FujiFilm、Canon | https://exiftool.org/TagNames/Nikon.html ；https://exiftool.org/TagNames/Sony.html ；https://exiftool.org/TagNames/FujiFilm.html ；https://exiftool.org/TagNames/Canon.html |
| 7 | 官 | 微软 System.Rating 照片元数据策略（更新 2025-03） | https://learn.microsoft.com/en-us/windows/win32/wic/-wic-photoprop-system-rating |
| 8 | 官 | 微软 System.SimpleRating 照片元数据策略（更新 2025-03） | https://learn.microsoft.com/el-gr/windows/win32/wic/-wic-photoprop-system-simplerating |
| 9 | 官 | 微软 System.Rating 属性（1–99 与星的对应；转文本） | https://learn.microsoft.com/en-us/windows/win32/properties/props-system-rating |
| 10 | 官 | Adobe：Save metadata to external sidecar files（Lightroom Classic 15.0 ACR 小文件；转文本） | https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/create-xmp-acr-files.html |
| 11 | 官 | Adobe：Metadata basics and actions（Lightroom Classic；含 15.0、13.0 变化；转文本） | https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/metadata-basics-actions.html |
| 12 | 官 | Adobe：Advanced metadata actions（外部更改图标、从文件读取元数据；转文本） | https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/advanced-metadata-actions.html |
| 13 | 官 | Adobe：Work with video in Lightroom Classic（视频元数据只存目录库；转文本） | https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/video-lightroom.html |
| 14 | 官 | Adobe：About metadata（Bridge；转文本） | https://helpx.adobe.com/bridge/desktop/organize-and-find-files/tag-and-find-files/about-metadata.html |
| 15 | 官 | Adobe：Manage Camera Raw settings（小文件、DNG、忽略小文件；转文本） | https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/camera-raw-settings.html |
| 16 | 工 | Adobe 社区：LrC reads metadata for a DNG from an associated sidecar（Thomas Knoll，2022-09） | https://community.adobe.com/t5/lightroom-classic-discussions/lrc-reads-metadata-for-a-dng-from-an-associated-sidecar/m-p/13205271/highlight/true |
| 17 | 三 | Adobe 社区：Does LR Classic 13 support HEIC XMP metadata（社区资深用户，2023-10） | https://community.adobe.com/t5/lightroom-classic-discussions/does-lr-classic-13-support-heic-xmp-metadata/m-p/14189255 |
| 18 | 三 | Adobe 社区：If LrC is set to automatically write changes to XMP ... DNG（2023-02，另含 PNG 说明） | https://community.adobe.com/t5/lightroom-classic-discussions/dng-and-xmp/m-p/13559194 |
| 19 | 三 | Adobe 社区：Doesn't read star rating from XMP file (Mac)（小写 .xmp，2024-01） | https://community.adobe.com/t5/lightroom-classic-discussions/doesnt-read-star-rating-from-xmp-file-mac/m-p/14348803/highlight/true |
| 20 | 工 | Adobe 社区：Premiere 设置星级会改视频文件修改日期（社区经理答复，2025-09-05） | https://community.adobe.com/t5/premiere-pro-bugs/urgent-bug-setting-the-rating-changes-the-video-file-modification-date-on-disk/idi-p/15492249 |
| 21 | 三 | Adobe 社区：Canon R 机内视频星级导入 LrC 丢失（2024-04 至 2025-10） | https://community.adobe.com/questions-675/rating-videos-on-camera-canon-r-stars-don-t-survive-import-to-lr-classic-976090 |
| 22 | 工 | Adobe 社区缺陷区：GFX100RF 机内星级未导入（Adobe 员工在调查，2025-07 至 2025-10） | https://community.adobe.com/bug-reports-679/p-in-camera-star-ratings-from-fujifilm-gfx100rf-not-importing-662280 |
| 24 | 官 | Capture One：Metadata in XMP sidecar files（无日期；转文本） | https://support.captureone.com/hc/en-us/articles/360002544898-Metadata-in-XMP-sidecar-files |
| 25 | 工 | Capture One 支持：Rating and tagging 页面评论里的版主答复（视频只能播放；日期未取得；转文本） | https://support.captureone.com/hc/en-us/articles/360002743718-Rating-and-tagging |
| 26 | 官 | DxO：How can I ensure that my image ratings and metadata are correctly synchronized ...（v5 及以后；转文本） | https://support.dxo.com/hc/en-us/articles/6640759778333 |
| 27 | 官 | darktable 4.4 手册：importing sidecar files generated by other applications | https://docs.darktable.org/usermanual/4.4/en/overview/sidecar-files/sidecar-import/ |
| 28 | 官 | darktable 5.6 手册：sidecar files、偏好 > 存储、导入模块（转文本） | https://docs.darktable.org/usermanual/stable/en/overview/sidecar-files/ ；https://docs.darktable.org/usermanual/stable/en/preferences-settings/storage/ ；https://docs.darktable.org/usermanual/stable/en/module-reference/utility-modules/lighttable/import/ |
| 29 | 官 | digiKam 手册：Metadata Settings | https://docs.digikam.org/en/setup_application/metadata_settings.html |
| 30 | 官（旧） | FastRawViewer 手册（1.7 版）：Metadata: Ratings, Labels, Title, and Description | https://www.fastrawviewer.com/usermanual15/xmp-metadata |
| 31 | 工 | FastRawViewer 官方论坛：Rating and labels from FRV in Lightroom（开发方答复，2022-08；转文本） | https://www.fastrawviewer.com/node/892 |
| 32 | 官 | Photo Mechanic：IPTC/XMP Preferences（转文本） | https://docs.camerabits.com/support/solutions/articles/48001146198-iptc-xmp-preferences |
| 33 | 三 | Camera Bits 论坛：PM always is producing XMP-files（回答者身份未确认；日期未取得；转文本） | https://forums.camerabits.com/index.php?topic=13047.0 |
| 34 | 三 | 问答站：Photo Mechanic ratings 与锁定 DNG（用户自测） | https://www.uniquephoto.com/community/qa/why-do-photo-mechanic-ratings-break-adobe-camera-raw-edits-on-locked-dng-files |
| 35 | 三 | 问答站：能否把星级直接写进 NEF（无关键结论，未引用） | https://www.uniquephoto.com/community/qa/can-star-ratings-be-written-directly-into-a-nikon-nef-file-instead-of-using-xmp-sidecars |
| 36 | 三（旧） | pixls.us 论坛：RawTherapee 5.7 can't read rating from XMP（2019-11） | https://discuss.pixls.us/t/rawtherapee-5-7-cant-read-rating-from-xmp/14902 |
| 37 | 官 | ACDSee Photo Studio for Mac 更新日志（2022-11 至 2026-05） | https://www.acdsee.com/en/support/photo-studio-mac/changelog/ |
| 38 | 工 | XnView 论坛：Saving ratings in both jpeg metadata and sidecar simultaneously（作者答复，2024-05 至 2026-01） | https://newsgroup.xnview.com/viewtopic.php?p=206692 |
| 39 | 官 | Immich 文档：XMP sidecars（小文件命名、xmp:Rating） | https://docs.immich.app/features/xmp-sidecars |
| 40 | 三 | Pixelmator 支持：Importing flags and ratings from other apps into Photomator | https://support.pixelmator.com/faq-photomator/advanced-workflows/importing-flags-and-ratings-from-other-apps-into-photomator |
| 41 | 官（旧） | Kyno（Lesspain）：How Kyno metadata gets translated to FCP7, FCPX and Premiere Pro（2019-11；转文本） | https://lesspain.freshdesk.com/support/solutions/articles/12000021994-how-kyno-metadata-gets-translated-to-fcp7-fcpx-and-premiere-pro-metadata |
| 42 | 三 | NeoFinder 手册：KYNO Metadata（Kyno 存储位置、2021 被收购；转文本） | https://www.cdfinder.de/guide/22/22.10/catalog_KYNO.html |
| 43 | 官 | Apple：Add titles, captions, and more to photos and videos on Mac（评星控件） | https://support.apple.com/en-au/guide/photos/phta4e5a733f/mac |
| 44 | 官 | Apple：Rate clips in Final Cut Pro for Mac | https://support.apple.com/en-gb/guide/final-cut-pro/ver30ccd91f/mac |
| 45 | 官 | Apple：Add star ratings ... in Photos on iCloud.com | https://support.apple.com/guide/icloud/mm54e2d3fb7a/icloud |
| 46 | 工 | KDE 缺陷单 500178：digiKam 视频星级（开发者答复，2025-02-16） | https://bugs.kde.org/show_bug.cgi?id=500178 |
| 47 | 三 | KDE 缺陷单 446183：Exif 与 XMP 星级不一致，预览显示 XMP 值（2021-11） | https://bugs.kde.org/show_bug.cgi?id=446183 |
| 48 | 三 | Blackmagic 论坛：XMP metadata support（用户帖，日期未取得；转文本） | https://forum.blackmagicdesign.com/viewtopic.php?p=775388 |
| 50 | 三 | 问答站转载：Bridge 给部分 JPEG 生成 .xmp（ACR 16.3.1，ACR 17.0 / Bridge 15.0 修复） | https://www.uniquephoto.com/community/qa/why-is-adobe-bridge-creating-xmp-sidecars-for-some-jpeg-files-instead-of-writing-metadata-into-the-jpeg |

（编号 23、49 在整理中合并或弃用，故空缺。）

### 只见搜索摘要、没有打开（正文没有当依据）

- ExifTool 论坛关于 Rating、RatingPercent、Windows 资源管理器行为的帖子（论坛当时无法访问）。
- Adobe 帮助站 Premiere Pro 元数据页、Lightroom 云端版元数据页（打不开或不存在）。
- Capture One 社区：Fujifilm RAF 机内星级、Sony A7 III 星级丢失、「完全同步」与星级回退。
- ON1 官方博客关于 XMP 小文件的旧文章。
- DaVinci Resolve 手册里的 CSV 元数据导入导出。
- Apple 社区关于「照片」导入 XMP 的帖子（页面是维护占位页）。
- 第三方教程：Windows 对 MP4 评分、预览检查器 IPTC > StarRating、Finder 不显示评分。
- darktable 论坛、Photomator、pixls.us 上关于 Bridge 星级未读入 darktable 的帖子。

---

## 统计（供核对）

- 实际打开并读到正文的来源：约 48 个页面（含 4 个 ExifTool 厂商标签页、3 个 darktable 手册页作为一组）。
- 报告中标「未找到可靠来源」的单元格和结论：全文共 40 行含该词（矩阵单元格和正文结论合计）。
- 没有来源、纯属我的推断，已在正文标注「推断」的：3 处（追加 uuid 盒子不动偏移；保留修改时间可能让 Lightroom 看不到变化；实况照片 MOV 写入后配对）。
