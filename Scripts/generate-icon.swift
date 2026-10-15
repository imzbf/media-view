#!/usr/bin/env swift
import AppKit
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("icon.png")
guard let sourceData = try? Data(contentsOf: sourceURL),
      let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.png",
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sourceImage.width == sourceImage.height
else {
    fputs("Expected a readable square PNG at \(sourceURL.path)\n", stderr)
    exit(1)
}

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 每个尺寸直接从原图采样，保留透明边缘；大于原图的 1024 像素版本也使用高质量插值。
func render(pixels: Int) -> Data {
    // 原尺寸直接复用 PNG，避免无意义的颜色转换和透明像素舍入。
    if pixels == sourceImage.width { return sourceData }

    let context = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.clear(bounds)
    context.interpolationQuality = .high
    context.setBlendMode(.copy)
    context.draw(sourceImage, in: bounds)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", root.appendingPathComponent("Packaging/AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Generated Packaging/AppIcon.icns from icon.png")
