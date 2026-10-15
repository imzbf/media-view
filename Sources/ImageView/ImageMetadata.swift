import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 只把信息卡需要的文字带回主线程，不保留 ImageIO source 或整个 EXIF 字典。
struct ImageMetadata: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        let name: String
        let value: String
    }

    let fields: [Field]

    /// 禁用源缓存，仅读取文件属性和首帧元数据；这里不创建 CGImage，也不遍历 GIF 帧。
    static func read(_ url: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> ImageMetadata {
        if isCancelled() { throw CancellationError() }
        let url = URL(fileURLWithPath: url.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ImageDecodeError.unreadableFile }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?
        else { throw ImageDecodeError.unsupportedFormat }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ImageDecodeError.invalidImage }
        if isCancelled() { throw CancellationError() }

        var fields = [Field(name: "文件", value: url.lastPathComponent),
                      Field(name: "格式", value: UTType(identifier)?.preferredFilenameExtension?.uppercased() ?? identifier)]
        if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        {
            let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
            fields.append(Field(name: "尺寸", value: rotated
                ? "\(height.intValue) × \(width.intValue)"
                : "\(width.intValue) × \(height.intValue)"))
        }
        if let size = values?.fileSize {
            fields.append(Field(name: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let date = values?.contentModificationDate {
            fields.append(Field(name: "修改时间", value: DateFormatter.localizedString(from: date,
                dateStyle: .medium, timeStyle: .medium)))
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !date.isEmpty {
            // EXIF 时间可能没有时区；保留相机记录的本地时间，不猜测或转换时区。
            fields.append(Field(name: "拍摄时间", value: date))
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased())
            ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { fields.append(Field(name: "相机", value: camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
            fields.append(Field(name: "镜头", value: lens))
        }
        if let length = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
            fields.append(Field(name: "焦距", value: "\(String(format: "%.3g", length.doubleValue)) mm"))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? NSNumber {
            fields.append(Field(name: "光圈", value: "f/\(String(format: "%.3g", aperture.doubleValue))"))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber, exposure.doubleValue > 0 {
            let value = exposure.doubleValue
            fields.append(Field(name: "快门", value: value < 1
                ? "1/\(String(format: "%.3g", 1 / value)) s" : "\(String(format: "%.3g", value)) s"))
        }
        if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], !speeds.isEmpty {
            fields.append(Field(name: "ISO", value: speeds.map { $0.stringValue }.joined(separator: " / ")))
        }
        return ImageMetadata(fields: fields)
    }
}
