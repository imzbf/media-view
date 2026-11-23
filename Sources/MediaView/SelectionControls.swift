import AppKit

/// 选片操作留在照片外侧；窄窗口增加一行，而不是缩掉文字或覆盖画面。
@MainActor
final class SelectionHeaderView: NSView {
    let filters = NSSegmentedControl(labels: SelectionFilter.allCases.map(\.title), trackingMode: .selectOne,
                                     target: nil, action: nil)
    let exportButton = NSButton(title: "导出入选", target: nil, action: nil)
    let exitButton = NSButton(title: "退出选片", target: nil, action: nil)
    let backButton = NSButton(title: "返回网格", target: nil, action: nil)
    let retryButton = NSButton(title: "重试", target: nil, action: nil)
    let progressLabel = NSTextField(labelWithString: "")
    let saveLabel = NSTextField(labelWithString: "已保存")
    private let titleLabel = NSTextField(labelWithString: "照片选片")
    var onFilter: ((SelectionFilter) -> Void)?
    var onExport: (() -> Void)?
    var onExit: (() -> Void)?
    var onBack: (() -> Void)?
    var onRetry: (() -> Void)?
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { bounds.width < 800 ? 100 : 72 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        filters.segmentDistribution = .fillEqually
        filters.target = self
        filters.action = #selector(filterChanged)
        filters.setAccessibilityLabel("按选片状态筛选")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        for label in [progressLabel, saveLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for (button, action) in [(exportButton, #selector(exportPhotos)), (exitButton, #selector(exitSelection)),
                                 (backButton, #selector(backToGrid)), (retryButton, #selector(retrySave))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportButton.imagePosition = .imageLeading
        for control in [filters, exportButton, exitButton, backButton, retryButton, progressLabel, saveLabel, titleLabel] {
            addSubview(control)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ session: SelectionSession, scanning: Bool, enabled: Bool, exporting: Bool) {
        let counts = session.counts
        for (index, filter) in SelectionFilter.allCases.enumerated() {
            filters.setLabel("\(filter.title) \(counts[filter])", forSegment: index)
        }
        filters.selectedSegment = SelectionFilter.allCases.firstIndex(of: session.filter)!
        filters.isEnabled = enabled
        exportButton.title = "导出入选 \(counts.picked)"
        exportButton.isEnabled = enabled && !scanning && !exporting && counts.picked > 0
        exitButton.isEnabled = enabled
        backButton.isHidden = session.filter != .picked || session.showsGrid
        backButton.isEnabled = enabled
        let missing = session.missingPickedCount
        progressLabel.stringValue = "已处理 \(counts.reviewed) / \(counts.all) · 入选 \(counts.picked)"
            + (missing > 0 ? " · \(missing) 张入选文件缺失" : "") + (scanning ? " · 扫描中…" : "")
        progressLabel.toolTip = progressLabel.stringValue
        retryButton.isHidden = true
        saveLabel.textColor = .secondaryLabelColor
        saveLabel.toolTip = nil
        switch session.saveState {
        case .saved: saveLabel.stringValue = "已保存"
        case .saving: saveLabel.stringValue = "保存中…"
        case .failed(let message):
            saveLabel.stringValue = "保存失败"
            saveLabel.textColor = .systemOrange
            saveLabel.toolTip = message
            retryButton.isHidden = false
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let compact = width < 800
        exitButton.frame = CGRect(x: width - 98, y: 9, width: 84, height: 28)
        exportButton.frame = CGRect(x: width - 250, y: 9, width: 144, height: 28)
        backButton.frame = CGRect(x: compact ? 14 : width - 352, y: 9, width: 94, height: 28)
        titleLabel.isHidden = !compact || !backButton.isHidden
        titleLabel.frame = CGRect(x: 18, y: 15, width: 100, height: 20)
        filters.frame = CGRect(x: 14, y: compact ? 42 : 10,
                              width: compact ? width - 28 : width - (backButton.isHidden ? 278 : 380), height: 26)
        let statusY: CGFloat = compact ? 76 : 46
        let saveWidth: CGFloat = retryButton.isHidden ? 66 : 118
        progressLabel.frame = CGRect(x: 18, y: statusY, width: max(0, width - saveWidth - 46), height: 18)
        saveLabel.frame = CGRect(x: width - saveWidth - 16, y: statusY, width: 68, height: 18)
        retryButton.frame = CGRect(x: width - 68, y: statusY - 5, width: 54, height: 26)
    }

    @objc private func filterChanged() { onFilter?(SelectionFilter.allCases[filters.selectedSegment]) }
    @objc private func exportPhotos() { onExport?() }
    @objc private func exitSelection() { onExit?() }
    @objc private func backToGrid() { onBack?() }
    @objc private func retrySave() { onRetry?() }
}

@MainActor
final class SelectionActionBar: NSView {
    let pickedButton = NSButton(title: "入选 P", target: nil, action: nil)
    let skippedButton = NSButton(title: "跳过 X", target: nil, action: nil)
    let pendingButton = NSButton(title: "恢复待选 U", target: nil, action: nil)
    let autoAdvanceButton = NSButton(checkboxWithTitle: "标记后自动下一张", target: nil, action: nil)
    let undoButton = NSButton(title: "撤销 ⌘Z", target: nil, action: nil)
    private let gridHint = NSTextField(labelWithString: "点击照片查看大图 · 移出入选后恢复为待选")
    var onMark: ((PhotoSelectionStatus) -> Void)?
    var onAutoAdvance: ((Bool) -> Void)?
    var onUndo: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        for (button, status) in [(skippedButton, PhotoSelectionStatus.skipped), (pickedButton, .picked), (pendingButton, .pending)] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(mark(_:))
            button.tag = PhotoSelectionStatus.allCases.firstIndex(of: status)!
            button.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.toolTip = status == .skipped ? "标记为跳过，保留原文件（X）" : button.title
            addSubview(button)
        }
        pickedButton.contentTintColor = .systemGreen
        autoAdvanceButton.target = self
        autoAdvanceButton.action = #selector(autoAdvanceChanged)
        autoAdvanceButton.font = .systemFont(ofSize: 11)
        autoAdvanceButton.toolTip = "关闭后停留查看；若标记后不再符合当前筛选条件，照片仍会移出列表。"
        undoButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undo)
        gridHint.font = .systemFont(ofSize: 12)
        gridHint.textColor = .secondaryLabelColor
        gridHint.alignment = .center
        for control in [autoAdvanceButton, undoButton, gridHint] { addSubview(control) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ session: SelectionSession, canMark: Bool, hasImage: Bool, enabled: Bool) {
        let status = session.currentURL.map { session.status(of: $0) }
        pickedButton.title = status == .picked ? "已入选 P" : "入选 P"
        skippedButton.title = status == .skipped ? "已跳过 X" : "跳过 X"
        pickedButton.isEnabled = canMark && hasImage && status != .picked
        skippedButton.isEnabled = canMark && status != .skipped
        pendingButton.isEnabled = canMark && status != .pending
        for button in [pickedButton, skippedButton, pendingButton] { button.isHidden = session.showsGrid }
        autoAdvanceButton.isHidden = session.showsGrid
        autoAdvanceButton.state = session.autoAdvance ? .on : .off
        autoAdvanceButton.isEnabled = enabled
        undoButton.isEnabled = enabled && session.undoManager.canUndo
        gridHint.isHidden = !session.showsGrid
    }

    override func layout() {
        super.layout()
        let width = min(420, bounds.width - 24)
        let itemWidth = (width - 16) / 3
        let left = (bounds.width - width) / 2
        for (index, button) in [skippedButton, pickedButton, pendingButton].enumerated() {
            button.frame = CGRect(x: left + CGFloat(index) * (itemWidth + 8), y: 7, width: itemWidth, height: 30)
        }
        autoAdvanceButton.frame = CGRect(x: 16, y: 43, width: 230, height: 20)
        undoButton.frame = CGRect(x: bounds.width - 108, y: 39, width: 92, height: 28)
        gridHint.frame = CGRect(x: 14, y: 13, width: bounds.width - 28, height: 20)
    }

    @objc private func mark(_ sender: NSButton) { onMark?(PhotoSelectionStatus.allCases[sender.tag]) }
    @objc private func autoAdvanceChanged() { onAutoAdvance?(autoAdvanceButton.state == .on) }
    @objc private func undo() { onUndo?() }
}

@MainActor
final class SelectionEmptyView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    let reviewButton = NSButton(title: "查看入选", target: nil, action: nil)
    let exportButton = NSButton(title: "导出原图", target: nil, action: nil)
    var onReview: (() -> Void)?
    var onExport: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        reviewButton.target = self
        reviewButton.action = #selector(review)
        exportButton.target = self
        exportButton.action = #selector(exportPhotos)
        for button in [reviewButton, exportButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [reviewButton, exportButton])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, detail, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ session: SelectionSession, scanning: Bool) {
        let counts = session.counts
        if scanning {
            title.stringValue = "正在整理照片…"
            detail.stringValue = "选片范围包含此文件夹及其子目录。"
        } else if session.filter == .pending && counts.all > 0 {
            title.stringValue = "本轮筛选完成"
            detail.stringValue = "共入选 \(counts.picked) 张照片，可以集中复核或导出原图。"
        } else {
            title.stringValue = session.filter == .picked ? "还没有入选照片" : "这里还没有照片"
            detail.stringValue = session.filter == .picked ? "在待选中把喜欢的照片标记为入选，再来集中复核。"
                : "可切换其他筛选条件。选片模式仅包含图片。"
        }
        reviewButton.isHidden = counts.picked == 0 || session.filter == .picked
        exportButton.isHidden = counts.picked == 0
        exportButton.isEnabled = !scanning
    }

    @objc private func review() { onReview?() }
    @objc private func exportPhotos() { onExport?() }
}

/// 导出使用窗口内的进度面板；取消只停止后续文件，完成后仍可找到已经复制的照片。
@MainActor
final class SelectionExportPanel: NSWindowController {
    private let message = NSTextField(wrappingLabelWithString: "准备导出…")
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let detailScroll = NSScrollView()
    private let cancelButton = NSButton(title: "取消导出", target: nil, action: nil)
    private let finderButton = NSButton(title: "在 Finder 中查看", target: nil, action: nil)
    var onCancel: (() -> Void)?
    private var outputDirectory: URL?
    private var finished = false

    init(total: Int) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "导出入选原图"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        message.frame = CGRect(x: 24, y: 230, width: 452, height: 45)
        message.font = .systemFont(ofSize: 14, weight: .medium)
        progress.frame = CGRect(x: 24, y: 207, width: 452, height: 14)
        progress.isIndeterminate = false
        progress.maxValue = Double(total)
        details.isEditable = false
        details.drawsBackground = false
        details.font = .systemFont(ofSize: 12)
        details.textColor = .secondaryLabelColor
        details.isVerticallyResizable = true
        details.textContainer?.widthTracksTextView = true
        detailScroll.frame = CGRect(x: 24, y: 64, width: 452, height: 128)
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.documentView = details
        details.frame = detailScroll.bounds
        details.string = "复制原文件，保留格式和元数据。取消会保留已经完成的副本。"
        cancelButton.frame = CGRect(x: 376, y: 16, width: 100, height: 32)
        finderButton.frame = CGRect(x: 200, y: 16, width: 168, height: 32)
        cancelButton.bezelStyle = .rounded
        finderButton.bezelStyle = .rounded
        finderButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelOrClose)
        finderButton.target = self
        finderButton.action = #selector(reveal)
        for view in [message, progress, detailScroll, cancelButton, finderButton] { content.addSubview(view) }
        update(completed: 0, total: total)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(completed: Int, total: Int) {
        progress.doubleValue = Double(completed)
        message.stringValue = "正在导出 \(completed) / \(total) 张…"
    }

    func complete(_ result: SelectionExportResult) {
        outputDirectory = result.directory
        message.stringValue = "\(result.cancelled ? "已取消" : "导出完成")：成功 \(result.copied.count) 张，失败 \(result.failures.count) 张"
        details.string = result.failures.isEmpty ? "照片已保存到：\n\(result.directory.path)"
            : result.failures.map { "\($0.source.path)\n\($0.message)" }.joined(separator: "\n\n")
        finderButton.isHidden = false
        finish()
    }

    func fail(_ error: Error) {
        message.stringValue = error is CancellationError ? "已取消导出" : "无法导出照片"
        details.string = error is CancellationError ? "选片记录已保留，可稍后重新导出。" : error.localizedDescription
        finish()
    }

    private func finish() { finished = true; cancelButton.title = "完成"; cancelButton.isEnabled = true }

    @objc private func cancelOrClose() {
        if finished {
            if let window { window.sheetParent?.endSheet(window) }
            close()
        } else {
            cancelButton.isEnabled = false
            cancelButton.title = "取消中…"
            onCancel?()
        }
    }

    @objc private func reveal() {
        if let outputDirectory { NSWorkspace.shared.activateFileViewerSelecting([outputDirectory]) }
    }
}
