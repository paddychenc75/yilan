# 测试样例文件的来源和许可 / Fixture credits

`sample/` 里的图片和视频全部来自公开授权的素材：每个原始文件都是 **CC0（公共领域贡献）** 或 **公共领域（Public Domain）**，可以自由使用、修改，不需要署名。下面仍然逐个记下来源和作者，方便核对。

- 下载时间：2026-11-10。许可以 Wikimedia Commons 文件页上的 `LicenseShortName` 为准（通过 Commons API `prop=imageinfo&iiprop=extmetadata` 读取并核对）。
- 原始文件只在本机临时目录里下载和转换，仓库里放的是下面“处理”一列说明的结果。
- 没有使用任何个人照片或个人文件夹里的文件。
- 转换工具：`sips`（macOS 自带）、`ffmpeg`，以及一个只用 ImageIO 重新编码的小脚本（缩小尺寸、去掉全部 EXIF/GPS，保留色彩描述文件）。

## sample/

| 文件 | 来源 | 作者 | 许可 | 处理 |
|---|---|---|---|---|
| `IMG_2052.jpg` | [Summer morning in the Swiss Alps.jpg](https://commons.wikimedia.org/wiki/File:Summer_morning_in_the_Swiss_Alps.jpg) | Sternenjaeger | CC0 | 原文件，没有改动。带真实相机 EXIF（iPhone 11 Pro，f/2.4，ISO 20，2020-08-01）和 GPS 位置，用于信息面板测试和截图 |
| `aurora.jpg` | [Aurora borealis near Salzdahlum 2024-10-10.jpg](https://commons.wikimedia.org/wiki/File:Aurora_borealis_near_Salzdahlum_2024-10-10.jpg) | Profpcde | CC0 | 原文件，没有改动。带真实相机 EXIF（Google Pixel 4a）和 GPS |
| `IMG_2034.jpg` | [Cape Cod, Massachusetts coastal skyline.jpg](https://commons.wikimedia.org/wiki/File:Cape_Cod,_Massachusetts_coastal_skyline.jpg) | Walesjl | CC0 | 缩小到 2400 × 1800，重新编码时去掉全部 EXIF（测试“没有拍摄信息的 JPEG”） |
| `harbor_night.png` | [Busan fishing harbor at night 18.jpg](https://commons.wikimedia.org/wiki/File:Busan_fishing_harbor_at_night_18.jpg) | Syced | CC0 | 缩小到 1600 × 1200，转成 PNG，不带 EXIF |
| `IMG_2031.heic` | [Landscape of lake and clouds.jpg](https://commons.wikimedia.org/wiki/File:Landscape_of_lake_and_clouds.jpg) | Mshuang2 | CC0 | 用 `sips -s format heic` 转成 HEIC，保留原来的 EXIF（OnePlus A6003）和 GPS |
| `IMG_2035.heic` | [Hierve el Agua nature.jpg](https://commons.wikimedia.org/wiki/File:Hierve_el_Agua_nature.jpg) | Paumucito | CC0 | 用 `sips -s format heic` 转成 HEIC，保留原来的 EXIF 和 GPS |
| `old_scan.bmp` | [Township of Canungra, Queensland (historic) 01.jpg](https://commons.wikimedia.org/wiki/File:Township_of_Canungra,_Queensland_(historic)_01.jpg) | Robert Augustus Henry L'Estrange（老照片扫描） | CC0 | 用 `sips -Z 1400 -s format bmp` 缩小到 1400 × 854 并转成 BMP |
| `scan_003.tif` | [Heuernte bei Wergzahna im September 2017.webm](https://commons.wikimedia.org/wiki/File:Heuernte_bei_Wergzahna_im_September_2017.webm) | Cmuelle8 | CC0 | 用 `ffmpeg` 取视频第 8 秒的一帧（1920 × 1080），再用 `sips -s format tiff` 转成不压缩的 TIFF |
| `gears.gif` | [Spur gears animation.gif](https://commons.wikimedia.org/wiki/File:Spur_gears_animation.gif) | Jahobr | CC0 | 原文件，没有改动（动图） |
| `mountains.svg` | [Vector Illustration of a Mountain Landscape with Pine Trees.svg](https://commons.wikimedia.org/wiki/File:Vector_Illustration_of_a_Mountain_Landscape_with_Pine_Trees.svg) | Missaruthra | CC0 | 原文件，没有改动（660 × 659，不含脚本和外部链接） |
| `trail.mp4` | [Sandwatt (Fussspuren).webm](https://commons.wikimedia.org/wiki/File:Sandwatt_(Fussspuren).webm) | Rhetos | CC0 | Commons 上只有 WebM（VP8 + Vorbis），AVFoundation 播放不了。用 `ffmpeg` 转成 MP4：H.264 1280 × 720 + AAC 立体声，10.6 秒，去掉容器元数据 |
| `IMG_2036.mov` | [Flor di tuna, Aruba (Opuntia caracassana).webm](https://commons.wikimedia.org/wiki/File:Flor_di_tuna,_Aruba_(Opuntia_caracassana).webm) | Ginelly.Q | CC0 | 原文件是 WebM（VP9 + Opus）。用 `ffmpeg` 转成 QuickTime MOV：HEVC（hvc1）1280 × 720 + AAC，14.5 秒，去掉容器元数据 |
| `broken.jpg` | 自己生成 | — | — | 2 KB 的无效数据，扩展名是 .jpg，用来测试“文件已损坏” |
| `notes.txt` | 自己生成 | — | — | 一个文本文件，用来测试“不支持的文件会被跳过” |

视频是从 Commons 上的 WebM 原片转码得到的真实画面，不是用静态图片合成的。

## raw/（不放进仓库）

`raw/` 被 `.gitignore` 忽略（文件太大，共约 184 MB），需要时从 [raw.pixls.us](https://raw.pixls.us/) 下载。这 5 个文件在 raw.pixls.us 的样张库里都标为 **CC0**（2026-11-10 通过它的数据接口 `json/getrepository.php?set=all` 核对过），本地文件的 SHA-256 和网站上公布的一致。

| 文件 | 相机 | 下载地址 | 许可 | SHA-256（前 16 位） |
|---|---|---|---|---|
| `_DSC0009.ARW` | Sony ILCE-7M3 | https://raw.pixls.us/data/Sony/ILCE-7M3/ | CC0 | `250784580ea52744` |
| `AFXT2720.RAF` | Fujifilm X-T3 | https://raw.pixls.us/data/Fujifilm/X-T3/ | CC0 | `24abd27b4a200f31` |
| `DSC_0750.NEF` | Nikon Z 6 | https://raw.pixls.us/data/Nikon/Z%206/ | CC0 | `b4cdb8ecf8a971ec` |
| `IMG_1361.DNG` | Apple iPhone 12 Pro | https://raw.pixls.us/data/Apple/iPhone%2012%20Pro/ | CC0 | `e91e77a4533ed7cc` |
| `IMG_6310.CR3` | Canon EOS R10 | https://raw.pixls.us/data/Canon/Canon%20EOS%20R10/ | CC0 | `2dc0bbdf04c93ca6` |
