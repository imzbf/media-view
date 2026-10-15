import Foundation
import ImageIO

/// 元数据只读。source 创建完成后，所有帧访问仅在 ImageDecoder 的串行优先队列上执行。
/// 保留一个源可让 ImageIO 复用 GIF 的索引和合成状态，无需每帧重新打开整个文件。
final class GIFAnimation: @unchecked Sendable {
    let url: URL
    let pixelSize: CGSize
    let frameDurations: [TimeInterval]
    /// ImageIO 已把 NETSCAPE 的“首轮后重复次数”转换为总轮数：缺失为 1，0 表示无限。
    let totalPlays: Int?
    private let source: CGImageSource

    var frameCount: Int { frameDurations.count }

    init(source: CGImageSource, url: URL, pixelSize: CGSize,
         isCancelled: @escaping @Sendable () -> Bool) throws
    {
        self.source = source
        self.url = url
        self.pixelSize = pixelSize
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loops = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? 1
        totalPlays = loops == 0 ? nil : max(1, loops)
        // ImageIO 可能不计入截断的最后一帧。容器只数描述符，避免静默忽略损坏尾帧；
        // 像素、透明、延时、循环语义及合成仍由 ImageIO 提供。
        let declaredCount = try Self.declaredFrameCount(url: url, isCancelled: isCancelled)
        var durations: [TimeInterval] = []
        for index in 0..<max(declaredCount, CGImageSourceGetCount(source)) {
            if isCancelled() { throw CancellationError() }
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let timing = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            durations.append(Self.frameDuration(properties: timing))
        }
        frameDurations = durations
    }

    static func frameDuration(properties: [CFString: Any]) -> TimeInterval {
        // 存在未钳制字段时以它为准；0、负值或非有限值不再退回被系统改写的延时。
        let number = properties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
            ?? properties[kCGImagePropertyGIFDelayTime] as? NSNumber
        let duration = number?.doubleValue ?? 0
        return duration.isFinite && duration > 0 ? duration : 0.1
    }

    func decodeFrame(at index: Int, quality: DecodeQuality,
                     isCancelled: @escaping @Sendable () -> Bool) throws -> DecodedImage
    {
        guard frameDurations.indices.contains(index) else { throw ImageDecodeError.invalidImage }
        let image = try ImageDecoder.createImage(source: source, index: index, pixelSize: pixelSize,
                                                 quality: quality, isCancelled: isCancelled)
        return DecodedImage(image: image, pixelSize: pixelSize,
                            isFullResolution: image.width >= Int(pixelSize.width)
                                && image.height >= Int(pixelSize.height))
    }
    private static func declaredFrameCount(url: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 13 else { return 0 }
        var frameCount = 0
        let packed = data[10]
        var offset = 13 + (packed & 0x80 != 0 ? 3 * (1 << (Int(packed & 7) + 1)) : 0)

        // GIF 子块都有一个长度字节；跳过压缩内容，不扫描其中可能碰巧出现的标记。
        func skipSubblocks() -> Bool {
            while offset < data.count {
                let length = Int(data[offset])
                offset += 1
                if length == 0 { return true }
                guard length <= data.count - offset else { return false }
                offset += length
            }
            return false
        }

        parsing: while offset < data.count {
            if isCancelled() { throw CancellationError() }
            let marker = data[offset]
            offset += 1
            switch marker {
            case 0x21:
                guard offset < data.count else { break parsing }
                offset += 1 // 扩展标签，后面统一按长度子块跳过。
                guard skipSubblocks() else { break parsing }
            case 0x2c:
                frameCount += 1
                guard data.count - offset >= 9 else { break parsing }
                let framePacked = data[offset + 8]
                offset += 9
                if framePacked & 0x80 != 0 { offset += 3 * (1 << (Int(framePacked & 7) + 1)) }
                guard offset < data.count else { break parsing }
                offset += 1 // LZW 最小码长，实际解压交给 ImageIO。
                guard skipSubblocks() else { break parsing }
            case 0x3b:
                break parsing
            default:
                break parsing
            }
        }
        return frameCount
    }
}
