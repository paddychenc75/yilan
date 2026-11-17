# 一览 Yilan v0.2.1

## 中文

### 修复

- **信息面板的「位置」看起来是空的**：窗口不够高时面板中间部分会滚动，但下面被截掉的内容没有任何提示，「位置」只剩一个标题。现在内容放不下时底部会渐隐，打开面板时滚动条闪一下，提示还可以往下滚。
- **视频缩略图是一块灰**：有些视频开头几乎没有细节（比如一整片泥沙），缩小后只是一块灰。现在取视频中间偏前（时长的 40%，最多 6 秒）的一帧，更有代表性。
- **第二次打开文件夹时视频缩略图没有时长角标**：从磁盘缓存读回缩略图时丢了时长，已修复。

升级后缩略图缓存会自动重新生成。

### 系统要求和首次打开

和 v0.2.0 相同：macOS 26（Tahoe）或更高版本；只做了 ad-hoc 签名，第一次打开需要在「系统设置 › 隐私与安全性」里点「仍要打开」，或执行 `xattr -dr com.apple.quarantine /Applications/Yilan.app`。

校验和：`shasum -a 256 Yilan-0.2.1.zip`，对照文末的值。

---

## English

### Fixes

- **The Location section of the info panel looked empty**: when the window is not tall enough the middle of the panel scrolls, but nothing hinted that content was cut off, so Location showed only its title. The bottom now fades out when there is more below, and the scroll bar flashes when the panel opens.
- **A video thumbnail was a flat grey block**: some videos open on a nearly featureless frame (for example, a stretch of mud), which shrinks to plain grey. The thumbnail now uses a frame at 40% of the duration (at most 6 seconds in), which is more representative.
- **Duration badges disappeared the second time a folder was opened**: the duration was lost when reading thumbnails back from the disk cache. Fixed.

Thumbnails are regenerated automatically after the upgrade.

### Requirements and first launch

Same as v0.2.0: macOS 26 (Tahoe) or later; ad-hoc signed only, so on first launch click "Open Anyway" in System Settings › Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/Yilan.app`.

Verify the download with `shasum -a 256 Yilan-0.2.1.zip` and compare with the value below.

**SHA-256**: `a121388dc5379137162a91aea35f3074bac8a8b3d557fa1c4283ffc68c2ec940`

---

# 一览 Yilan v0.2.0

## 中文

### 新功能

- **信息面板**：按 I 打开，显示文件信息（大小、尺寸、格式、时间）和 EXIF 拍摄信息；视频显示时长、分辨率、编码、帧率、码率。面板浮在图片上，不挤压图片。
- **移到废纸篓**：按 Delete，确认后移到废纸篓，提示条里可以 ⌘Z 撤销。
- **全屏**：按 F 进入，只剩图片和环境光；鼠标移到顶部或底部时控件再出现。
- **文件夹同步**：浏览时文件夹里新增或删除文件，缩略图栏自动更新；新文件会短暂高亮；当前文件被删除或移走时自动显示相邻的一个。
- **菜单和设置**：补全编辑菜单（撤销、拷贝图片、拷贝文件路径），快捷键页按设计稿分组。
- **稳定性和性能**：加载管线竞态修复、动图和超大图的内存上限、区分文件丢失与损坏、视频无法播放时显示出错卡片、缩略图缓存清理、内存紧张时自动清缓存、窗口位置在断开的显示器上时移回主屏幕。

### 系统要求

macOS 26（Tahoe）或更高版本，Apple 芯片和 Intel 芯片都可以。

### 首次打开

这个版本只做了 ad-hoc 签名，没有 Apple 开发者账号签名，也没有公证。第一次打开时 macOS 会提示「无法验证开发者」，任选一种办法：

1. 解压 `Yilan-0.2.0.zip`，把 `Yilan.app` 拖进「应用程序」。
2. 双击打开一次（会被拦下），然后到「系统设置 › 隐私与安全性」，点 Yilan 旁边的「仍要打开」。
3. 或者在终端执行：`xattr -dr com.apple.quarantine /Applications/Yilan.app`

校验和：`shasum -a 256 Yilan-0.2.0.zip`，对照下面的值。

---

## English

### What's new

- **Info panel**: press I for file info (size, dimensions, format, dates) and EXIF shooting data; for videos it shows duration, resolution, codec, frame rate and bitrate. The panel floats over the image without resizing it.
- **Move to Trash**: press Delete, confirm, and undo from the toast with ⌘Z.
- **Full screen**: press F to leave only the image and ambient glow; controls slide back in when the pointer reaches the top or bottom.
- **Folder sync**: files added to or removed from the folder show up in the strip automatically; new files are briefly highlighted; if the current file disappears, the neighbouring one is shown.
- **Menus and Settings**: completed Edit menu (Undo, Copy Image, Copy File Path); shortcuts page grouped as in the design.
- **Stability and performance**: loading pipeline race fixes, memory caps for animated and huge images, distinguishing missing from corrupt files, an error card when a video cannot be played, thumbnail cache cleanup, cache purge under memory pressure, and moving the window back to the main display when its saved display is gone.

### Requirements

macOS 26 (Tahoe) or later, Apple silicon or Intel.

### First launch

This build is only ad-hoc signed: no Apple Developer ID, no notarization. macOS will say it cannot verify the developer the first time. Use either way:

1. Unzip `Yilan-0.2.0.zip` and drag `Yilan.app` into Applications.
2. Double-click it once (it will be blocked), then open System Settings › Privacy & Security and click "Open Anyway" next to Yilan.
3. Or run in Terminal: `xattr -dr com.apple.quarantine /Applications/Yilan.app`

Verify the download with `shasum -a 256 Yilan-0.2.0.zip` and compare with the value below.

**SHA-256**: `699ab632438c69c2c936adf1014bb4f6376052cca9de64dec1360663036d321b`
