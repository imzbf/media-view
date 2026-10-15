import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DecodeQuality: Hashable, Sendable {
    case screen(maxPixelDimension: Int)
    case original

    /// 对相近窗口尺寸共用缓存，避免拖动窗口边缘时不断产生新的缩略图。
    static func screen(pixelDimension: CGFloat) -> DecodeQuality {
        .screen(maxPixelDimension: max(512, min(8192, Int(ceil(pixelDimension / 512)) * 512)))
    }
}

/// CGImage 创建后只读，可以安全地从解码队列交给主线程的 CALayer。
struct DecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
    let isFullResolution: Bool
    var animation: GIFAnimation? = nil
    var memoryCost: Int { image.bytesPerRow * image.height }
}

/// 请求用途同时决定取消域和队列；缩略条不能通过加载缩略图替换当前主图。
enum ImageDecodeRequest: Sendable {
    case mainImage(URL, DecodeQuality)
    case animationFrame(GIFAnimation, index: Int, quality: DecodeQuality)
    case neighborPrefetch(URL, DecodeQuality)
    case thumbnail(URL, maxPixelDimension: Int)

    var url: URL {
        switch self {
        case .mainImage(let url, _), .neighborPrefetch(let url, _), .thumbnail(let url, _): return url
        case .animationFrame(let animation, _, _): return animation.url
        }
    }

    var quality: DecodeQuality {
        switch self {
        case .mainImage(_, let quality), .neighborPrefetch(_, let quality),
             .animationFrame(_, _, let quality): return quality
        case .thumbnail(_, let dimension): return .screen(maxPixelDimension: dimension)
        }
    }
}

enum ImageDecodeError: LocalizedError, Equatable {
    case unreadableFile
    case unsupportedFormat
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "无法读取图片"
        case .unsupportedFormat: return "系统暂不支持此图片格式"
        case .invalidImage: return "无法解码图片"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unreadableFile: return "文件可能已被移动，或没有访问权限。可继续使用方向键浏览。"
        case .unsupportedFormat: return "RAW 支持取决于 macOS 和相机型号。可继续使用方向键浏览。"
        case .invalidImage: return "图片可能已损坏，或系统不支持此编码。可继续使用方向键浏览。"
        }
    }
}

/// 取消立即释放等待者；ImageIO 的单次原生调用无法中断，但始终最多有两个调用在执行。
private final class ImageIOOperation<Value: Sendable>: Operation, @unchecked Sendable {
    typealias Loader = @Sendable (@escaping @Sendable () -> Bool) throws -> Value

    let url: URL
    private let loader: Loader
    private let resultLock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?

    init(url: URL, loader: @escaping Loader) {
        self.url = url
        self.loader = loader
    }

    func receive(_ continuation: CheckedContinuation<Value, Error>) {
        resultLock.lock()
        if let outcome {
            resultLock.unlock()
            continuation.resume(with: outcome)
        } else {
            self.continuation = continuation
            resultLock.unlock()
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        resultLock.lock()
        guard outcome == nil else {
            resultLock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        continuation = nil
        resultLock.unlock()
        waiting?.resume(with: result)
    }

    override func cancel() {
        super.cancel()
        // 已取消且尚未启动的 Operation 不会执行 main，必须在这里恢复 continuation。
        finish(.failure(CancellationError()))
    }

    override func main() {
        autoreleasepool {
            let result = Result {
                if isCancelled { throw CancellationError() }
                let image = try loader({ [weak self] in self?.isCancelled ?? true })
                if isCancelled { throw CancellationError() }
                return image
            }
            finish(result)
        }
    }
}

private typealias DecodeOperation = ImageIOOperation<DecodedImage>

private extension ImageIOOperation where Value == DecodedImage {
    convenience init(request: ImageDecodeRequest, loader: @escaping ImageDecoder.Loader) {
        self.init(url: request.url) { try loader(request, $0) }
    }
}

/// 主图与 GIF 共用一个优先队列，邻图与缩略图共用另一个后台队列。
/// 元数据也复用后台队列，两个串行队列把不可中断的 ImageIO 调用限制为最多两个。
actor ImageDecoder {
    typealias Loader = @Sendable (ImageDecodeRequest, @escaping @Sendable () -> Bool) throws -> DecodedImage
    typealias MetadataLoader = @Sendable (URL, @escaping @Sendable () -> Bool) throws -> ImageMetadata

    private struct Key: Hashable {
        let url: URL
        let quality: DecodeQuality
    }
    private struct CachedImage {
        let value: DecodedImage
        var lastAccess: UInt64
    }

    private let currentQueue: OperationQueue
    private let prefetchQueue: OperationQueue
    private let loader: Loader
    private let metadataLoader: MetadataLoader
    private let cacheCapacity: Int
    private let byteBudget: Int
    private var cache: [Key: CachedImage] = [:]
    private var accessCounter: UInt64 = 0
    private var generation = UUID()
    private var currentOperation: DecodeOperation?
    private var frameOperations: [UUID: DecodeOperation] = [:]
    private var prefetchOperations: [Key: DecodeOperation] = [:]
    private var thumbnailOperations: [UUID: DecodeOperation] = [:]
    private var metadataOperations: [UUID: ImageIOOperation<ImageMetadata>] = [:]
    private var thumbnailCache: [Key: CachedImage] = [:]
    private let thumbnailCapacity: Int
    private let thumbnailByteBudget: Int

    init(cacheCapacity: Int = 6, byteBudget: Int = 256 * 1024 * 1024,
         thumbnailCapacity: Int = 128, thumbnailByteBudget: Int = 32 * 1024 * 1024,
         loader: @escaping Loader = { try ImageDecoder.decode($0, isCancelled: $1) },
         metadataLoader: @escaping MetadataLoader = { try ImageMetadata.read($0, isCancelled: $1) })
    {
        self.cacheCapacity = max(0, cacheCapacity)
        self.byteBudget = max(0, byteBudget)
        self.thumbnailCapacity = max(0, thumbnailCapacity)
        self.thumbnailByteBudget = max(0, thumbnailByteBudget)
        self.loader = loader
        self.metadataLoader = metadataLoader
        currentQueue = OperationQueue()
        currentQueue.name = "ImageView.main-and-animation"
        currentQueue.maxConcurrentOperationCount = 1
        currentQueue.qualityOfService = .userInitiated
        prefetchQueue = OperationQueue()
        prefetchQueue.name = "ImageView.neighbors-and-thumbnails"
        prefetchQueue.maxConcurrentOperationCount = 1
        prefetchQueue.qualityOfService = .utility
    }

    deinit {
        currentQueue.cancelAllOperations()
        prefetchQueue.cancelAllOperations()
    }

    func reset() {
        generation = UUID()
        currentOperation?.cancel()
        currentOperation = nil
        cancelAnimationFrames()
        cancelPrefetch()
        thumbnailOperations.values.forEach { $0.cancel() }
        thumbnailOperations.removeAll()
        metadataOperations.values.forEach { $0.cancel() }
        metadataOperations.removeAll()
        cache.removeAll()
        thumbnailCache.removeAll()
    }

    /// 同 URL 的外部修改必须同时失效各清晰度、缩略图和在途工作。
    /// 任务从登记表移除后，取消前已进入 ImageIO 的迟到结果也不能再次写回缓存。
    func invalidate(_ urls: Set<URL>) {
        cache = cache.filter { !urls.contains($0.key.url) }
        thumbnailCache = thumbnailCache.filter { !urls.contains($0.key.url) }
        if let operation = currentOperation, urls.contains(operation.url) {
            operation.cancel()
            currentOperation = nil
        }
        for (id, operation) in frameOperations where urls.contains(operation.url) {
            operation.cancel()
            frameOperations.removeValue(forKey: id)
        }
        for (key, operation) in prefetchOperations where urls.contains(key.url) {
            operation.cancel()
            prefetchOperations.removeValue(forKey: key)
        }
        for (id, operation) in thumbnailOperations where urls.contains(operation.url) {
            operation.cancel()
            thumbnailOperations.removeValue(forKey: id)
        }
        for (id, operation) in metadataOperations where urls.contains(operation.url) {
            operation.cancel()
            metadataOperations.removeValue(forKey: id)
        }
    }

    /// 信息卡关闭或切图只取消自己的读取；不触碰主图请求，也不创建像素缓存。
    func metadata(of url: URL) async throws -> ImageMetadata {
        try Task.checkCancellation()
        let id = UUID()
        let loader = metadataLoader
        let operation = ImageIOOperation<ImageMetadata>(url: url) { try loader(url, $0) }
        operation.queuePriority = .high
        metadataOperations[id] = operation
        let requestGeneration = generation
        defer { metadataOperations.removeValue(forKey: id) }
        let result = try await Self.run(operation, on: prefetchQueue)
        try Task.checkCancellation()
        guard generation == requestGeneration, metadataOperations[id] === operation else {
            throw CancellationError()
        }
        return result
    }

    func load(_ url: URL, quality: DecodeQuality) async throws -> DecodedImage {
        try Task.checkCancellation()
        currentOperation?.cancel()
        currentOperation = nil
        cancelAnimationFrames()
        cancelPrefetch()
        let key = Key(url: url, quality: quality)
        if let value = cachedImage(for: key) { return value }

        let operation = DecodeOperation(request: .mainImage(url, quality), loader: loader)
        operation.queuePriority = .veryHigh
        currentOperation = operation
        let requestGeneration = generation
        defer {
            if currentOperation === operation { currentOperation = nil }
        }
        let image = try await Self.run(operation, on: currentQueue)
        try Task.checkCancellation()
        guard generation == requestGeneration, currentOperation === operation else {
            throw CancellationError()
        }
        insert(image, for: key)
        return image
    }

    /// 动画帧只由播放控制器保留两帧，不进入主图 LRU，避免缓存每个播放位置。
    func frame(of animation: GIFAnimation, at index: Int, quality: DecodeQuality) async throws -> DecodedImage {
        try Task.checkCancellation()
        let id = UUID()
        let operation = DecodeOperation(request: .animationFrame(animation, index: index, quality: quality),
                                        loader: loader)
        operation.queuePriority = .high
        frameOperations[id] = operation
        let requestGeneration = generation
        defer { frameOperations.removeValue(forKey: id) }
        let image = try await Self.run(operation, on: currentQueue)
        try Task.checkCancellation()
        guard generation == requestGeneration, frameOperations[id] === operation else {
            throw CancellationError()
        }
        return image
    }

    /// 每个缩略请求有独立取消句柄；复用单元格时取消它不会影响主图或其他缩略图。
    func thumbnail(_ url: URL, maxPixelDimension: Int) async throws -> DecodedImage {
        try Task.checkCancellation()
        let key = Key(url: url, quality: .screen(maxPixelDimension: maxPixelDimension))
        if let cached = thumbnailCache[key] {
            accessCounter &+= 1
            thumbnailCache[key]?.lastAccess = accessCounter
            return cached.value
        }
        let id = UUID()
        let operation = DecodeOperation(request: .thumbnail(url, maxPixelDimension: maxPixelDimension), loader: loader)
        operation.queuePriority = .normal
        thumbnailOperations[id] = operation
        let requestGeneration = generation
        defer { thumbnailOperations.removeValue(forKey: id) }
        let image = try await Self.run(operation, on: prefetchQueue)
        try Task.checkCancellation()
        guard generation == requestGeneration, thumbnailOperations[id] === operation else {
            throw CancellationError()
        }
        if thumbnailCapacity > 0, image.memoryCost <= thumbnailByteBudget {
            accessCounter &+= 1
            thumbnailCache[key] = CachedImage(value: image, lastAccess: accessCounter)
            while thumbnailCache.count > thumbnailCapacity || thumbnailCachedByteCount > thumbnailByteBudget {
                guard let oldest = thumbnailCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
                else { break }
                thumbnailCache.removeValue(forKey: oldest)
            }
        }
        return image
    }

    /// 原始尺寸只为当前图片按需加载；相邻两张始终使用有界的屏幕缩略图。
    func prefetch(_ urls: [URL], quality: DecodeQuality) {
        guard case .screen = quality else { return }
        let desired = Set(urls.prefix(2).map { Key(url: $0, quality: quality) })
        for (key, operation) in prefetchOperations where !desired.contains(key) {
            operation.cancel()
            prefetchOperations.removeValue(forKey: key)
        }
        for url in urls.prefix(2) {
            let key = Key(url: url, quality: quality)
            guard prefetchOperations[key] == nil, cachedImage(for: key) == nil else { continue }
            let operation = DecodeOperation(request: .neighborPrefetch(url, quality), loader: loader)
            operation.queuePriority = .low
            prefetchOperations[key] = operation
            let requestGeneration = generation
            let queue = prefetchQueue
            Task { [weak self] in
                let result = try? await Self.run(operation, on: queue)
                await self?.finishPrefetch(result, for: key, operation: operation,
                                           generation: requestGeneration)
            }
        }
    }

    var cachedURLs: Set<URL> { Set(cache.keys.map(\.url)) }
    var cachedByteCount: Int { cache.values.reduce(0) { $0 + $1.value.memoryCost } }
    var thumbnailCachedURLs: Set<URL> { Set(thumbnailCache.keys.map(\.url)) }
    var thumbnailCachedCount: Int { thumbnailCache.count }
    var thumbnailCachedByteCount: Int { thumbnailCache.values.reduce(0) { $0 + $1.value.memoryCost } }

    private func cancelAnimationFrames() {
        frameOperations.values.forEach { $0.cancel() }
        frameOperations.removeAll()
    }

    private func finishPrefetch(_ image: DecodedImage?, for key: Key,
                                operation: DecodeOperation, generation requestGeneration: UUID)
    {
        guard generation == requestGeneration, prefetchOperations[key] === operation else { return }
        prefetchOperations.removeValue(forKey: key)
        if let image, !operation.isCancelled { insert(image, for: key) }
    }

    private func cancelPrefetch() {
        prefetchOperations.values.forEach { $0.cancel() }
        prefetchOperations.removeAll()
    }

    private func cachedImage(for key: Key) -> DecodedImage? {
        // 更大的缩略图或原图也能满足小窗口；反向复用会导致 ⌘1 显示低清图片。
        let match = cache.keys.first { candidate in
            guard candidate.url == key.url, let value = cache[candidate]?.value else { return false }
            if value.isFullResolution { return true }
            switch (candidate.quality, key.quality) {
            case (.screen(let cached), .screen(let requested)): return cached >= requested
            default: return false
            }
        }
        guard let match else { return nil }
        accessCounter &+= 1
        cache[match]?.lastAccess = accessCounter
        return cache[match]?.value
    }

    private func insert(_ image: DecodedImage, for key: Key) {
        // 超过预算的原图可显示，但不额外保留在缓存中。
        guard cacheCapacity > 0, image.memoryCost <= byteBudget else { return }
        accessCounter &+= 1
        cache[key] = CachedImage(value: image, lastAccess: accessCounter)
        while cache.count > cacheCapacity || cachedByteCount > byteBudget {
            guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
            else { break }
            cache.removeValue(forKey: oldest)
        }
    }

    private nonisolated static func run<Value>(_ operation: ImageIOOperation<Value>, on queue: OperationQueue)
        async throws -> Value
    {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.receive(continuation)
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    nonisolated static func decode(_ request: ImageDecodeRequest,
                                   isCancelled: @escaping @Sendable () -> Bool) throws -> DecodedImage
    {
        switch request {
        case .animationFrame(let animation, let index, let quality):
            return try animation.decodeFrame(at: index, quality: quality, isCancelled: isCancelled)
        case .thumbnail:
            return try decodeImage(request.url, quality: request.quality, includeAnimation: false,
                                   isCancelled: isCancelled)
        case .mainImage, .neighborPrefetch:
            return try decodeImage(request.url, quality: request.quality, isCancelled: isCancelled)
        }
    }

    /// 主图/邻图返回首帧及 GIF 元数据；缩略图不建立播放源。其他格式仍只读索引 0。
    nonisolated static func decodeImage(_ url: URL, quality: DecodeQuality,
                                        includeAnimation: Bool = true,
                                        isCancelled: @escaping @Sendable () -> Bool) throws -> DecodedImage
    {
        if isCancelled() { throw CancellationError() }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImageDecodeError.unreadableFile
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageDecodeError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0
        else { throw ImageDecodeError.invalidImage }
        if isCancelled() { throw CancellationError() }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let pixelSize = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                               height: rotated ? width.doubleValue : height.doubleValue)
        let image = try createImage(source: source, index: 0, pixelSize: pixelSize, quality: quality,
                                    isCancelled: isCancelled)
        let animation: GIFAnimation?
        if includeAnimation, CGImageSourceGetType(source) as String? == UTType.gif.identifier {
            // 第二帧就损坏时 ImageIO 可能只报告一帧，仍需检查容器中的后续描述符。
            let candidate = try GIFAnimation(source: source, url: url, pixelSize: pixelSize, isCancelled: isCancelled)
            animation = candidate.frameCount > 1 ? candidate : nil
        } else {
            animation = nil
        }
        return DecodedImage(image: image, pixelSize: pixelSize,
                            isFullResolution: image.width >= Int(pixelSize.width)
                                && image.height >= Int(pixelSize.height), animation: animation)
    }

    /// ImageIO 将 GIF 的局部更新、透明索引与 disposal 合成为完整逻辑画布后再降采样。
    /// 禁用源缓存并释放本索引的解码缓存，不能让长 GIF 在 ImageIO 内累计所有帧。
    nonisolated static func createImage(source: CGImageSource, index: Int, pixelSize: CGSize,
                                        quality: DecodeQuality,
                                        isCancelled: @escaping @Sendable () -> Bool) throws -> CGImage
    {
        if isCancelled() { throw CancellationError() }
        let maximumDimension: Int
        switch quality {
        case .screen(let dimension): maximumDimension = max(1, dimension)
        case .original: maximumDimension = Int(max(pixelSize.width, pixelSize.height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
        else {
            throw ImageDecodeError.invalidImage
        }
        if isCancelled() { throw CancellationError() }
        return image
    }
}
