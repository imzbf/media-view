import AVKit

@MainActor
final class MediaPlayerView: AVPlayerView {
    weak var canvas: ImageCanvasView?
    private var keyMonitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlsStyle = .inline
        videoGravity = .resizeAspect
        showsFullScreenToggleButton = false
        allowsPictureInPicturePlayback = false
        // 暂停帧的文字识别会截获右键和复制；这些入口在本应用中始终用于当前媒体文件。
        allowsVideoFrameAnalysis = false
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let window else { return }
        // AppKit 窗口默认不发送 mouseMoved；AVKit 控制条需要它来响应悬停和重新出现。
        window.acceptsMouseMovedEvents = true
        // AVKit 的按钮和滑块会先于画布收到空格和方向键。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handlePlaybackKey(event) == true ? nil : event
        }
    }

    func handlePlaybackKey(_ event: NSEvent) -> Bool {
        guard trackingMenus.isEmpty, let canvas, canvas.isVideoVisible, let window, event.window === window,
              window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let responder = window.firstResponder as? NSView,
              !(responder is NSTextView), !(responder is NSTextField),
              responder === canvas || responder.isDescendant(of: self),
              [49, 123, 124, 53].contains(event.keyCode)
        else { return false }
        if event.type == .keyDown { canvas.keyDown(with: event) }
        else if event.keyCode == 49 { canvas.keyUp(with: event) }
        return true
    }

    // 菜单跟踪时第一响应者仍可能是画布，必须让方向键、空格和 Esc 留给原生菜单。
    // 用集合处理嵌套菜单，子菜单结束不能提前重新启用预览快捷键。
    @objc private func menuBeganTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    override func keyDown(with event: NSEvent) {
        if !handlePlaybackKey(event) { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { canvas?.menu(for: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canvas?.draggingEntered(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { canvas?.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { canvas?.draggingEnded(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canvas?.performDragOperation(sender) ?? false
    }
}
