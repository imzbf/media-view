import AppKit

/// 复核预览拥有自己的解码与播放任务，切版本不会取消原浏览会话或后台查重分析。
@MainActor
final class DuplicatePreviewController: NSViewController {
    let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    let decoder = ImageDecoder()
    private let video = VideoPlaybackController()
    private lazy var gif = GIFPlaybackController(decoder: decoder)
    private var task: Task<Void, Never>?
    private var request = UUID()
    private var image: DecodedImage?
    private var visible = true
    private(set) var url: URL?

    override func loadView() {
        view = canvas
        canvas.showStatus(title: "选择一个版本预览", detail: "照片可缩放查看，视频可播放核对。")
        canvas.onToggleVideoPlayback = { [weak self] in self?.video.togglePlayback() }
        canvas.onActualSize = { [weak self] in
            guard let self, self.image?.isFullResolution == false else { return }
            self.load(quality: .original, preservingImage: true)
        }
        video.onStateChanged = { [weak self] in
            guard let self, self.video.url == self.url else { return }
            switch self.video.state {
            case .ready: self.canvas.finishVideoLoading()
            case .failed:
                self.canvas.showStatus(title: "无法预览视频", detail: self.video.error?.localizedDescription ?? "请检查文件是否可用。")
            default: break
            }
        }
        gif.onFrame = { [weak self] in self?.canvas.displayFrame($0) }
        gif.onFailure = { [weak self] in self?.canvas.showNotice($0.localizedDescription) }
    }

    func show(_ url: URL?) {
        _ = view
        guard self.url != url else { return }
        stop()
        self.url = url
        guard url != nil else {
            canvas.showStatus(title: "选择一个版本预览", detail: "照片可缩放查看，视频可播放核对。")
            return
        }
        load(quality: canvas.screenQuality, preservingImage: false)
    }

    private func load(quality: DecodeQuality, preservingImage: Bool) {
        guard let url else { return }
        task?.cancel()
        request = UUID()
        let id = request
        if MediaFileTypes.kind(for: url) == .video {
            canvas.prepareForVideo(video.player, filename: url.lastPathComponent)
            video.prepare(url, visible: visible)
            return
        }
        canvas.prepareForLoading()
        canvas.setLoadingIndicatorVisible(true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.decoder.load(url, quality: quality)
                try Task.checkCancellation()
                guard self.request == id, self.url == url else { return }
                self.image = image
                self.canvas.setLoadingIndicatorVisible(false)
                self.canvas.display(image, filename: url.lastPathComponent, resetTransform: !preservingImage)
                if let animation = image.animation {
                    self.gif.start(animation, firstFrame: image, quality: quality, visible: self.visible)
                }
            } catch {
                guard !Task.isCancelled, self.request == id else { return }
                self.canvas.setLoadingIndicatorVisible(false)
                self.canvas.showStatus(title: "无法预览这个版本", detail: error.localizedDescription,
                    symbol: "exclamationmark.triangle")
            }
        }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        video.setVisible(visible)
        gif.setVisible(visible)
    }

    func stop() {
        task?.cancel()
        task = nil
        request = UUID()
        image = nil
        url = nil
        video.stop()
        gif.stop()
        canvas.cancelInteraction()
        canvas.setLoadingIndicatorVisible(false)
    }
}
