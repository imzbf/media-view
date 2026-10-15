import AppKit
import QuartzCore

/// 画布只管理显示与手势；文件读取和解码由控制器交给后台任务。
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

    private(set) var geometry = CanvasGeometry()
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
    private var dragPoint: CGPoint?
    private var previousDisplaySize = CGSize.zero
    private var previousBackingScale: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

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
        NSLayoutConstraint.activate([
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
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
        showStatus(title: "拖入图片或文件夹", detail: "使用 ← → 浏览 · 滚动缩放 · 按住空格拖拽",
                   symbol: "photo.on.rectangle.angled", showOpenButton: true)
    }

    func showStatus(title: String, detail: String, symbol: String = "photo",
                    showOpenButton: Bool = false)
    {
        // 清空也要关闭隐式动画；淡出会保留旧位图，快切到大图时便会按新 bounds 短暂放大。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        geometry.setImage(size: .zero)
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

    /// 等待解码时只暂留画面；是否保留新图的视角仍由控制器在 display 时决定。
    func prepareForLoading() {
        if !geometry.hasImage {
            showStatus(title: "正在载入…", detail: "", symbol: "photo")
        }
        notice.isHidden = true
        noticeBackground.isHidden = true
        setLoadingIndicatorVisible(false)
    }

    /// 控制器延迟确认请求仍有效后才显示转圈，缓存命中不应产生一闪而过的提示。
    func setLoadingIndicatorVisible(_ visible: Bool) {
        if visible { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !visible
    }

    func display(_ decoded: DecodedImage, filename: String, resetTransform: Bool) {
        // 内容和几何一同提交，暂留的旧位图不会套用新图尺寸，也不会触发隐式淡入。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
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
        // 长错误最多显示两行；悬停可读完整原因，避免提示撑大窗口或压住缩略条。
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
        geometry.resize(to: bounds.size, backingScale: backingScale)
        updateImageLayer()
        dropBorder.frame = bounds
        dropBorder.path = CGPath(roundedRect: bounds.insetBy(dx: 7, dy: 7),
                                 cornerWidth: 8, cornerHeight: 8, transform: nil)
        if previousDisplaySize != bounds.size || previousBackingScale != backingScale {
            previousDisplaySize = bounds.size
            previousBackingScale = backingScale
            onDisplayChanged?()
        }
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
        switch event.keyCode {
        case 123: onNavigate?(-1)
        case 124: onNavigate?(1)
        case 49:
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
        if event.keyCode == 49 { cancelInteraction() } else { super.keyUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // 菜单跟踪可能消费空格 keyUp，进入菜单前结束拖拽，且让命令针对画布而非搜索输入框。
        cancelInteraction()
        window?.makeFirstResponder(self)
        return onContextMenu?() ?? super.menu(for: event)
    }

    /// 窗口失焦可能收不到空格的 keyUp，主动清除状态以免重新激活后卡在拖拽模式。
    func cancelInteraction() {
        spaceHeld = false
        dragPoint = nil
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard spaceHeld, geometry.hasImage else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard spaceHeld, let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        geometry.pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y))
        dragPoint = point
        updateImageLayer()
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spaceHeld ? (dragPoint == nil ? .openHand : .closedHand) : .arrow)
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
