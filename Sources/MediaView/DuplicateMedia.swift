import Foundation
import CryptoKit
import ImageIO
import AVFoundation
import Darwin

enum DuplicateKind: String, Codable, Sendable { case photo, video }
enum DuplicateMatch: String, Codable, Sendable {
    case exact, similar
    var title: String { self == .exact ? "完全重复" : "疑似重复" }
}

/// inode 和纳秒时间一起校验，避免同一路径被替换后仍沿用旧指纹或清理决定。
struct DuplicateFileStamp: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DuplicateError.changedFile }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }

    var key: String { "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanos):\(changedSeconds):\(changedNanos)" }
}

enum DuplicateError: LocalizedError {
    case changedFile, invalidRecord, noKeeper
    var errorDescription: String? {
        switch self {
        case .changedFile: return "文件已变化或不是普通文件，请重新检查后再清理。"
        case .invalidRecord: return "重复检查记录无法读取，原记录已保留。"
        case .noKeeper: return "每组至少需要保留一个仍然有效的文件。"
        }
    }
}

struct DuplicateFile: Codable, Equatable, Sendable {
    let path: String
    let kind: DuplicateKind
    let stamp: DuplicateFileStamp
    var digest: String?
    var visual: DuplicateVisual?

    var name: String { (path as NSString).lastPathComponent }
    func url(in root: URL) -> URL { root.appendingPathComponent(path) }
    var identity: String { path + "\u{0}" + stamp.key }

    static func relativePath(_ url: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard url.isFileURL, components.count > base.count, components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    var detail: String {
        var parts = [kind == .photo ? "照片" : "视频"]
        if let visual {
            parts.append("\(visual.width) × \(visual.height)")
            if let duration = visual.duration {
                let seconds = Int(duration.rounded())
                parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
        }
        parts.append(ByteCountFormatter.string(fromByteCount: stamp.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

struct DuplicateGroup: Equatable, Sendable, Identifiable {
    let id: String
    let match: DuplicateMatch
    let files: [DuplicateFile]

    init(files: [DuplicateFile], match: DuplicateMatch) {
        self.files = files.sorted {
            let a = ($0.visual?.width ?? 0) * ($0.visual?.height ?? 0)
            let b = ($1.visual?.width ?? 0) * ($1.visual?.height ?? 0)
            if a != b { return a > b }
            if $0.stamp.size != $1.stamp.size { return $0.stamp.size > $1.stamp.size }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        self.match = match
        // 判定算法版本也属于组身份，后续调整阈值不能悄悄继承旧的清理决定。
        id = Self.hash("v1:\(match.rawValue)\n" + files.map(\.identity).sorted().joined(separator: "\n"))
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct DuplicateIssue: Equatable, Sendable {
    let path: String
    let message: String
}

struct DuplicateProgress: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    var text: String { total > 0 ? "\(phase) \(completed) / \(total)" : phase }
}

struct DuplicateScanResult: Sendable {
    let groups: [DuplicateGroup]
    let issues: [DuplicateIssue]
    let fileCount: Int
}

/// 持久化的是小型画面指纹，不保存原图或视频帧；预览仍使用独立的解码器。
struct DuplicateVisual: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let duration: Double?
    let frames: [DuplicateFrame]

    var indexHash: UInt64? { frames.isEmpty ? nil : frames[frames.count / 2].hash }

    func matches(_ other: Self) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0,
              !frames.isEmpty, frames.count == other.frames.count else { return false }
        let aspect = Double(width) / Double(height)
        let otherAspect = Double(other.width) / Double(other.height)
        guard abs(aspect / otherAspect - 1) <= 0.02 else { return false }
        if let duration, let otherDuration = other.duration {
            guard abs(duration - otherDuration) <= max(0.25, min(duration, otherDuration) * 0.005) else { return false }
        } else if duration != nil || other.duration != nil { return false }
        return zip(frames, other.frames).allSatisfy { $0.matches($1, video: duration != nil) }
    }

    static func read(_ url: URL, kind: DuplicateKind) async throws -> Self {
        try Task.checkCancellation()
        if kind == .photo {
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    let width = properties[kCGImagePropertyPixelWidth] as? Int,
                    let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ImageDecodeError.invalidImage }
                let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? Int) ?? 1)
                // GIF 等多帧文件不能只凭封面当作同一素材；仍可参与完整文件哈希检查。
                guard CGImageSourceGetCount(source) == 1 else {
                    return Self(width: rotated ? height : width, height: rotated ? width : height, duration: nil, frames: [])
                }
                // 较大的中间缩略图消除 JPEG 方向校正与重采样次序带来的边缘误差，无需放宽阈值。
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary) else { throw ImageDecodeError.invalidImage }
                return Self(width: rotated ? height : width, height: rotated ? width : height,
                    duration: nil, frames: [try DuplicateFrame(image)])
            }
        }
        let asset = AVURLAsset(url: url)
        let info = try await VideoInfo.load(from: asset)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        return try await withTaskCancellationHandler {
            var frames: [DuplicateFrame] = []
            // 分散采样避免同一片头误报；保持顺序比较，转传不应改变时间线。
            for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
                try Task.checkCancellation()
                let sample = try await generator.image(at: CMTime(seconds: info.duration * fraction, preferredTimescale: 600))
                frames.append(try autoreleasepool { try DuplicateFrame(sample.image) })
            }
            return Self(width: Int(info.pixelSize.width.rounded()), height: Int(info.pixelSize.height.rounded()),
                duration: info.duration, frames: frames)
        } onCancel: { generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
    }
}

struct DuplicateFrame: Codable, Equatable, Sendable {
    let hash: UInt64
    let luminance: Data
    let colors: Data
    private static let cosines = (0..<8).map { frequency in
        (0..<32).map { cos(Double(2 * $0 + 1) * Double(frequency) * .pi / 64) }
    }

    init(_ image: CGImage) throws {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard rendered else { throw ImageDecodeError.invalidImage }
        let gray = (0..<1024).map { index -> UInt8 in
            let i = index * 4
            return UInt8((Double(pixels[i]) * 0.299 + Double(pixels[i + 1]) * 0.587 + Double(pixels[i + 2]) * 0.114).rounded())
        }
        luminance = Data(gray)
        var rgb: [UInt8] = []
        for y in 0..<8 { for x in 0..<8 { for channel in 0..<3 {
            var sum = 0
            for dy in 0..<4 { for dx in 0..<4 { sum += Int(pixels[((y * 4 + dy) * 32 + x * 4 + dx) * 4 + channel]) } }
            rgb.append(UInt8(sum / 16))
        } } }
        colors = Data(rgb)
        // 分离的二维 DCT 只取低频 8×8；先候选索引，再以局部结构和颜色复核。
        var rows = [Double](repeating: 0, count: 32 * 8)
        for y in 0..<32 { for u in 0..<8 {
            for x in 0..<32 { rows[y * 8 + u] += Double(gray[y * 32 + x]) * Self.cosines[u][x] }
        } }
        var coefficients = [Double](repeating: 0, count: 64)
        for v in 0..<8 { for u in 0..<8 {
            for y in 0..<32 { coefficients[v * 8 + u] += rows[y * 8 + u] * Self.cosines[v][y] }
        } }
        // 纯色与平坦画面的理论零系数会有浮点残差，不能把舍入噪声当成纹理差异。
        coefficients = coefficients.map { abs($0) < 0.000001 ? 0 : $0 }
        let median = coefficients.dropFirst().sorted()[31]
        var value: UInt64 = 0
        for i in 1..<64 where coefficients[i] > median { value |= UInt64(1) << i }
        hash = value
    }

    func matches(_ other: Self, video: Bool) -> Bool {
        guard luminance.count == 1024, other.luminance.count == 1024, colors.count == 192, other.colors.count == 192,
              (hash ^ other.hash).nonzeroBitCount <= (video ? 8 : 6) else { return false }
        let colorDifference = zip(colors, other.colors).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / (192 * 255)
        guard colorDifference <= 0.055 else { return false }
        let a = Array(luminance), b = Array(other.luminance)
        var total = 0.0
        for row in 0..<4 { for column in 0..<4 {
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            for y in 0..<8 { for x in 0..<8 {
                let i = (row * 8 + y) * 32 + column * 8 + x
                let av = Double(a[i]), bv = Double(b[i])
                sx += av; sy += bv; sxx += av * av; syy += bv * bv; sxy += av * bv
            } }
            let mx = sx / 64, my = sy / 64
            let vx = max(0, sxx / 64 - mx * mx), vy = max(0, syy / 64 - my * my)
            let score = ((2 * mx * my + 6.5025) * (2 * (sxy / 64 - mx * my) + 58.5225))
                / ((mx * mx + my * my + 6.5025) * (vx + vy + 58.5225))
            guard score >= (video ? 0.75 : 0.85) else { return false }
            total += score
        } }
        return total / 16 >= (video ? 0.95 : 0.97)
    }
}
