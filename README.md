# ImageView

ImageView 是一个原生 Swift + AppKit 图片查看器，支持 macOS 13 及以上版本。项目使用 Swift Package Manager，不依赖第三方运行时库。

## 基本使用

拖入图片或文件夹，或使用 **文件 → 打开…**（`⌘O`）。打开文件夹时默认递归浏览图片；使用 **查看 → 包含子文件夹** 可以切换为仅浏览当前文件夹。也可以直接把图片路径作为启动参数传入：

```sh
swift run ImageView /absolute/path/to/photo.jpg
```

支持 JPEG、PNG、HEIC/HEIF、GIF、TIFF、WebP，以及当前 macOS ImageIO 支持的 RAW 格式。损坏或不支持的文件会显示错误状态，不会中断当前图库。

常用操作：

| 操作 | 快捷键或交互 |
| --- | --- |
| 上一张 / 下一张 | `←` / `→` |
| 放大 / 缩小 | `⌘+` / `⌘-` |
| 适合窗口 / 原始尺寸 | `⌘0` / `⌘1` |
| 平移图片 | 按住空格拖动 |
| 查找文件名 | `⌘F` |
| 显示图片信息 | `⌘I` |
| 重新载入当前图片 | `⌘R` |
| 刷新当前文件夹 | `⇧⌘R` |
| 打开文件夹 | `⇧⌘O` |
| 全屏 | `⌃⌘F` |
| 旋转 | `⌘[` / `⌘]` |

缩略条、排序、浏览范围、图片方向、复制和删除等操作可从 **查看** 菜单或图片右键菜单使用。旋转和镜像只影响显示，不修改原文件；删除会将文件移到系统废纸篓。

## 开发

需要 macOS、Swift 6 或更新版本，以及可用的 macOS SDK。应用最低支持 macOS 13。

运行应用：

```sh
swift run ImageView
```

运行测试：

```sh
swift test
```

如果本机命令行工具无法找到 Swift Testing 的宏路径，使用项目提供的兼容脚本：

```sh
./Scripts/test.sh
```

测试使用的临时图片和目录写入已忽略的 `.build/test-fixtures/`，测试结束后会清理。

## 构建应用

在 macOS 上构建 Universal 2 应用：

```sh
./Scripts/build-universal.sh
open build/ImageView.app
```

脚本分别构建 `arm64` 和 `x86_64` Release，合并为一个 Universal 2 应用，生成图标资源并执行本地 ad-hoc 签名。默认产物为 `build/ImageView.app`；版本号和输出路径可以按需覆盖：

```sh
./Scripts/build-universal.sh \
  --output build/ImageView.app \
  --version 1.0.0 \
  --build-number 1
```

检查产物架构和签名：

```sh
lipo -archs build/ImageView.app/Contents/MacOS/ImageView
codesign --verify --deep --strict --verbose=2 build/ImageView.app
```

项目的打包元数据位于 `Packaging/Info.plist`，应用图标源文件为 `icon.png`，构建时生成的图标资源位于 `Packaging/AppIcon.icns`。
