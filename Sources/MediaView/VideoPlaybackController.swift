import AVFoundation

@MainActor
final class VideoPlaybackController {
    enum State { case idle, loading, ready, failed }
    typealias InfoLoader = @Sendable (AVURLAsset) async throws -> VideoInfo

    let player = AVPlayer()
    var onStateChanged: (() -> Void)?
    private(set) var state: State = .idle
    private(set) var url: URL?
    private(set) var info: VideoInfo?
    private(set) var error: Error?
    private(set) var isVisible = true
    private let infoLoader: InfoLoader
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var resumesWhenVisible = false

    var isPlaying: Bool { player.rate > 0 || replayTask != nil }

    init(infoLoader: @escaping InfoLoader = { try await VideoInfo.load(from: $0) }) {
        self.infoLoader = infoLoader
        player.actionAtItemEnd = .pause
    }

    deinit {
        loadTask?.cancel()
        replayTask?.cancel()
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func prepare(_ url: URL, visible: Bool) {
        stop()
        self.url = url
        isVisible = visible
        state = .loading
        onStateChanged?()
        let id = generation
        let loader = infoLoader
        let asset = AVURLAsset(url: url)
        loadTask = Task { [weak self] in
            do {
                let info = try await loader(asset)
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                self.loadTask = nil
                self.info = info
                let item = AVPlayerItem(asset: asset)
                self.observe(item, generation: id)
                self.player.replaceCurrentItem(with: item)
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        pause()
        clearObservers()
        player.replaceCurrentItem(with: nil)
        url = nil
        info = nil
        error = nil
        resumesWhenVisible = false
        state = .idle
    }

    func togglePlayback() {
        guard state == .ready, isVisible else { return }
        if isPlaying { pause() } else { play() }
    }

    func pause() {
        replayTask?.cancel()
        replayTask = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
    }

    private func play() {
        guard state == .ready, isVisible else { return }
        if reachedEnd {
            restart()
        } else {
            player.play()
        }
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible {
            resumesWhenVisible = isPlaying
            pause()
        } else {
            let shouldResume = resumesWhenVisible
            resumesWhenVisible = false
            if shouldResume { play() }
        }
    }

    private var reachedEnd: Bool {
        guard let item = player.currentItem, item.duration.isNumeric else { return false }
        let position = item.currentTime()
        return position.isNumeric && position >= item.duration
    }

    private func restart() {
        pause()
        let id = generation
        replayTask = Task { [weak self] in
            guard let self else { return }
            let finished = await self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.generation == id else { return }
            self.replayTask = nil
            if finished, self.isVisible { self.player.play() }
        }
    }

    private func observe(_ item: AVPlayerItem, generation id: UUID) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.generation == id, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.state == .loading else { return }
                    self.state = .ready
                    self.onStateChanged?()
                case .failed: self.fail(item.error ?? VideoLoadError.invalidVideo)
                default: break
                }
            }
        }
        // 原生控件直接修改 player.rate；这里同时覆盖按钮重播和不可见时误触播放。
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == id, self.player.rate > 0 else { return }
                guard self.isVisible else { self.player.pause(); return }
                if self.reachedEnd { self.restart() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.resumesWhenVisible = false
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                  object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.fail(error ?? VideoLoadError.invalidVideo)
            }
        }
    }

    private func fail(_ error: Error) {
        guard state != .failed else { return }
        loadTask = nil
        pause()
        clearObservers()
        player.replaceCurrentItem(with: nil)
        resumesWhenVisible = false
        self.error = error
        state = .failed
        onStateChanged?()
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
    }
}
