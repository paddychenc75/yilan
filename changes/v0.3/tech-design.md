# 一览 v0.3 技术方案（tech-design）

状态：草稿，待评审（2026-11-17）。依据 `prd.md`、`design/`、`spec.md`。所有「实测」数字来自 2026-11-17 在本机（Apple M3 Max，16 核，**macOS 27.2.1**，Xcode 27.0，Swift 6.4）用 `app/Fixtures` 里的公开授权素材做的实验，实验代码是一次性的，没有进仓库（第 7 节）。

## 1. 目标和范围

给文件评星并和 Lightroom 等软件互通，按星级、格式筛选，缩放控件移到顶部栏，修复双击标题栏，加入更新提醒。对应 PRD：R1–R9、R5a、R5b、E1、B1、U1–U7，以及 4.2–4.5 的规则。

## 2. 影响的模块和文件

沿用现有结构：`App`、`Imaging`、`Model`、`Stage`、`Views`、`Resources`。新增两个目录：`Metadata/`（**所有读写用户文件的星级代码只在这里**）和 `Update/`（更新检查）。`project.yml` 用目录做源，不用改，只需 `xcodegen generate`。

### 2.1 新增

| 文件 | 内容 |
| --- | --- |
| `Metadata/RatingFileIO.swift` | 唯一对外入口：`read(_:sidecars:) -> RatingInfo`、`write(_:to:mode:sidecars:) throws -> RatingWriteResult`、`sidecarURL(for:in:)`。其他模块不直接碰 XMP 和文件 |
| `Metadata/XMPPacket.swift` | 用 `XMLDocument` 读、改 XMP：按命名空间 URI 找 `xmp:Rating`（兼容旧前缀 `xap:`、属性写法和元素写法、多个 `rdf:Description`），改值 / 插入 / 删除，其他节点原样保留；判断「只剩星级」「由一览创建（`x:xmptk="Yilan …"`）」 |
| `Metadata/JPEGXMPWriter.swift` | 自己替换或插入 JPEG 的 XMP APP1 段，其他字节原样拷贝 |
| `Metadata/PNGXMPWriter.swift` | 自己替换或插入 PNG 的 `iTXt`（`XML:com.adobe.xmp`）块，算 CRC |
| `Metadata/ImageIOXMPWriter.swift` | HEIC / HEIF / TIFF：`CGImageDestinationCopyImageSource` + 合并元数据 |
| `Metadata/SafeReplace.swift` | 写同目录隐藏临时文件 → 自检 → `FileManager.replaceItemAt` → 用 `utimensat` 恢复原修改时间（纳秒）；错误统一映射成 `RatingWriteError.notWritable / .diskFull / .vanished / .other(String)` |
| `Metadata/SidecarIndex.swift` | 文件夹里所有 `.xmp` 的索引（小写文件名 → URL、修改时间、大小）和 spec S-04 的命名规则 |
| `Metadata/RatingWriter.swift` | `actor`：按文件排队、同一文件只写最新值、记录「一览自己写的」账本（OwnWriteLedger），退出时等待（S-20） |
| `Metadata/RatingLoader.swift` | 打开文件夹后在后台批量读星级：先当前文件，再附近，再其余；最多 4 个并发；每 100 毫秒批量交回主线程 |
| `Model/Rating.swift` | `RatingInfo`（值 0–5、来源、内嵌值）、`RatingStorageMode`（内嵌 / 一律小文件）、值解析（spec R4-03） |
| `Model/BrowseFilter.swift` | 筛选模型（见 4.3）：`FilterCriterion` 协议、`RatingCriterion`、`FormatCriterion`、`FormatGroup`、`BrowseFilter`、`FilterFacets`（各项数量） |
| `Model/UndoHistory.swift` | 删除和评星共用的撤销记录，替换 `TrashUndoStack` |
| `Model/BrowserModel+Rating.swift` | 打星、撤销评星、自动下一张、暂留、可写判断、提示卡片队列 |
| `Model/BrowserModel+Filter.swift` | 筛选状态、面板开关、重新计算结果列表、改筛选后的选中规则 |
| `Model/BrowserModel+Export.swift` + `Metadata/ExportService.swift` | 导出筛选结果（拷贝 / 移动、改名、带小文件） |
| `Update/AppVersion.swift` | 版本号解析和逐段比较 |
| `Update/ReleaseClient.swift` | `URLSession`（ephemeral）请求最新正式发布，解析 JSON |
| `Update/ReleaseNotes.swift` | 按语言取「## 中文 / ## English」段，失败回退全文；简化 Markdown 解析成块 |
| `Update/UpdateChecker.swift` | `@MainActor @Observable`：节流、跳过、稍后、小点、手动检查状态；仓库地址只在这里出现一次 |
| `Views/ZoomControl.swift` | 顶部缩放控件（完整 / 只留百分比）和它的菜单 |
| `Views/FilterButton.swift`、`Views/FilterPanel.swift` | 筛选按钮三种样子、弹出面板（分区可扩展） |
| `Views/StarBar.swift` | 画面五星胶囊、信息面板里的星、缩略图角标 `RatingBadge` |
| `Views/TopBarLayout.swift` | 顶部栏收缩档位的纯函数 + 实测宽度 |
| `Views/HintCard.swift` | 快捷键变化、.xmp、新版本三种提示卡片（同一个外观） |
| `Views/UpdateSheet.swift` | 更新说明表单、Markdown 块渲染 |
| `Views/ExportSheet.swift` | 导出表单 |

### 2.2 修改

| 文件 | 改什么 |
| --- | --- |
| `Model/BrowserModel.swift` | `items` 改为「类型 ∧ 筛选 + 暂留」；键盘：去掉单键 0 / 1 缩放，加 1–5 / 0 评星（按 keyCode，忽略按键重复）、Z、⌘0、⌘9、⌘F、Esc 顺序；`zoomPercent` 换成 `ZoomState`；`undoStack` 换成 `UndoHistory` |
| `Model/BrowserModel+Trash.swift`、`Model/Trash.swift` | `TrashEntry` 加可选的小文件（原位置、废纸篓位置），删除和撤销一起处理；删除后的选中按结果列表 |
| `Model/BrowserModel+Sync.swift`、`Model/FolderSync.swift` | `FolderDiff` 加小文件变化；对照 OwnWriteLedger 把一览自己写的文件当作「没变」；内嵌或小文件被其他软件改了 → 重读这些文件的星级 |
| `Model/FolderScanner.swift` | 扫描时顺便收集 `.xmp` 索引（`Result.sidecars`）；打开文件夹时清理超过 10 分钟的 `.yilan-*` 临时文件（S-08） |
| `Model/MediaItem.swift` | 加 `formatGroup`（RAW、HEIC、JPEG…） |
| `Model/AppSettings.swift` | 新键：`autoAdvanceAfterRating`、`ratingStorage`、`autoCheckUpdates`、`lastUpdateCheck`、`skippedVersion`、`cachedRelease`、`lastLaunchedVersion`、`didShowSidecarHint`、`lastExportFolder` |
| `App/YilanApp.swift` | 菜单（spec 第 14 节）；启动后 3 秒自动检查；`applicationShouldTerminate` 等待未写完的星级（最多 3 秒） |
| `Views/RootView.swift` | 顶部栏重排（缩放控件、筛选组、收缩）；五星胶囊；提示卡片；空结果卡片；更新表单、导出表单挂载；删除 `ZoomPill` |
| `Views/TitleBarControls.swift` | `CounterPill` 加「· ★4」；`ToolGroup` 的 ⋯ 菜单加更新项、缩放组、导出；小点 |
| `Views/ThumbnailDock.swift` | 左上角星级角标；渐隐区内不画（需要知道格子是否完整可见） |
| `Views/InfoPanel.swift`、`Model/InfoContent.swift` | 最上面加评星组；拷贝信息加评星行 |
| `Views/StateCards.swift` | 删 `ZoomPill`；加「没有符合条件的文件」卡片、检查更新小条 |
| `Views/SettingsView.swift`、`Views/ShortcutsPane.swift`、`Views/WelcomeAndDrop.swift` | 新设置项；快捷键列表改新按键 |
| `Stage/ImageStageView.swift` | 合入 `fix/titlebar-double-click`（5c04298）；`onZoomChanged` 改报 `ZoomState`（比例、是否适应窗口、能否再放大 / 缩小）；加「200%」指令 |
| `Resources/Localizable.xcstrings` | spec 第 15 节全部文案，中英文 |

## 3. 数据和文件格式决定

### 3.1 星级写在哪里（实测后的方案）

| 格式 | 写法 | 依据（第 7 节实验） |
| --- | --- | --- |
| JPEG | **自己写 XMP APP1 段**，不用 ImageIO 重写 | ImageIO 的 `CGImageDestinationCopyImageSource` 虽然画面数据逐字节不变，但会重写整个 EXIF：有理数被近似（曝光时间 12.769997 → 12.76999700419413）、丢掉 Interop 目录（Adobe RGB 相机 JPEG 靠它标色彩空间）、把扩展 XMP 合进主 XMP。自己写只动 XMP 段，其余字节全部一致 |
| PNG | **自己写 iTXt 块** | ImageIO 对没有 XMP 的 PNG 第一次写入**静默不写**（返回成功但读不到星级），还删掉了 eXIf 里的 ColorSpace |
| HEIC / HEIF | ImageIO `CGImageDestinationCopyImageSource`，`kCGImageDestinationMergeMetadata = true` | 63 个 hvc1 图块、grid、Exif 项逐字节不变，只有 XMP 项变了；清除不能用 kCFNull（无效），写 0 |
| TIFF | 同 HEIC | 条带数据逐字节不变，新增 XMP（700）和 IPTC（34377）标签；清除写 0 |
| RAW | .xmp 小文件 | PRD：RAW 绝不改写 |
| 视频、GIF、WebP、SVG、BMP | .xmp 小文件 | GIF 实测 ImageIO 明确拒绝（“not supported for lossless metadata modification”）；其余按 PRD |

小文件内容由 `XMPPacket` 生成和修改。**不用 ImageIO 改小文件**：实测它重新序列化时会改写语义（把 `exif:DateTimeOriginal` 变成了 `photoshop:DateCreated`）；`XMLDocument` 定点修改在同样的测试里一项不丢。读取小文件也用 `XMLDocument`（0.03–0.04 毫秒 / 个，比 ImageIO 的 0.09 毫秒快）。

被否决的方案：
- **全部用 ImageIO**：见上，JPEG 的 EXIF 被改、PNG 不可靠。
- **全部用小文件**：最安全，但 PRD 要求其他软件能读到 JPEG 等的星级（Lightroom 对 JPEG 只读文件内部），保留为设置选项。
- **只用正则替换文本**：碰到属性 / 元素两种写法、`xap:` 旧前缀、多个 Description 时容易错；`XMLDocument` 按命名空间处理更稳，速度也够。

### 3.2 写入细节

- JPEG：XMP 段放在 Exif APP1（没有就在 APP0 / SOI）后面、任何 APP2 前面。这样多图 JPEG（MPF，新 iPhone 的 HDR 增益图就是这种）里的偏移量不受影响。已有 XMP 段位于 MPF APP2 后面、XMP 包超过 65502 字节时，改用小文件（spec S-21、S-22）。扩展 XMP（`xmpNote:HasExtendedXMP`）原样保留。
- PNG：iTXt 放在第一个 IDAT 前；已有的压缩 iTXt XMP 不改，改用小文件。
- XMP 包：`<?xpacket begin=… ?>` 包裹，JPEG 留 512 字节空白（方便别的软件原地改），`x:xmptk="Yilan <版本>"` 只在一览新建时写。
- 清除：JPEG、PNG、小文件删掉 Rating 项；HEIC、TIFF 写 0；RAW 有机内星级时小文件写 0（spec S-12）。
- 两处一致（spec PD-05）：「写入文件内部」模式下，如果这个文件已经有带星级的小文件，写完内嵌后把小文件里的星级也改成同一个值（不新建小文件）；「一律小文件」模式绝不碰图片本身。
- 自检（替换前，对临时文件）：ImageIO 读回的 Rating 等于目标值；图片数量、像素宽高、方向不变；原有辅助图（HDR 增益图、深度图）还在；原 XMP 的全部属性（拍平成「命名空间|路径=值」的集合）除 Rating 外一项不少。任何一项不合格 → 删临时文件，改写小文件（S-21）。
- 修改时间：`stat` 取原文件 `st_mtimespec`，替换后 `utimensat` 写回（实测 `FileManager.setAttributes` 只保留到微秒，纳秒部分会丢）。
- 替换：`FileManager.replaceItemAt`。实测保留创建时间、权限、扩展属性（自定义 xattr 和 `com.apple.provenance` 都在）；inode 会变（文件编号变，路径不变，`FolderDiff` 按路径匹配不受影响）。

### 3.3 读取

- 来源和先后：spec R4-01 ~ R4-03。内嵌用 `CGImageSourceCopyMetadataAtIndex` + `xmp:Rating`（`kCGImageSourceShouldCache = false`）；实测 ARW、NEF、CR3 的机内星级 ImageIO 会以 `xmp:Rating` 给出（样张都是 0），RAF、DNG 样张没有这一项。
- RAW 有小文件时不读内嵌（省下 RAW 头部读取）。
- 小文件索引在扫描文件夹时一次列出（实测列 3000 项目录 6 毫秒），之后按名字查，不再逐个 `fileExists`。

### 3.4 星级在内存里的样子

- `BrowserModel.ratings: [URL: RatingInfo]`，和 `MediaItem` 分开。`MediaItem` 的相等判断包含大小和文件编号，把星级放进去会让「当前文件」频繁变成「另一个文件」触发重新加载。
- 一览自己写完后，不更新 `allItems` 里的 `MediaItem`（大小会差几 KB），由 OwnWriteLedger 让文件夹同步把它当作没变。代价：信息面板和底部的文件大小在下次打开文件夹前可能差几 KB（显示到 0.1 MB，基本看不出）。好处：解码缓存（按路径 + 修改时间）、缩略图磁盘缓存（按路径 + 修改时间 + 大小）都继续命中，当前图片不重载、不闪。

### 3.5 小文件命名（spec S-04，待定 PD-04）

RAW → `同名.xmp`；其他文件 → 已有 `完整名.xmp` 就用它，否则文件夹里没有同名的其他支持文件时用 `同名.xmp`，有就用 `完整名.xmp`。读取：非 RAW 先找 `完整名.xmp`，再在没有同名冲突时找 `同名.xmp`。

## 4. 数据流

### 4.1 打星

```
按键 / 点星 ──► BrowserModel.setRating(n, for: item)
   ├─ 不可写 / 不能评星 → 提示，结束
   ├─ ratings[url] = n（界面 0.1 秒内更新）；UndoHistory.push(.rating(url, old, new))
   ├─ 筛选中且不再符合 → 记为暂留（F-01）
   ├─ 自动下一张（R8）
   └─ RatingWriter.enqueue(url, n, mode, sidecars)   ← actor，后台
            └─ RatingFileIO.write → SafeReplace / 小文件
                 ├─ 成功：OwnWriteLedger 记下（路径、新大小、修改时间）；第一次建 RAW 小文件 → 主线程排 .xmp 提示
                 └─ 失败：主线程把 ratings[url] 恢复成写之前的值、撤销记录里删掉这一条、提示（10 秒去重）
```

同一文件排队时只保留最后一个值（R1-11）；退出时 `applicationShouldTerminate` 返回 `.terminateLater`，等写完或 3 秒。

### 4.2 打开文件夹和读取

`FolderScanner.open` → `apply(result)`（和 v0.2 一样先显示第一张）→ 首张图显示（`Perf.shown`）或 300 毫秒后，以较早者为准 → `RatingLoader` 开始：当前文件 → 当前 ±50 → 其余；`AsyncLimiter(limit: 4)`，`.utility` 优先级；结果每 100 毫秒合并一次写进 `ratings`（避免 2000 次界面刷新）。换文件夹时取消。

### 4.3 筛选模型（可扩展）

```swift
protocol FilterCriterion: Sendable, Equatable {
    var isActive: Bool { get }
    func matches(_ facts: ItemFacts) -> Bool      // ItemFacts = MediaItem + 星级（以后加色标、日期）
}
struct RatingCriterion: FilterCriterion { enum Mode { case any, atLeast(Int), unrated } }
struct FormatCriterion: FilterCriterion { var selected: Set<FormatGroup> }   // 组内「或」
struct BrowseFilter: Equatable { var rating: RatingCriterion; var format: FormatCriterion
    var activeKinds: Int   // 摘要「筛选 · 2」的数字
    func matches(_ f: ItemFacts) -> Bool }        // 各条件之间「且」
struct FilterFacets { /* 每个分区的数量 = 类型 + 其他分区条件下的数量（不含自己） */ }
```

- 结果列表 = `allItems.filter { type.includes($0) && filter.matches(facts($0)) }`，暂留文件按原位置插回。
- 加一种新筛选（例如色标）：新增一个 `FilterCriterion`、`BrowseFilter` 加一个字段、`FilterFacets` 加一组数量、面板加一个分区视图；按钮、摘要、清除筛选、导出不用改。
- 2000 个文件一次过滤 + 全部数量是几次线性扫描，预计 < 5 毫秒（测试里用 `measure` 卡 20 毫秒上限）。
- 类型切换（`MediaFilter`）保持原样，不并进 `BrowseFilter`，避免改动 v0.2 的记忆和菜单行为。

### 4.4 撤销模型

```swift
enum UndoEntry { case trash(TrashEntry)           // TrashEntry 增加 sidecar: (original: URL, trashed: URL)?
                 case rating(url: URL, old: Int, new: Int) }
struct UndoHistory { entries（最多 100）; var menuTitle; push; pop; removeAll }
```

- ⌘Z / 菜单 / 提示条「撤销」都调用 `undoLast()`，按类型分派到 `undoDelete` 或 `undoRating`。
- 撤销评星 = 再走一次 4.1 的写入（目标是 old），但不进撤销记录、不触发自动下一张。
- 换文件夹时 `removeAll()`（v0.2 已有的规则扩展到评星）。
- 不用 `NSUndoManager`：现有删除撤销是自己的栈，菜单文字也要自定义，统一成一个栈更简单。

### 4.5 文件夹同步

`FolderWatcher`（FSEvents，0.3 秒合并）本来就对文件夹里任何变化触发。扫描结果多带 `sidecars`：
1. 对比媒体文件：`modified` 里命中 OwnWriteLedger（同路径、同大小、同修改时间）的，当作没变并从账本删掉；其余照 v0.2 处理，另外加入「需要重读星级」。
2. 对比小文件索引：新增、删除、修改的小文件 → 找到它的主人 → 重读星级。一览自己写的小文件同样先查账本。
3. 重读结果更新 `ratings`；当前文件不再符合筛选就暂留。

### 4.6 更新检查

```
启动 3 秒后（自动检查开、距上次成功 ≥ 24 小时）或手动
  └─ ReleaseClient.latest()  GET https://api.github.com/repos/paddychenc75/yilan/releases/latest
        请求头只有：User-Agent: Yilan-Update-Check、Accept: application/vnd.github+json、Accept-Language: en
        URLSessionConfiguration.ephemeral，urlCache = nil，不发 Cookie，超时 15 秒
  └─ 200：draft / prerelease 为真 → 当作没有新版本；tag_name 解析失败 → 同上
     404：没有发布 → 已是最新；其他状态码、网络错误、JSON 错误 → 失败
  └─ 比较版本 → 保存 cachedRelease（tag、正文、html_url、published_at）和 lastUpdateCheck
  └─ UpdateChecker 决定：提示卡片（排队，见 spec U2-03）/ 小点 / 打开表单 / 提示条
```

- 显式设置 User-Agent 和 Accept-Language：实测 `URLSession` 默认会发出 `Accept-Language: zh-CN,zh-Hans;q=0.9` 和 `User-Agent: <程序名> CFNetwork/3896.200.61 Darwin/27.2.0`，前者是用户语言、后者是系统版本，PRD 要求不带。GitHub 要求必须有 User-Agent（实测空 UA 返回 403）。
- 不用 ETag 条件请求：实测未登录时 304 照样计入限额（used 2 → 3），对每天一次的检查没有好处。
- 正文渲染：块级（`#`–`######` 标题、`-` / `*` / `1.` 列表、段落）自己按行解析；行内（粗体、行内代码、链接）用 `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`；链接点击经过过滤，只放行 http / https。不使用 WebView，不加载图片。
- 语言：`LanguageSettings.runningLanguage`（一览当前界面语言），不是系统语言。
- 测试替身：`ReleaseClient` 接受注入的 `URLSession`（测试里用 `URLProtocol` 桩）；调试用启动参数 `--update-feed=<本地 JSON 路径>` 可以模拟新版本、预发布、草稿、格式不对的说明，不连 GitHub。
- 以后上架 App Store：`UpdateChecker.isAvailable` 一处关掉，菜单项和设置组随之隐藏。

### 4.7 顶部栏收缩

`TopBarLayout.tier(width:, measured:)` 是纯函数：输入窗口宽度和各控件实测宽度（`PreferenceKey` 报上来），从最宽的档位往下找第一个「左组 + 中组 + 右组 + 间距 ≥ 14」放得下的档位，顺序固定为 spec E1-10 的 ①–⑥。中文下用设计稿给的控件宽度做单元测试，应得到 1260 / 1180 / 1050 / 940 / 890 / 730 这组阈值（±10）；英文另测不重叠（spec E1-11、PD-03）。

## 5. 对用户文件的风险和防护

| 写入点 | 最坏情况 | 防护 | 怎么证明 |
| --- | --- | --- | --- |
| 内嵌写星级（JPEG / PNG / HEIC / TIFF） | 原图损坏、画质下降、其他元数据丢失 | 只改 XMP；临时文件 + 自检 + 原子替换；自检不过不替换（回退小文件）；修改时间纳秒级恢复 | 单元测试：每种格式写入 → 解码像素逐字节相同；JPEG / PNG 去掉 XMP 段后整个文件逐字节相同；HEIC 每个图块逐字节相同；EXIF / GPS 字典相同；修改时间相同；连续写 4 次后仍成立 |
| 写到一半断电 / 被杀 / 磁盘满 | 半截文件 | 临时文件写完才替换；`replaceItemAt` 是原子换名；残留的隐藏临时文件下次打开清理 | 实测磁盘满：写临时文件报 ENOSPC，原文件 SHA-1 不变、无残留；测试里注入「写一半失败」 |
| 只读磁盘、写保护卡、无权限 | 崩溃或假装成功 | 打开文件夹时预判（`volumeIsReadOnly`、目录可写）；写入错误映射成 notWritable，界面回滚 | 实测只读磁盘映像：`volumeIsReadOnly = true`，写入报 NSCocoaError 642 / EROFS；`CGImageDestinationCreateWithURL` 在只读卷上直接返回 nil（没有错误信息），所以先预判；测试用 `chmod 555` 临时目录 |
| 修改已有小文件 | 丢掉 Lightroom 调色参数 | `XMLDocument` 定点改，前后拍平比较，除 Rating 外不少一项，少了就不写 | 单元测试用 Lightroom 风格、darktable 风格、Capture One 风格的合成 XMP（自己写的文本，不是用户文件） |
| 删除一览建的小文件（清除星级） | 删掉别人的小文件 | 只删 `x:xmptk` 以「Yilan」开头且清除后不剩任何属性的 | 单元测试：别人建的、只有 Rating 的小文件清除后保留 |
| 清理 `.yilan-*` 临时文件 | 删掉用户文件 | 只匹配一览自己的命名（`.yilan-` + UUID + 原扩展名），且超过 10 分钟 | 单元测试：相似名字的文件不删 |
| 删除到废纸篓带上小文件 | 小文件丢失 / 误删共用小文件 | 进废纸篓（可恢复）；两个 RAW 共用时不动；撤销一起放回 | 测试用现有假废纸篓（`TrashService.fakeTrashDirectory`） |
| 导出（拷贝 / 移动） | 覆盖目标文件、移动中途失败丢文件 | 同名加序号不覆盖；跨盘移动是拷贝完整后再删原文件（`FileManager.moveItem` 跨卷即如此）；逐个处理，失败的原文件不动 | 测试：重名、目标只读、跨卷（磁盘映像） |
| 外置盘 FAT / exFAT | 修改时间精度、`._` 文件 | 实测 exFAT、FAT32 磁盘映像上 JPEG、HEIC 写入成功、修改时间不变；系统会生成 `._文件名`（AppleDouble，存扩展属性，cp 也会生成），属系统行为 | 手动测试步骤 |
| 网络盘、iCloud Drive | 替换不原子或失败 | 失败按 T11 提示，原文件不动；不做特殊处理 | 未实测，列入风险 |

## 6. 性能

- **打开 2000 个文件**：星级读取推迟到首张图显示之后，并发 4、`.utility`。实测读取耗时（缓存热，见第 7 节 d）：RAW 内嵌单线程每个 1.2–2.8 毫秒（2000 个 5.7 秒），16 线程并行 0.29 毫秒（0.58 秒）；JPEG / HEIC 0.28 / 0.59 毫秒；小文件 0.03 毫秒。按 4 并发估算 2000 个 RAW 约 1.5–2 秒读完；有小文件的 RAW 不读内嵌，只要几十毫秒。
- **测量方法（验收 R4-05）**：用现有 `Perf` 打点「open → 首张显示」，2000 个 RAW（用 `cp -c` 从 `Fixtures/raw` 克隆，不占空间）在 v0.2.1 和 v0.3 各跑 5 次取中位数，差异 < 50 毫秒算通过；另外记录星级全部读完的时间。
- **连续切图、连续打星**：打星只改内存字典，写入在 actor 里；同一文件合并。实测单次写入：ImageIO 路径 1.2–7.8 毫秒，自写路径在内存中 0.3–2.1 毫秒（不含磁盘）。`ratings` 是一个字典，缩略图格子只读自己那一项；读取批量合并，避免 2000 次刷新。
- **筛选 0.3 秒（验收 R6-04）**：过滤 + 数量 < 5 毫秒；缩略图栏换数据源。测试用 2000 个合成 `MediaItem` 卡 20 毫秒；界面另用 `Perf` 打点「点星 → 缩略图栏更新」手测。
- **更新检查**：启动 3 秒后在后台，网络超时 15 秒，不占主线程。

## 7. 开发前必须先用实验验证的事（已做，结果如下）

所有实验都在复制到临时目录的素材上做（`app/Fixtures/sample` 和本地的 `app/Fixtures/raw`，均为 CC0），实验代码在会话临时目录，没有进仓库。

**a. RAW 旁边的 .xmp 小文件** — 通过（用 `XMLDocument` 方案）
- 本地有 5 个 RAW 样张（ARW、RAF、NEF、DNG、CR3，CREDITS.md 已登记，不进仓库）。
- 新建：生成只含 `xmp:Rating` 的小文件，ImageIO 读回正确。
- 更新已有小文件：用一个仿 Lightroom 的小文件（crs 调色参数、色调曲线序列、xmpMM:History 结构数组、dc:subject、dc:title 多语言、lr:hierarchicalSubject、未知命名空间）和一个仿 darktable + Capture One 的小文件（两个 `rdf:Description`、xpacket 包裹）测试：
  - ImageIO（`CGImageMetadataCreateFromXMPData` → 改 → `CGImageMetadataCreateXMPData`）：Lightroom 那份 32 项不丢；darktable 那份**丢了 `exif:DateTimeOriginal`、凭空多出 `photoshop:DateCreated`**，还去掉了 xpacket 包裹、改写了 `x:xmptk`。**否决**。
  - `XMLDocument` 定点修改：两份都一项不丢、不多，xpacket 保留；排版（空白、属性换行）有变化。**采用**。
- RAW 本身：前后内容和修改时间都不变。

**b. JPEG 内嵌星级** — ImageIO 只做到一半；自己写 XMP 段完全通过
- ImageIO `CGImageDestinationCopyImageSource` + 合并：3 张 JPEG（`IMG_2052.jpg` iPhone、`aurora.jpg` Pixel、`IMG_2034.jpg` 无 EXIF）解码像素逐字节相同，压缩数据（DQT / DHT / SOF / SOS + 熵编码段）逐字节相同；但 EXIF APP1 被重写：aurora 丢了 IFD0 的 0x100 / 0x101 / 0x213 和整个 Interop 目录、字节序从 II 变 MM，曝光时间有理数被近似；IMG_2052 的 GPS 水平误差 7.435514927550326 → 7.435514929355265；扩展 XMP 被合进主 XMP。**否决用于 JPEG**。
- 自己写 XMP APP1：三张图依次设 4、2、清除、5，每次读回正确，**去掉 XMP 段后整个文件逐字节相同**，解码像素相同，扩展 XMP 和 `xmpNote:HasExtendedXMP` 保留。
- 修改时间：`setAttributes` 能保留到微秒（1794926102.880743041 → .880743000），改用 `utimensat` 恢复纳秒。创建时间、权限、自定义扩展属性保持；inode 改变。
- 原子性：临时文件 + `replaceItemAt`；只读卷上写失败（NSCocoaError 642 / EROFS），磁盘满时写临时文件失败（NSCocoaError 640 / ENOSPC），两种情况原文件 SHA-1 都不变、没有残留。
- 注意：实验代码把新 XMP 段插在最后一个 APPn 之后；正式实现改为插在 Exif 之后、APP2 之前（3.2），以保护多图 JPEG。多图 JPEG（MPF / HDR 增益图）本地没有样张，**未实测**，开发第 1 阶段先用 ImageIO 生成一张带增益图的 JPEG 补测。

**c. HEIC / HEIF、TIFF、PNG**
- HEIC（`IMG_2031.heic` 63 块、`IMG_2035.heic` 48 块）：**可以无损**。ImageIO 合并写入后，按 iloc 逐项比较，全部 hvc1 图块、grid、Exif 项逐字节相同，只有 XMP（mime）项变了；EXIF / GPS / TIFF 字典相同。清除：设 kCFNull 无效（星级仍在），去掉后整体替换元数据会重写 Exif 项，所以**清除写 0**。
- TIFF（`scan_003.tif`）：**可以无损**。条带数据逐字节相同，像素相同；新增 XMP、IPTC 标签。清除同样写 0。
- PNG（`harbor_night.png`）：**ImageIO 不可靠**——对原本没有 XMP 的 PNG，前三次写入都返回成功却没写进去；还删了 eXIf 的 ColorSpace。**自己写 iTXt 块：可以无损**，去掉 XMP 块后整个文件逐字节相同。
- GIF：ImageIO 明确返回「不支持无损修改元数据」，按 PRD 用小文件。
- 也在 exFAT、FAT32 磁盘映像上写了 JPEG 和 HEIC：成功，修改时间不变。

**d. 2000 个文件的读取速度**（缓存热：克隆文件和刚写的文件都在内存缓存里，冷读取会更慢，本机没法清缓存，需要在开发阶段用存储卡实测）
- 2000 个图片（1200 JPEG + 800 HEIC，都带星级）：`CopyMetadata` 单线程 1423 毫秒（0.71 毫秒 / 个），`CopyProperties` 896 毫秒，16 线程并行 302 毫秒。
- 2000 个 RAW（ARW / RAF / NEF / DNG / CR3 各 400）：单线程 5679 毫秒（2.84 毫秒 / 个；按格式 ARW 2.80、DNG 2.50、NEF 2.58、CR3 1.54、RAF 1.22），并行 577 毫秒；第二遍 4196 / 571 毫秒。
- 1000 个小文件：ImageIO 解析 100 毫秒，`XMLDocument` 43 毫秒，文本正则 13 毫秒。
- 列目录（含 xmp，3000 项）：6 毫秒。
- **结论**：读取不能放在打开文件夹的路径上；首张图之后在后台、限 4 并发、先近后远；有小文件的 RAW 不读内嵌。

**e. 读回兼容性**
- Apple ImageIO：本方案写的 JPEG、PNG、HEIC、TIFF 和小文件，`xmp:Rating` 和 `kCGImagePropertyIPTCStarRating` 都读回正确值。
- 独立于 ImageIO 的检查：用 `XMLDocument` 解析写进文件的 XMP 包，Rating 正确。
- `exiftool`：本机没有安装，按规则不安装，**未验证**。
- `mdls`：本机 Spotlight 索引是只读状态，所有文件 `mdls` 都返回空；用 `mdimport -t -d3` 直接跑系统的 Image 导入器，返回 68 个属性但**没有任何星级属性**，说明 Spotlight 不把 `xmp:Rating` 收进索引，无法用它验证。
- Lightroom Classic、Capture One：本机没有，**未验证**。PRD 风险一节要求的「用真实软件各测一次」仍待做（需要有这两个软件的机器，或请负责人协助）。DNG 的情况见 spec PD-15。
- 「预览」App 能否显示星级：未验证（spec 第 17 节）。

**f. GitHub 接口**（用公开仓库 `cli/cli` 和 `torvalds/linux` 测，没有请求一览自己的仓库；请求头只有通用 User-Agent，没有任何身份信息；本机网络经过代理）
- `GET /repos/cli/cli/releases/latest` → 200，字段：`tag_name = "v2.104.0"`、`draft = false`、`prerelease = false`、`published_at = "2026-11-12T19:03:51Z"`、`html_url = "https://github.com/cli/cli/releases/tag/v2.104.0"`、`body` 是 Markdown（4503 字），另有 assets、author 等。
- 限额响应头：`x-ratelimit-limit: 60`、`x-ratelimit-remaining`、`x-ratelimit-used`、`x-ratelimit-resource: core`、`x-ratelimit-reset`（Unix 秒）。确认未登录每个 IP 每小时 60 次。`cache-control: public, max-age=60`，有 `etag`。
- 带 `If-None-Match` → 304，但 `used` 仍然加 1（未登录时 304 也算次数）。
- 没有任何发布的仓库（`torvalds/linux`）→ 404，`{"message":"Not Found",…}`。
- 不带 User-Agent → 403。
- `/releases/latest` 本身就不返回草稿和预发布；代码里仍然检查两个字段。

**B1 双击标题栏**：`fix/titlebar-double-click`（5c04298）只读了代码，没有实际点击。它读 `AppleActionOnDoubleClick`：本机没设过这个键（默认是缩放）；系统设置里还有「填充」（值 `Fill`），代码里没处理会落到「缩放」。合入后要按第 8 节的手动步骤逐个设置实测。

## 8. 测试计划

自动测试放 `app/YilanTests/`，素材只用 `app/Fixtures/sample` 的公开授权文件，测试时复制到临时目录再改；RAW 测试在 `Fixtures/raw` 不存在时跳过（`XCTSkip`）。合成的 XMP 文本是测试代码里自己写的，不需要登记；如果另存成文件放进 `Fixtures/`，在 CREDITS.md 记为「自己生成」。

| PRD 验收 | 自动测试 | 手动 |
| --- | --- | --- |
| 1–5 后 0.1 秒内点亮，0 清除 | `RatingKeyTests`：keyCode 映射、重复键忽略、相同数字不进记录 | `Perf` 打点「按键 → 视图更新」 |
| RAW 生成同名 .xmp，RAW 一个字节都不变 | `SidecarTests`：命名规则、新建内容、RAW 前后 SHA-256 相同 | — |
| JPEG 画面数据一致、修改时间不变 | `EmbeddedWriteTests`：JPEG / PNG 去掉 XMP 段逐字节相同；HEIC 图块、TIFF 条带逐字节相同；像素相同；纳秒修改时间相同；自检失败回退小文件 | — |
| Lightroom 互通 | — | **需要 Lightroom Classic**：导入一览评过星的 JPEG、HEIC、RAW+xmp、DNG+xmp；Lightroom 打星后「将元数据存储到文件」，一览打开看星级。Capture One 同样 |
| 已有 .xmp 调色参数保留 | `XMPPacketTests`：三种风格合成小文件，拍平比较 | Lightroom 生成的真实小文件再测一次 |
| 写保护卡上提示、回滚、不崩 | `SafeReplaceTests`：`chmod 555` 目录 → notWritable；注入磁盘满 → diskFull | 用 `hdiutil` 做只读磁盘映像、20 MB 写满的磁盘映像、真实写保护 SD 卡 |
| ≥3 星筛选、计数、方向键 | `BrowseFilterTests`：匹配、数量、暂留、改筛选后的选中（F-03）、2000 个 `measure` | — |
| 格式只列已有格式、RAW+JPEG+≥4 星 | `BrowseFilterTests`：格式分组（heic / heif、jpg / jpeg 合并）、组内或、组间且 | — |
| 不打开面板看出条件；清除筛选 | `FilterSummaryTests`：摘要文字三种长度 | 截图对照设计稿 |
| ⌘Z 撤销打星，文件同步恢复 | `UndoHistoryTests`：评星、删除交错的顺序和菜单文字；撤销后文件读回旧值 | — |
| 删除带星 RAW，xmp 一起进废纸篓并能撤销 | `TrashSidecarTests`（假废纸篓） | — |
| 中英文完整文案 | 扩展现有 `LocalizationTests`：新键都有 en | 两种语言各走一遍 |
| 顶部缩放控件、菜单 | `ZoomStateTests`：百分比、−/+ 置灰、勾选 | 截图对照 |
| 从宽拖到最窄不重叠 | `TopBarLayoutTests`：中文阈值、英文实测宽度 | 640–1400 逐步拖动，中英文各一遍 |
| ⌘0 / ⌘9 / Z / ⌘1–3，菜单和设置同步 | 键映射测试 | 看菜单、设置、欢迎界面 |
| 双击标题栏（B1） | — | 合入 5c04298 后，在系统设置分别选「缩放」「填充」「最小化」「不执行任何操作」，各在标题栏空白处双击；放大到 200% 后再双击标题栏，比例不变；双击图片仍切换缩放；全屏时双击；标题栏单击拖动移动窗口 |
| 有新版本时提醒、说明格式正常 | `ReleaseNotesTests`（用 `changes/release-notes-template.md` 的文字做固定格式样本）、`UpdatePolicyTests`（URLProtocol 桩） | `--update-feed` 指向本地 JSON 走一遍 |
| 中文只显示中文段、英文只显示英文段、不合格式显示全文 | `ReleaseNotesTests` | 切换界面语言看 |
| 前往下载打开发布页 | `UpdatePolicyTests` 检查打开的 URL | 点一次 |
| 跳过后不再提醒、更高版本再提醒 | `UpdatePolicyTests` | — |
| 24 小时内只检查一次 | `UpdatePolicyTests`：桩计数 | — |
| 断网无提示、不影响打开图片 | `UpdatePolicyTests`：网络错误不产生任何界面状态 | 关 Wi-Fi 启动 |
| 手动检查三种结果 | `UpdatePolicyTests` | 断网、桩、真实 GitHub（发布后） |
| 关掉自动检查后不发请求 | `UpdatePolicyTests`：桩计数为 0 | Little Snitch 类工具可选 |
| 预发布、草稿不提醒 | `UpdatePolicyTests` | — |
| 2000 个 RAW 首张图不变慢 | — | 第 6 节方法，v0.2.1 对照 |
| 连续切图、连续打星不卡 | `RatingWriterTests`：合并、顺序 | 按住方向键 + 快速按数字 |
| 2000 个文件切换筛选 0.3 秒 | `BrowseFilterTests.measure` | `Perf` 打点 |

## 9. 本地化和沙盒

- 新文案全部进 `Localizable.xcstrings`（spec 第 15 节，键是中文，带 comment）；「N 星」「N 个文件」用 xcstrings 的复数变体；更新说明正文不翻译（来自网络，按段落选语言）。
- 目前 App Sandbox 关闭。所有写用户文件的代码集中在 `Metadata/`（评星、导出）和现有 `Model/Trash.swift`；以后开沙盒时需要：
  - 在 Info.plist 的文档类型里给 `xmp` 声明 `NSIsRelatedItemType`，写小文件时用 `NSFileCoordinator` 并让文件呈现者的 `primaryPresentedItemURL` 指向照片——这是苹果给「同名旁路文件」的官方机制；
  - 或者打开文件夹时取得文件夹授权（security-scoped bookmark），v0.2 的 `project.yml` 注释里已经记了这件事。
  - 更新检查需要 `com.apple.security.network.client`；上架商店版本关掉更新检查（`UpdateChecker.isAvailable`）。

## 10. 风险

- **实验在 macOS 27.2.1 上做，应用最低支持 macOS 26**。ImageIO 的行为可能不同。对策：写入路径的自动测试检查的是结果（逐字节、像素、读回），在 macOS 26 上跑一遍测试就能发现差异；写入还有自检兜底。
- **Lightroom、Capture One、exiftool 都没验证**（见 7.e）。XMP 写法符合 Adobe 规范，但「Lightroom 读到」仍是推断。DNG 尤其可能读不到（PD-15）。
- **多图 JPEG、带增益图 / 深度图的 HEIC 没有样张**。对策：3.2 的插入位置规则 + 自检里检查辅助图仍在；第 1 阶段补测。
- **冷读取速度未测**：存储卡上的 2000 个 RAW 读星级可能明显慢于实测；只影响角标出现的快慢，不影响首张图。
- **小文件排版会变**：`XMLDocument` 改写后空白和属性排列不同，内容不变；极少数按文本比较小文件的工具可能认为「被修改了」。
- **文件大小显示差几 KB**（3.4 的取舍）。
- **网络盘 / iCloud Drive 上的替换**未测。
- **GitHub 访问不稳定**：失败一律安静；手动检查才提示。

## 11. 开发顺序（每个阶段结束时程序都能正常用、测试全过）

| 阶段 | 内容 | 结束时的状态 |
| --- | --- | --- |
| 0 | 合入 `fix/titlebar-double-click`；按第 8 节手动验证 B1 | v0.2.1 + B1 修复 |
| 1 | `Metadata/` 全部（读、写、小文件、自检、账本）和它的单元测试；补测多图 JPEG / 带增益图 HEIC；界面不变 | 功能不变，写入层有测试保证 |
| 2 | 评星：键盘、五星胶囊、角标、信息面板、序号星级、后台读取、文件夹同步、写失败提示、.xmp 提示；`UndoHistory` 替换删除撤销；删除带小文件；快捷键调整（0 / 1 让给评星，加 Z / ⌘0 / ⌘9）、快捷键变化提示、设置 › 浏览新项 | 可以打星、撤销，缩放用新快捷键（左下角比例胶囊暂时保留） |
| 3 | 顶部缩放控件、删除 `ZoomPill`、顶部栏收缩（先只有类型切换 + 缩放） | E1 完成 |
| 4 | 筛选：模型、按钮、面板、空结果、暂留、⌘F、菜单；顶部栏收缩加入筛选按钮各档 | R5 系列完成 |
| 5 | 更新提醒：客户端、策略、提示卡片排队、小点、表单、设置 › 通用、菜单 | U 系列完成 |
| 6 | 尽量做：R8 自动下一张、R9 导出 | 全部功能 |
| 7 | 对照设计稿逐画板验收、中英文、640 宽度、2000 文件性能对比、Lightroom 实测（如有条件） | 可以写更新说明 |

R8、R9 是「尽量做」，按负责人「先发布、余下放到下个补丁版本」的偏好，阶段 6 来不及时可以移到 v0.3.1，不影响前面的阶段。
