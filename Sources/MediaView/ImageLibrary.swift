import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: Sendable {
    case image, video
}

enum MediaFileTypes {
    private static let imageTypes = (CGImageSourceCopyTypeIdentifiers() as! [String]).compactMap { UTType($0) }
    private static let videoTypes = ["mp4", "mov", "m4v"].compactMap { UTType(filenameExtension: $0) }
    static let allowedContentTypes: [UTType] = [.image, .rawImage] + videoTypes

    static func kind(for url: URL, contentType: UTType? = nil) -> MediaKind? {
        let types = [contentType, UTType(filenameExtension: url.pathExtension.lowercased())].compactMap { $0 }
        for type in types {
            if type.conforms(to: .rawImage) { return .image }
            if type.conforms(to: .image), imageTypes.contains(where: { type.conforms(to: $0) }) { return .image }
        }
        return types.contains { type in videoTypes.contains { type.conforms(to: $0) } } ? .video : nil
    }
}

enum LibraryError: LocalizedError {
    case noSupportedInput
    case unreadableDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .noSupportedInput:
            return "无法打开这些项目"
        case .unreadableDirectory:
            return "无法读取文件夹"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noSupportedInput:
            return "请选择可读取的图片、视频或文件夹。RAW 和视频编码支持取决于当前 macOS。"
        case .unreadableDirectory(let url):
            return "请检查“\(url.lastPathComponent)”的访问权限，然后重新打开。"
        }
    }
}

enum LibrarySort: Int, CaseIterable, Sendable {
    case nameAscending, nameDescending, modifiedNewest, modifiedOldest

    var title: String {
        switch self {
        case .nameAscending: return "名称：升序"
        case .nameDescending: return "名称：降序"
        case .modifiedNewest: return "修改时间：从新到旧"
        case .modifiedOldest: return "修改时间：从旧到新"
        }
    }
}

/// 浏览偏好属于本次运行；根目录另由控制器保存，切换范围不能以当前图片的父目录替代。
struct LibraryOptions: Equatable, Sendable {
    var includesSubdirectories = true
    var sort: LibrarySort = .nameAscending
}

struct LibrarySnapshot: Sendable {
    let directory: URL
    let images: [URL]
    let preferredImage: URL?
    let isComplete: Bool
    let skippedPaths: Int

    /// 每次按 URL 重新定位，避免最终排序使当前索引指向另一张图片。
    func currentIndex(keeping currentURL: URL?) -> Int? {
        if let url = currentURL ?? preferredImage, let index = images.firstIndex(of: url) {
            return index
        }
        return images.isEmpty ? nil : 0
    }
}

enum ImageLibrary {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isPackageKey,
        .isSymbolicLinkKey, .contentTypeKey,
    ]

    /// 流只保留最新快照，主线程忙碌时不会积压大目录的历史数组。
    static func scan(opening inputs: [URL], options: LibraryOptions = LibraryOptions(),
                     updateInterval: TimeInterval = 0.2)
        -> AsyncThrowingStream<LibrarySnapshot, Error>
    {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task.detached(priority: .utility) {
                do {
                    let manager = FileManager.default
                    var directory: URL?
                    var preferredImage: URL?
                    var inaccessibleDirectory: URL?

                    // 检查类型和权限也可能访问网络磁盘，不能放在拖拽或 Finder 的主线程回调中。
                    for input in inputs where input.isFileURL {
                        try Task.checkCancellation()
                        let url = input.standardizedFileURL
                        guard let values = try? url.resourceValues(forKeys: keys),
                              values.isHidden != true, values.isPackage != true
                        else { continue }
                        if values.isDirectory == true {
                            guard manager.isReadableFile(atPath: url.path) else {
                                inaccessibleDirectory = url
                                continue
                            }
                            directory = url
                            break
                        }
                        if values.isRegularFile == true,
                           manager.isReadableFile(atPath: url.path),
                           MediaFileTypes.kind(for: url, contentType: values.contentType) != nil
                        {
                            directory = url.deletingLastPathComponent()
                            preferredImage = url
                            break
                        }
                    }

                    guard let directory else {
                        if let inaccessibleDirectory {
                            throw LibraryError.unreadableDirectory(inaccessibleDirectory)
                        }
                        throw LibraryError.noSupportedInput
                    }

                    var images = preferredImage.map { [$0] } ?? []
                    var seen = Set(images)
                    var skippedPaths = 0
                    continuation.yield(LibrarySnapshot(
                        directory: directory, images: images, preferredImage: preferredImage,
                        isComplete: false, skippedPaths: 0
                    ))

                    guard manager.isReadableFile(atPath: directory.path),
                          let enumerator = manager.enumerator(
                            at: directory,
                            includingPropertiesForKeys: Array(keys),
                            options: options.includesSubdirectories
                                ? [.skipsHiddenFiles, .skipsPackageDescendants]
                                : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
                            errorHandler: { _, _ in
                                skippedPaths += 1
                                return !Task.isCancelled
                            }
                          )
                    else { throw LibraryError.unreadableDirectory(directory) }

                    var lastUpdate = ProcessInfo.processInfo.systemUptime
                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        do {
                            let values = try url.resourceValues(forKeys: keys)
                            if values.isHidden == true || values.isPackage == true
                                || values.isSymbolicLink == true
                            {
                                // 不沿目录符号链接扫描，避免循环以及无意间跳出所选目录。
                                enumerator.skipDescendants()
                                continue
                            }
                            if values.isRegularFile == true,
                               MediaFileTypes.kind(for: url, contentType: values.contentType) != nil
                            {
                                if manager.isReadableFile(atPath: url.path) {
                                    let normalized = url.standardizedFileURL
                                    if seen.insert(normalized).inserted { images.append(normalized) }
                                } else {
                                    skippedPaths += 1
                                }
                            }
                        } catch {
                            skippedPaths += 1
                            enumerator.skipDescendants()
                        }

                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastUpdate >= updateInterval {
                            continuation.yield(LibrarySnapshot(
                                directory: directory, images: images, preferredImage: preferredImage,
                                isComplete: false, skippedPaths: skippedPaths
                            ))
                            lastUpdate = now
                        }
                    }

                    images = try sortedImages(images, by: options.sort)
                    try Task.checkCancellation()
                    continuation.yield(LibrarySnapshot(
                        directory: directory, images: images, preferredImage: preferredImage,
                        isComplete: true, skippedPaths: skippedPaths
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    static func comesBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }

    /// 仅时间排序读取文件属性；比较器只查内存，避免在 O(n log n) 次比较中反复访问磁盘。
    static func sortedImages(_ images: [URL], by order: LibrarySort) throws -> [URL] {
        var dates: [URL: Date] = [:]
        if order == .modifiedNewest || order == .modifiedOldest {
            for url in images {
                try Task.checkCancellation()
                // 使用新 URL，避免 Foundation 曾为扫描 URL 缓存的属性掩盖外部修改。
                let freshURL = URL(fileURLWithPath: url.path)
                dates[url] = try? freshURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
        var comparisons = 0
        let result = try images.sorted { lhs, rhs in
            comparisons += 1
            if comparisons.isMultiple(of: 1024) { try Task.checkCancellation() }
            switch order {
            case .nameAscending: return comesBefore(lhs, rhs)
            case .nameDescending: return comesBefore(rhs, lhs)
            case .modifiedNewest, .modifiedOldest:
                switch (dates[lhs], dates[rhs]) {
                case (.some(let left), .some(let right)) where left != right:
                    return order == .modifiedNewest ? left > right : left < right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return comesBefore(lhs, rhs)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// 查询只检查当前快照中的名称，不枚举目录，也不解码匹配项。
    static func matchingImages(in images: [URL], query: String) throws -> [URL] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [URL] = []
        for (index, url) in images.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if url.lastPathComponent.localizedStandardContains(query) { matches.append(url) }
        }
        return matches
    }
}
