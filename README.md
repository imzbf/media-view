# MediaView

适用于 macOS 13 及以上版本的本地图片和视频查看器。

- **图片**：JPEG、PNG、HEIC/HEIF、GIF、TIFF、WebP，以及系统支持的 RAW 格式。
- **视频**：MP4、MOV、M4V，具体编码支持取决于 macOS。

## 使用

将文件或文件夹拖入窗口，或按 `⌘O` 打开。默认包含子文件夹，可在「查看 → 包含子文件夹」中关闭。

- **浏览**：`←` 和 `→` 切换文件，`⌘F` 按文件名查找，`⌘I` 查看文件信息。
- **看图**：滚动或双指捏合缩放，`⌘0` 适合窗口，`⌘1` 显示原始尺寸。图片超出窗口时，按住左键直接拖动；也可按住空格从留白处拖动。
- **看视频**：打开后停在首帧，按空格播放或暂停。

## 构建

在 macOS 上使用 Swift 6 或更高版本，从仓库根目录执行：

| 版本 | 构建命令 | 产物 |
| --- | --- | --- |
| 本机 Debug | `swift build -c debug` | 调试用可执行文件 |
| 本机 Release | `swift build -c release` | 优化后的可执行文件 |
| 通用版（Apple Silicon 和 Intel） | `./Scripts/build-universal.sh` | `build/MediaView.app` |
| Apple Silicon | `./Scripts/build-universal.sh --arch arm64` | `build/arm64/MediaView.app` |
| Intel | `./Scripts/build-universal.sh --arch x86_64` | `build/x86_64/MediaView.app` |
| DMG 安装包 | `./Scripts/build-dmg.sh --arch arm64 --version 1.2.3`（Intel 改用 `x86_64`） | `build/release/MediaView-1.2.3-<arch>.dmg` |

本机运行：`swift run MediaView`。运行测试：`./Scripts/test.sh`。本地签名与公证选项见 `./Scripts/build-universal.sh --help`。

## 发布

先将待发布的改动提交到 `main`，再推送分支和新的稳定版标签（以 `v1.2.3` 为例）：

```sh
git push origin main
git tag v1.2.3 main
git push origin v1.2.3
```

只有新的 `vX.Y.Z` 标签会触发发布。测试通过且 Apple Silicon 和 Intel 的 DMG 均通过校验后，两个安装包会随 GitHub Release 一起发布。

安装包使用 ad-hoc 签名，未经 Apple 公证，首次打开可能出现 macOS 安全提示。发布中断可在 Actions 重跑；已公开的附件不会被覆盖。
