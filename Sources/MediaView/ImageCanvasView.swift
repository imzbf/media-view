import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class ImageCanvasView: NSView {
    var onOpenFiles: (([URL]) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onActualSize: (() -> Void)?
    var onZoomChanged: (() -> Void)?
    var onDisplayChanged: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onDismissOverlay: (() -> Bool)?
    var onToggleVideoPlayback: (() -> Void)?
    var onSelectionKey: ((NSEvent) -> Bool)?

    private(set) var geometry = CanvasGeometry()
    private(set) var videoView: MediaPlayerView?
    var isVideoVisible: Bool { videoView?.isHidden == false }
    private let imageLayer = CALayer()
    private let dropBorder = CAShapeLayer()
    private let statusStack = NSStackView()
    private let statusIcon = NSImageView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "打开…", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let notice = NSTextField(labelWithString: "")
    private let noticeBackground = ViewerOverlayView(frame: .zero)
    private var spaceHeld = false
    private var pan: (point: CGPoint, usesSpace: Bool)?
    private var noticeBottom: NSLayoutConstraint?

    override var acceptsFirstResponder: Bool { true }

    /// 直接抓取和手形光标使用同一个可见区域；只有按住空格时才允许从留白处起拖。
    private var directPanRect: CGRect {
        let frame = geometry.imageFrame
        guard geometry.mode != .fit, frame.width > bounds.width || frame.height > bounds.height else { return .null }
        return bounds.intersection(frame)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        dropBorder.strokeColor = NSColor.controlAccentColor.cgColor
        dropBorder.fillColor = NSColor.clear.cgColor
        dropBorder.lineWidth = 3
        dropBorder.isHidden = true
        layer?.addSublayer(dropBorder)

        statusIcon.contentTintColor = .tertiaryLabelColor
        statusIcon.imageScaling = .scaleProportionallyUpOrDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        statusTitle.font = .systemFont(ofSize: 18, weight: .medium)
        statusTitle.textColor = .secondaryLabelColor
        statusTitle.alignment = .center
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.alignment = .center
        statusDetail.maximumNumberOfLines = 4
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openPanel)
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 12
        [statusIcon, statusTitle, statusDetail, openButton].forEach(statusStack.addArrangedSubview)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            statusDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        noticeBackground.translatesAutoresizingMaskIntoConstraints = false
        noticeBackground.isHidden = true
        addSubview(noticeBackground)
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .labelColor
        notice.alignment = .center
        notice.lineBreakMode = .byTruncatingTail
        notice.maximumNumberOfLines = 2
        notice.cell?.wraps = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.isHidden = true
        addSubview(notice)
        noticeBottom = notice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        NSLayoutConstraint.activate([
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            noticeBottom!,
            notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -100),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            noticeBackground.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: -12),
            noticeBackground.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: 12),
            noticeBackground.topAnchor.constraint(equalTo: notice.topAnchor, constant: -8),
            noticeBackground.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: 8),
        ])
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        showWelcome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var screenQuality: DecodeQuality {
        let screenSize = window?.screen?.frame.size ?? bounds.size
        let backingScale = window?.backingScaleFactor ?? 2
        return .screen(pixelDimension: max(screenSize.width, screenSize.height) * backingScale)
    }

    func showWelcome() {
        showStatus(title: "拖入图片、视频或文件夹", detail: "使用 ← → 浏览 · 图片可缩放拖拽 · 视频按空格播放",
                   symbol: "photo.on.rectangle.angled", showOpenButton: true)
    }

    func showStatus(title: String, detail: String, symbol: String = "photo",
                    showOpenButton: Bool = false)
    {
        hideVideo()
        // 清空也要关闭隐式动画；淡出会保留旧位图，快切到大图时便会按新 bounds 短暂放大。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        geometry.setImage(size: .zero)
        cancelInteraction()
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        openButton.isHidden = !showOpenButton
        statusStack.isHidden = false
        notice.isHidden = true
        noticeBackground.isHidden = true
        setLoadingIndicatorVisible(false)
        setAccessibilityLabel(title)
        setAccessibilityValue(nil)
    }

    func prepareForLoading() {
        if !geometry.hasImage {
            showStatus(title: "正在载入…", detail: "", symbol: "photo")
        }
        notice.isHidden = true
        noticeBackground.isHidden = true
        setLoadingIndicatorVisible(false)
    }

    func prepareForVideo(_ player: AVPlayer, filename: String) {
        showStatus(title: "正在载入视频…", detail: "", symbol: "video")
        if videoView == nil {
            let playerView = MediaPlayerView(frame: bounds)
            playerView.canvas = self
            playerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(playerView, positioned: .below, relativeTo: statusStack)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
                playerView.topAnchor.constraint(equalTo: topAnchor),
                playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            videoView = playerView
            layer?.addSublayer(dropBorder)
        }
        videoView?.player = player
        videoView?.isHidden = false
        noticeBottom?.constant = -88
        // 以组暴露原生播放控件，不能沿用静态图片的叶节点角色。
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(filename)，视频")
    }

    func finishVideoLoading() {
        guard isVideoVisible else { return }
        statusStack.isHidden = true
        setLoadingIndicatorVisible(false)
    }

    private func hideVideo() {
        videoView?.player = nil
        videoView?.isHidden = true
        noticeBottom?.constant = -20
        setAccessibilityRole(.image)
    }

    func setLoadingIndicatorVisible(_ visible: Bool) {
        if visible { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !visible
    }

    func display(_ decoded: DecodedImage, filename: String, resetTransform: Bool) {
        hideVideo()
        // 内容和几何一同提交，暂留的旧位图不会套用新图尺寸，也不会触发隐式淡入。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // 旧图上的拖动不能带到新图；同一图片升级解码质量时则保留正在进行的手势。
        if resetTransform || geometry.imageSize != decoded.pixelSize { pan = nil }
        geometry.setImage(size: decoded.pixelSize, resetTransform: resetTransform || !geometry.hasImage)
        displayFrame(decoded)
        statusStack.isHidden = true
        setLoadingIndicatorVisible(false)
        notice.isHidden = true
        noticeBackground.isHidden = true
        setAccessibilityLabel(filename)
        updateImageLayer()
    }

    /// 换帧不碰几何、文件名或布局；关闭 contents 的隐式过渡，拖拽时也不会重置缩放和平移。
    func displayFrame(_ decoded: DecodedImage) {
        guard geometry.hasImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = decoded.image
        CATransaction.commit()
    }

    func showNotice(_ text: String) {
        setLoadingIndicatorVisible(false)
        notice.stringValue = text
        notice.isHidden = text.isEmpty
        noticeBackground.isHidden = text.isEmpty
        notice.toolTip = text.isEmpty ? nil : text
    }

    func fitToWindow() {
        geometry.fit()
        updateImageLayer()
    }

    func actualSize() {
        guard geometry.hasImage else { return }
        geometry.actualSize()
        updateImageLayer()
        onActualSize?()
    }

    func zoom(by factor: CGFloat) {
        zoom(by: factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func rotate(clockwise: Bool) {
        geometry.rotate(clockwise: clockwise)
        updateImageLayer()
    }

    func mirror(horizontal: Bool) {
        geometry.mirror(horizontal: horizontal)
        updateImageLayer()
    }

    func resetOrientation() {
        geometry.resetOrientation()
        updateImageLayer()
    }

    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        geometry.zoom(by: factor, around: anchor)
        updateImageLayer()
    }

    override func layout() {
        super.layout()
        let backingScale = window?.backingScaleFactor ?? 1
        let displayChanged = geometry.viewportSize != bounds.size || geometry.backingScale != backingScale
        geometry.resize(to: bounds.size, backingScale: backingScale)
        updateImageLayer()
        dropBorder.frame = bounds
        dropBorder.path = CGPath(roundedRect: bounds.insetBy(dx: 7, dy: 7),
                                 cornerWidth: 8, cornerHeight: 8, transform: nil)
        if displayChanged { onDisplayChanged?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func updateImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 有旋转时不能设置 CALayer.frame；它是变换后的包围盒，反推 bounds 会造成拉伸。
        imageLayer.bounds = CGRect(origin: .zero, size: CGSize(width: geometry.imageSize.width * geometry.scale,
                                                              height: geometry.imageSize.height * geometry.scale))
        imageLayer.position = CGPoint(x: geometry.imageFrame.midX, y: geometry.imageFrame.midY)
        imageLayer.setAffineTransform(geometry.orientation)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
        setAccessibilityValue(geometry.hasImage
            ? "\(Int((geometry.scale * geometry.backingScale * 100).rounded()))%" : nil)
        // 抓取期间整个画布都是闭手光标；松开时再按最终图片位置更新热区。
        if pan == nil { window?.invalidateCursorRects(for: self) }
        onZoomChanged?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        let exponent = min(max(delta * sensitivity, -0.5), 0.5)
        zoom(by: exp(exponent), at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if onSelectionKey?(event) == true { return }
        switch event.keyCode {
        case 123: onNavigate?(-1)
        case 124: onNavigate?(1)
        case 49:
            if isVideoVisible {
                if !event.isARepeat { onToggleVideoPlayback?() }
                return
            }
            spaceHeld = true
            window?.invalidateCursorRects(for: self)
        case 53: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if onDismissOverlay?() != true { super.cancelOperation(sender) }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { super.keyUp(with: event); return }
        spaceHeld = false
        if pan?.usesSpace == true { pan = nil }
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // 菜单跟踪可能消费空格 keyUp，进入菜单前结束拖拽，且让命令针对画布而非搜索输入框。
        cancelInteraction()
        window?.makeFirstResponder(self)
        return onContextMenu?() ?? super.menu(for: event)
    }

    /// 窗口失焦或菜单跟踪时可能收不到抬键、松鼠标事件，不能把抓取状态留给下一次交互。
    func cancelInteraction() {
        spaceHeld = false
        pan = nil
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard geometry.hasImage, spaceHeld || directPanRect.contains(point) else { return }
        pan = (point, spaceHeld)
        window?.invalidateCursorRects(for: self)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = pan?.point else { return }
        let point = convert(event.locationInWindow, from: nil)
        geometry.pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y))
        pan?.point = point
        updateImageLayer()
    }

    override func mouseUp(with event: NSEvent) {
        pan = nil
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if pan != nil {
            addCursorRect(bounds, cursor: .closedHand)
        } else {
            let grabRect = spaceHeld && geometry.hasImage ? bounds : directPanRect
            if !grabRect.isEmpty { addCursorRect(grabRect, cursor: .openHand) }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        dropBorder.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropBorder.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropBorder.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropBorder.isHidden = true
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onOpenFiles?(urls)
        window?.makeFirstResponder(self)
        return true
    }

    @objc private func openPanel() { onOpenPanel?() }
}
