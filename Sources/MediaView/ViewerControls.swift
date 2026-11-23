import AppKit

/// 在窗口内部采样图片，浮层随内容模糊；减少透明度由系统材质自动适配。
@MainActor
class ViewerOverlayView: NSVisualEffectView {
    private let contrastView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 文字浮层使用较实的原生弹层材质，亮图下也保持对比。
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // 纯白图片会把系统材质提亮，额外的暗色衬底为文字保留对比，同时继续透出模糊内容。
        contrastView.frame = bounds
        contrastView.autoresizingMask = [.width, .height]
        contrastView.wantsLayer = true
        contrastView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        addSubview(contrastView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === contrastView ? self : hit
    }
}

/// 保留 NSButton 的点击、键盘与辅助功能语义，只补充无边框图标的悬停和按压反馈。
@MainActor
final class ViewerIconButton: NSButton {
    enum Style { case standard, navigation }

    let style: Style
    fileprivate var isHovered = false
    var cornerRadius: CGFloat = 6
    var onScroll: ((NSEvent) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    init(symbol: String, label: String, style: Style = .standard) {
        self.style = style
        super.init(frame: .zero)
        let buttonCell = ViewerIconButtonCell()
        cell = buttonCell
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style == .navigation ? 18 : 13,
                                                           weight: style == .navigation ? .regular : .semibold)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = style == .navigation ? .white : .labelColor
        if style == .navigation {
            // 导航自行处理按压和禁用透明度，避免原生 cell 再次压暗箭头。
            buttonCell.highlightsBy = []
            buttonCell.imageDimsWhenDisabled = false
        }
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var alignmentRectInsets: NSEdgeInsets {
        // 淡显箭头仍保留完整的 44 pt 点击区域，避免原生对齐边距改变尺寸和边缘距离。
        style == .navigation ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScroll { onScroll(event) } else { super.scrollWheel(with: event) }
    }
}

@MainActor
private final class ViewerIconButtonCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let button = controlView as? ViewerIconButton {
            // 使用原生 cell 的跟踪状态，拖出取消、键盘激活和 performClick 都有一致的反馈。
            if button.style == .navigation, let context = NSGraphicsContext.current?.cgContext {
                if button.isEnabled && (button.isHovered || isHighlighted) {
                    NSColor.black.withAlphaComponent(isHighlighted ? 0.42 : 0.28).setFill()
                    let background = NSRect(x: cellFrame.midX - 18, y: cellFrame.midY - 18, width: 36, height: 36)
                    NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
                }
                let opacity: CGFloat = button.isEnabled ? ((isHighlighted || button.isHovered) ? 1 : 0.6) : 0.2
                // 平时只绘制细箭头；轻微暗色阴影保证亮图上的轮廓，背景只在交互时出现。
                context.saveGState()
                context.setAlpha(opacity)
                context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2,
                                  color: NSColor.black.withAlphaComponent(0.65).cgColor)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                super.draw(withFrame: cellFrame, in: controlView)
                context.endTransparencyLayer()
                context.restoreGState()
                return
            }
            let opacity: CGFloat = button.isEnabled ? (isHighlighted ? 0.26 : (button.isHovered ? 0.12 : 0)) : 0
            NSColor.white.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: button.cornerRadius, yRadius: button.cornerRadius).fill()
        }
        super.draw(withFrame: cellFrame, in: controlView)
    }
}
