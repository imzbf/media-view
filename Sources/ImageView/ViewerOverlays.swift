import AppKit

/// 搜索条只负责文本输入；查询和导航由控制器统一管理，避免输入框截走画布的状态。
@MainActor
final class ImageSearchBar: ViewerOverlayView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let previousMatchButton = ViewerIconButton(symbol: "chevron.up", label: "上一个匹配")
    let nextMatchButton = ViewerIconButton(symbol: "chevron.down", label: "下一个匹配")
    private let countLabel = NSTextField(labelWithString: "")
    var onQueryChanged: ((String) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var status: String { countLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchField.placeholderString = "按文件名查找"
        searchField.toolTip = "输入后按回车定位下一项，Shift + 回车定位上一项"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("查找图片文件名")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        previousMatchButton.target = self
        previousMatchButton.action = #selector(previousMatch)
        previousMatchButton.toolTip = "上一个匹配（⇧↩）"
        nextMatchButton.target = self
        nextMatchButton.action = #selector(nextMatch)
        nextMatchButton.toolTip = "下一个匹配（↩）"
        let close = ViewerIconButton(symbol: "xmark", label: "关闭查找")
        close.target = self
        close.action = #selector(closeSearch)
        close.toolTip = "关闭查找（Esc）"
        for child in [searchField, countLabel, previousMatchButton, nextMatchButton, close] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            child.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            previousMatchButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 6),
            previousMatchButton.widthAnchor.constraint(equalToConstant: 28),
            previousMatchButton.heightAnchor.constraint(equalToConstant: 28),
            nextMatchButton.leadingAnchor.constraint(equalTo: previousMatchButton.trailingAnchor, constant: 2),
            nextMatchButton.widthAnchor.constraint(equalToConstant: 28),
            nextMatchButton.heightAnchor.constraint(equalToConstant: 28),
            close.leadingAnchor.constraint(equalTo: nextMatchButton.trailingAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
        ])
        setStatus("输入文件名")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setStatus(_ text: String, canNavigate: Bool = false, isFailure: Bool = false) {
        countLabel.stringValue = text
        countLabel.textColor = isFailure ? .systemOrange : .secondaryLabelColor
        previousMatchButton.isEnabled = canNavigate
        nextMatchButton.isEnabled = canNavigate
    }

    func controlTextDidChange(_ notification: Notification) {
        // 中文输入的候选文字不是已提交的查询，回车必须先交给输入法确认候选。
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onNavigate?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }

    @objc private func closeSearch() { onClose?() }
    @objc private func previousMatch() { navigate(by: -1) }
    @objc private func nextMatch() { navigate(by: 1) }

    private func navigate(by direction: Int) {
        onNavigate?(direction)
        // 点击按钮后继续留在查询框，用户可以立即改词或用回车继续定位。
        window?.makeFirstResponder(searchField)
    }
}

/// 按需出现的只读卡片；小窗口内由原生滚动视图承载长 EXIF，画布尺寸保持不变。
@MainActor
final class ImageInfoCard: ViewerOverlayView, NSTextViewDelegate {
    private let textView = NSTextView()
    private(set) var metadata: ImageMetadata?
    var onClose: (() -> Void)?
    var text: String { textView.string }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "图片信息")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let close = ViewerIconButton(symbol: "xmark", label: "关闭图片信息")
        close.target = self
        close.action = #selector(closeInfo)
        close.toolTip = "关闭图片信息（⌘I / Esc）"
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 12, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("图片元数据")
        scrollView.documentView = textView
        for child in [title, close, scrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ metadata: ImageMetadata) {
        self.metadata = metadata
        let text = NSMutableAttributedString()
        for field in metadata.fields {
            text.append(NSAttributedString(string: "\(field.name)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor,
            ]))
            text.append(NSAttributedString(string: "\(field.value)\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            ]))
        }
        textView.textStorage?.setAttributedString(text)
        textView.scrollToBeginningOfDocument(nil)
    }

    func showStatus(_ message: String) {
        metadata = nil
        textView.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        textView.scrollToBeginningOfDocument(nil)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onClose?()
        return true
    }

    @objc private func closeInfo() { onClose?() }
}
