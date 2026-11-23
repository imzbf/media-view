import Foundation

/// 单调时钟只推进已显示帧；解码赶不上时延长当前帧，不补播一串过期帧。
/// 所有异步回填都验证 generation，切图、暂停或切换清晰度会立即取消旧任务。
@MainActor
final class GIFPlaybackController {
    var onFrame: ((DecodedImage) -> Void)?
    var onFailure: ((Error) -> Void)?

    private(set) var animation: GIFAnimation?
    private(set) var quality: DecodeQuality = .screen(maxPixelDimension: 512)
    private(set) var currentStep = 0
    private(set) var isFinished = false
    private(set) var hasFailed = false
    private(set) var isVisible = true
    private(set) var needsQualityRefresh = false
    private let decoder: ImageDecoder
    private let byteBudget: Int
    private let now: () -> TimeInterval
    private let schedulesTimers: Bool
    private var generation = UUID()
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var remainingDuration: TimeInterval = 0
    private var frameByteCost = 1
    private var buffer: [Int: DecodedImage] = [:]
    private var failures: [Int: Error] = [:]
    private var pending: [Int: Task<Void, Never>] = [:]
    private var qualityTask: Task<Void, Never>?

    var currentFrameIndex: Int { animation.map { currentStep % $0.frameCount } ?? 0 }
    var isPlaying: Bool { animation != nil && isVisible && !isFinished && !hasFailed && !needsQualityRefresh }
    var bufferedFrameCount: Int { buffer.count }
    var bufferedByteCount: Int { buffer.values.reduce(0) { $0 + $1.memoryCost } }
    var pendingFrameCount: Int { pending.count }

    init(decoder: ImageDecoder, byteBudget: Int = 64 * 1024 * 1024,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesTimers: Bool = true)
    {
        self.decoder = decoder
        self.byteBudget = max(0, byteBudget)
        self.now = now
        self.schedulesTimers = schedulesTimers
    }

    deinit {
        timer?.invalidate()
        pending.values.forEach { $0.cancel() }
        qualityTask?.cancel()
    }

    func start(_ animation: GIFAnimation, firstFrame: DecodedImage,
               quality: DecodeQuality, visible: Bool)
    {
        stop()
        guard animation.frameCount > 1 else { return }
        self.animation = animation
        self.quality = quality
        isVisible = visible
        frameByteCost = max(1, firstFrame.memoryCost)
        remainingDuration = animation.frameDurations[0]
        deadline = now() + remainingDuration
        fillBuffer()
        scheduleTick()
    }

    func stop() {
        invalidateWork()
        animation = nil
        currentStep = 0
        isFinished = false
        hasFailed = false
        needsQualityRefresh = false
    }

    /// 不可见时保存当前帧剩余时间，恢复时从该位置继续；失焦但仍可见不算暂停。
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        if isPlaying { remainingDuration = max(0, deadline - now()) }
        isVisible = visible
        invalidateWork()
        guard visible, animation != nil else { return }
        if needsQualityRefresh {
            reloadCurrentFrame()
        } else {
            deadline = now() + remainingDuration
            fillBuffer()
            scheduleTick()
        }
    }

    /// ⌘1 重新解码当前索引，然后以原来的帧、轮次和剩余延时继续，绝不重播首帧。
    func changeQuality(to quality: DecodeQuality) {
        guard animation != nil, self.quality != quality else { return }
        if isPlaying { remainingDuration = max(0, deadline - now()) }
        self.quality = quality
        invalidateWork()
        needsQualityRefresh = true
        if isVisible { reloadCurrentFrame() }
    }

    private func reloadCurrentFrame() {
        guard let animation else { return }
        let requestGeneration = generation
        let index = currentFrameIndex
        let quality = quality
        let decoder = decoder
        qualityTask = Task { [weak self] in
            do {
                let image = try await decoder.frame(of: animation, at: index, quality: quality)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.qualityTask = nil
                self.needsQualityRefresh = false
                self.frameByteCost = max(1, image.memoryCost)
                self.deadline = self.now() + self.remainingDuration
                self.onFrame?(image)
                self.fillBuffer()
                self.scheduleTick()
            } catch is CancellationError {
                // 暂停后仍保留 needsQualityRefresh，可见时再解码同一帧。
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func tick() {
        timer?.invalidate()
        timer = nil
        guard isPlaying else { return }
        let timestamp = now()
        guard timestamp >= deadline else {
            scheduleTick()
            return
        }
        let next = currentStep + 1
        guard canDisplay(step: next) else {
            // 最后一帧也停留完整延时，有限动画结束后保持最后一帧。
            isFinished = true
            invalidateWork()
            return
        }
        if let error = failures[next] {
            fail(error)
        } else if let image = buffer.removeValue(forKey: next) {
            present(image, step: next, at: timestamp)
        } else {
            // 单帧大于预算时不预取；到期才解码并直接交给画布，不进入缓冲。
            requestFrame(step: next)
        }
    }

    private func canDisplay(step: Int) -> Bool {
        guard let animation else { return false }
        return animation.totalPlays.map { step / animation.frameCount < $0 } ?? true
    }

    private func present(_ image: DecodedImage, step: Int, at timestamp: TimeInterval) {
        guard let animation else { return }
        currentStep = step
        remainingDuration = animation.frameDurations[currentFrameIndex]
        deadline = timestamp + remainingDuration
        onFrame?(image)
        fillBuffer()
        scheduleTick()
    }

    private func fillBuffer() {
        guard isPlaying else { return }
        // 在发起解码前预留字节，两个在途请求也不能各自占满 64 MiB。
        var reservedBytes = bufferedByteCount + pending.count * frameByteCost
        for step in (currentStep + 1)...(currentStep + 2) {
            guard canDisplay(step: step), failures[step] == nil else { break }
            if buffer[step] != nil || pending[step] != nil { continue }
            guard frameByteCost <= byteBudget - reservedBytes else { break }
            requestFrame(step: step)
            reservedBytes += frameByteCost
        }
    }

    private func requestFrame(step: Int) {
        guard let animation, pending[step] == nil else { return }
        let requestGeneration = generation
        let quality = quality
        let decoder = decoder
        pending[step] = Task { [weak self] in
            do {
                let image = try await decoder.frame(of: animation, at: step % animation.frameCount, quality: quality)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.pending.removeValue(forKey: step)
                self.frameByteCost = max(self.frameByteCost, image.memoryCost)
                let timestamp = self.now()
                if step == self.currentStep + 1, timestamp >= self.deadline {
                    self.present(image, step: step, at: timestamp)
                } else {
                    if image.memoryCost <= self.byteBudget - self.bufferedByteCount {
                        self.buffer[step] = image
                    }
                    self.fillBuffer()
                    self.scheduleTick()
                }
            } catch is CancellationError {
                // generation 已变更；旧帧既不能进入缓冲，也不能覆盖画布。
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.pending.removeValue(forKey: step)
                // 预取的后续帧损坏时，先显示已解码的前一帧，到期才报告错误。
                self.failures[step] = error
                self.tick()
            }
        }
    }

    private func scheduleTick() {
        timer?.invalidate()
        timer = nil
        guard schedulesTimers, isPlaying else { return }
        let delay = deadline - now()
        if delay <= 0, canDisplay(step: currentStep + 1),
           buffer[currentStep + 1] == nil, failures[currentStep + 1] == nil
        {
            // 到期但还在解码时由完成回调唤醒，避免零间隔计时器忙转。
            requestFrame(step: currentStep + 1)
            return
        }
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = min(0.001, max(0, delay) * 0.05)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fail(_ error: Error) {
        hasFailed = true
        needsQualityRefresh = false
        invalidateWork()
        onFailure?(error)
    }

    private func invalidateWork() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        qualityTask?.cancel()
        qualityTask = nil
        buffer.removeAll()
        failures.removeAll()
    }
}
