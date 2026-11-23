import AVFoundation

enum VideoLoadError: LocalizedError {
    case unreadableFile, noVideoTrack, unsupportedEncoding, invalidVideo

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "无法读取视频"
        case .noVideoTrack: return "文件中没有视频画面"
        case .unsupportedEncoding: return "系统暂不支持此视频编码"
        case .invalidVideo: return "无法载入视频"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unreadableFile: return "文件可能已被移动，或没有访问权限。可继续使用方向键浏览。"
        case .noVideoTrack: return "此文件没有可显示的视频轨道。可继续使用方向键浏览。"
        case .unsupportedEncoding, .invalidVideo:
            return "文件可能已损坏，或当前 macOS 不支持此编码。可继续使用方向键浏览。"
        }
    }
}

/// 主预览和信息卡共用方向修正后的尺寸；读取轨道属性不会解码整段视频。
struct VideoInfo: Equatable, Sendable {
    let pixelSize: CGSize
    let duration: TimeInterval

    var durationText: String {
        let seconds = Int(duration.rounded(.down))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func load(from asset: AVURLAsset) async throws -> VideoInfo {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard FileManager.default.isReadableFile(atPath: asset.url.path) else { throw VideoLoadError.unreadableFile }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw VideoLoadError.noVideoTrack }
            async let playable = asset.load(.isPlayable)
            async let duration = asset.load(.duration)
            async let size = track.load(.naturalSize)
            async let transform = track.load(.preferredTransform)
            guard try await playable else { throw VideoLoadError.unsupportedEncoding }
            let seconds = try await duration.seconds
            let bounds = try await CGRect(origin: .zero, size: size).applying(transform)
            try Task.checkCancellation()
            guard seconds.isFinite, seconds > 0, bounds.width > 0, bounds.height > 0 else {
                throw VideoLoadError.invalidVideo
            }
            return VideoInfo(pixelSize: bounds.size, duration: seconds)
        } onCancel: {
            asset.cancelLoading()
        }
    }

    func metadata(for url: URL) -> MediaMetadata {
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try? freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var fields = [MediaMetadata.Field(name: "文件", value: url.lastPathComponent),
                      .init(name: "格式", value: url.pathExtension.uppercased()),
                      .init(name: "尺寸", value: "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"),
                      .init(name: "时长", value: durationText)]
        if let size = values?.fileSize {
            fields.append(.init(name: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let date = values?.contentModificationDate {
            fields.append(.init(name: "修改时间", value: DateFormatter.localizedString(from: date,
                dateStyle: .medium, timeStyle: .medium)))
        }
        return MediaMetadata(fields: fields)
    }
}

/// 可见窗口可能包含数十段视频，只让两个首帧提取同时执行，避免每个缩略图都建立解码管线。
/// 已取消的调用立即返回，但其原生工作退出前仍占用名额，快速滚动也不会绕过并发上限。
actor VideoThumbnailLoader {
    typealias Loader = @Sendable (URL, Int) async throws -> DecodedImage
    private struct Request {
        let url: URL
        let dimension: Int
        let continuation: CheckedContinuation<DecodedImage, Error>
    }

    private let loader: Loader
    private let concurrency: Int
    private var requests: [UUID: Request] = [:]
    private var pending: [UUID] = []
    private var active: [UUID: Task<Void, Never>] = [:]

    init(concurrency: Int = 2, loader: @escaping Loader = { try await generate($0, dimension: $1) }) {
        self.concurrency = max(1, concurrency)
        self.loader = loader
    }

    func load(_ url: URL, dimension: Int) async throws -> DecodedImage {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                requests[id] = Request(url: url, dimension: dimension, continuation: continuation)
                pending.append(id)
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func startNext() {
        while active.count < concurrency, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let request = requests[id] else { continue }
            let loader = loader
            active[id] = Task {
                let result: Result<DecodedImage, Error>
                do {
                    let image = try await loader(request.url, request.dimension)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch { result = .failure(error) }
                active.removeValue(forKey: id)
                requests.removeValue(forKey: id)?.continuation.resume(with: result)
                startNext()
            }
        }
    }

    private func cancel(_ id: UUID) {
        requests.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        pending.removeAll { $0 == id }
        active[id]?.cancel()
    }

    private static func generate(_ url: URL, dimension: Int) async throws -> DecodedImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        // 请求起始位置附近的首个可显示帧，保留系统容差以兼容存在编辑偏移的视频。
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await generator.image(at: .zero)
            try Task.checkCancellation()
            return DecodedImage(image: result.image,
                                pixelSize: CGSize(width: result.image.width, height: result.image.height),
                                isFullResolution: false)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}
