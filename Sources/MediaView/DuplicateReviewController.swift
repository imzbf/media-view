import AppKit

/// 同一工作区内完成分组、预览和清理；小窗口改为列表/详情/预览逐级返回，保留操作文字。
@MainActor
final class DuplicateReviewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let session: DuplicateSession
    let preview = DuplicatePreviewController()
    let groupTable = DuplicateTableView()
    let fileTable = DuplicateTableView()
    let filters = NSSegmentedControl(labels: DuplicateFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let scanButton = NSButton(title: "重新检查", target: nil, action: nil)
    let exitButton = NSButton(title: "返回浏览", target: nil, action: nil)
    let cleanupButton = NSButton(title: "移到废纸篓…", target: nil, action: nil)
    let backButton = NSButton(title: "‹ 重复组", target: nil, action: nil)
    let previewButton = NSButton(title: "预览", target: nil, action: nil)
    let keepButton = NSButton(title: "保留这份，勾选其余", target: nil, action: nil)
    let removalButton = NSButton(checkboxWithTitle: "待清理", target: nil, action: nil)
    var onExit: (() -> Void)?
    private let pickedPaths: Set<String>
    private let titleLabel = NSTextField(labelWithString: "重复检查")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveLabel = NSTextField(labelWithString: "已保存")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    private let groupLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let groupScroll = NSScrollView()
    private let fileScroll = NSScrollView()
    private let ignoreButton = NSButton(title: "忽略这组", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试保存", target: nil, action: nil)
    private let issuesButton = NSButton(title: "查看问题", target: nil, action: nil)
    private let revealButton = NSButton(title: "在 Finder 中查看", target: nil, action: nil)
    private var displayedGroups: [DuplicateGroup] = []
    private var displayedFiles: [DuplicateFile] = []
    private var updating = false
    private var showsDetail = false
    private var showsPreview = false
    private var windowVisible = true
    private var compact: Bool { view.bounds.width < 860 || view.bounds.height < 500 }

    init(session: DuplicateSession, pickedPaths: Set<String> = []) {
        self.session = session
        self.pickedPaths = pickedPaths
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let content = DuplicateWorkspaceView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        view = content
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.setAccessibilityLabel("照片与视频重复检查")
        for label in [statusLabel, saveLabel, summaryLabel, resultLabel, groupLabel] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
        }
        statusLabel.textColor = .secondaryLabelColor
        saveLabel.textColor = .secondaryLabelColor
        resultLabel.textColor = .secondaryLabelColor
        groupLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        filters.segmentDistribution = .fillEqually
        filters.target = self
        filters.action = #selector(changeFilter)
        filters.setAccessibilityLabel("重复组分类")
        progressBar.style = .bar
        for (button, action) in [
            (scanButton, #selector(scanOrCancel)), (exitButton, #selector(exitReview)),
            (cleanupButton, #selector(confirmCleanup)), (ignoreButton, #selector(ignoreGroup)),
            (retryButton, #selector(retrySave)), (issuesButton, #selector(showIssues)),
            (backButton, #selector(goBack)), (previewButton, #selector(showPreview)),
            (keepButton, #selector(keepSelected)), (removalButton, #selector(toggleRemoval)),
            (revealButton, #selector(revealSelected)),
        ] {
            if button !== removalButton { button.bezelStyle = .rounded }
            button.target = self
            button.action = action
        }
        keepButton.toolTip = "明确选择保留当前版本，把本组其他副本加入待清理列表。"
        cleanupButton.hasDestructiveAction = true
        for (table, scroll, height, label) in [
            (groupTable, groupScroll, CGFloat(62), "重复分组"),
            (fileTable, fileScroll, CGFloat(86), "此组各个版本"),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(label))
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = height
            table.intercellSpacing = CGSize(width: 0, height: 4)
            table.style = .plain
            table.usesAlternatingRowBackgroundColors = false
            table.backgroundColor = .clear
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.allowsEmptySelection = true
            table.setAccessibilityLabel(label)
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
        }
        fileTable.target = self
        fileTable.doubleAction = #selector(showPreview)
        fileTable.onReturn = { [weak self] in self?.showPreview() }
        groupTable.onReturn = { [weak self] in self?.showsDetail = true; self?.layoutContent() }
        groupTable.onActivate = groupTable.onReturn
        addChild(preview)
        for child in [titleLabel, statusLabel, saveLabel, filters, progressBar, scanButton, exitButton,
                      summaryLabel, resultLabel, cleanupButton, retryButton, issuesButton,
                      groupScroll, fileScroll, preview.view, groupLabel, backButton, ignoreButton,
                      previewButton, keepButton, removalButton, revealButton, emptyLabel] { view.addSubview(child) }
        preview.canvas.onNavigate = { [weak self] delta in self?.navigateVersion(delta) }
        preview.canvas.onDismissOverlay = { [weak self] in
            guard let self, self.compact else { return false }
            self.goBack()
            return true
        }
        session.onChange = { [weak self] in self?.render() }
        content.onLayout = { [weak self] in self?.layoutContent() }
        render()
    }

    func render() {
        guard isViewLoaded else { return }
        updating = true
        defer { updating = false }
        let groups = session.visibleGroups
        if displayedGroups != groups {
            displayedGroups = groups
            groupTable.reloadData()
        }
        let files = session.selectedGroup?.files ?? []
        if displayedFiles != files {
            displayedFiles = files
            fileTable.reloadData()
        }
        let groupRow = groups.firstIndex { $0.id == session.record.groupID }
        groupTable.selectRowIndexes(groupRow.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        let fileRow = files.firstIndex { $0.path == session.record.path }
        fileTable.selectRowIndexes(fileRow.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        let visibleRows = fileTable.rows(in: fileTable.visibleRect)
        if visibleRows.location != NSNotFound {
            for row in visibleRows.location..<min(fileTable.numberOfRows, visibleRows.location + visibleRows.length) {
                guard let cell = fileTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? DuplicateFileCell else { continue }
                updateDecision(cell, file: files[row])
            }
        }
        filters.selectedSegment = DuplicateFilter.allCases.firstIndex(of: session.record.filter)!
        filters.isEnabled = !session.isBusy
        statusLabel.stringValue = session.progress.text
        statusLabel.toolTip = statusLabel.stringValue + "\n" + session.root.path
        scanButton.title = session.isScanning ? "取消检查" : (session.isCleaning ? "取消清理" : "重新检查")
        scanButton.isEnabled = !session.isDeparting
        exitButton.isEnabled = !session.isDeparting
        retryButton.isHidden = true
        saveLabel.textColor = .secondaryLabelColor
        switch session.saveState {
        case .saved: saveLabel.stringValue = "进度已保存"
        case .saving: saveLabel.stringValue = "保存中…"
        case .failed(let message):
            saveLabel.stringValue = "保存失败"
            saveLabel.textColor = .systemOrange
            saveLabel.toolTip = message
            retryButton.isHidden = false
        }
        retryButton.isEnabled = !session.isDeparting
        progressBar.isHidden = !session.isScanning && !session.isCleaning
        progressBar.isIndeterminate = session.progress.total == 0
        if progressBar.isIndeterminate { progressBar.startAnimation(nil) }
        else { progressBar.stopAnimation(nil); progressBar.maxValue = Double(session.progress.total); progressBar.doubleValue = Double(session.progress.completed) }
        let pending = session.pendingFiles
        let bytes = pending.reduce(Int64(0)) { $0 + $1.stamp.size }
        summaryLabel.stringValue = pending.isEmpty ? "先核对版本，再勾选需要清理的副本" : "待清理 \(pending.count) 项 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        summaryLabel.toolTip = summaryLabel.stringValue
        cleanupButton.isEnabled = session.canClean
        if let result = session.lastCleanup {
            resultLabel.stringValue = "\(result.cancelled ? "清理已取消" : "上次清理") · 成功 \(result.removed.count) 项 · 未完成 \(result.issues.count) 项"
        } else { resultLabel.stringValue = "所有检查在本机完成 · 勾选不会立即移动文件" }
        issuesButton.isHidden = session.issues.isEmpty && (session.lastCleanup?.issues.isEmpty ?? true)
        if let group = session.selectedGroup {
            groupLabel.stringValue = "\(group.match.title) · \(group.files.count) 个版本"
            groupLabel.toolTip = group.match == .similar ? "画面相近，请核对细节；视频需播放核对声音。" : "完整文件内容一致。"
            let ignored = session.record.decisions[group.id]?.ignored == true
            ignoreButton.title = ignored ? "恢复这组" : "忽略这组"
            ignoreButton.isEnabled = session.canReview
            keepButton.isEnabled = session.canReview && !ignored && session.selectedFile != nil
            removalButton.isEnabled = keepButton.isEnabled
            removalButton.state = session.record.path.map { session.record.decisions[group.id]?.removals.contains($0) == true } == true ? .on : .off
        }
        previewButton.isEnabled = session.selectedFile != nil && !session.isCleaning
        revealButton.isEnabled = session.selectedFile != nil
        preview.show(session.isCleaning ? nil : session.selectedFile?.url(in: session.root))
        emptyLabel.stringValue = session.isScanning ? "正在检查照片和视频…\n完成后可分组核对并清理。"
            : (!session.hasCompleted ? "检查尚未完成\n点击“重新检查”继续，已有复核进度会保留。"
                : (session.groups.isEmpty ? "没有发现重复照片或视频" : "这个分类中没有重复组"))
        layoutContent()
    }

    private func updateDecision(_ cell: DuplicateFileCell, file: DuplicateFile) {
        let decision = session.record.groupID.flatMap { session.record.decisions[$0] }
        cell.removal.state = decision?.removals.contains(file.path) == true ? .on : .off
        cell.removal.isEnabled = session.canReview && decision?.ignored != true
        cell.keep.isEnabled = cell.removal.isEnabled
    }

    private func layoutContent() {
        guard isViewLoaded else { return }
        let w = view.bounds.width, h = view.bounds.height
        titleLabel.frame = CGRect(x: 16, y: 11, width: max(0, w - 244), height: 24)
        scanButton.frame = CGRect(x: w - 226, y: 8, width: 108, height: 30)
        exitButton.frame = CGRect(x: w - 112, y: 8, width: 98, height: 30)
        statusLabel.frame = CGRect(x: 16, y: 40, width: max(0, w - 170), height: 17)
        saveLabel.frame = CGRect(x: w - 146, y: 40, width: 132, height: 17)
        retryButton.frame = CGRect(x: w - 94, y: 34, width: 82, height: 27)
        if !retryButton.isHidden { saveLabel.frame.size.width = 58; saveLabel.frame.origin.x = w - 154 }
        progressBar.frame = CGRect(x: 16, y: 59, width: w - 32, height: 3)
        filters.frame = CGRect(x: 14, y: 64, width: w - 28, height: 25)
        summaryLabel.frame = CGRect(x: 16, y: h - 61, width: max(0, w - 190), height: 18)
        cleanupButton.frame = CGRect(x: w - 174, y: h - 67, width: 160, height: 30)
        resultLabel.frame = CGRect(x: 16, y: h - 29, width: max(0, w - 140), height: 18)
        issuesButton.frame = CGRect(x: w - 124, y: h - 36, width: 110, height: 30)
        let body = CGRect(x: 12, y: 92, width: w - 24, height: max(0, h - 162))
        let hasGroup = session.selectedGroup != nil && !displayedGroups.isEmpty
        let detailVisible = hasGroup && (!compact || showsDetail)
        groupScroll.isHidden = displayedGroups.isEmpty || (compact && detailVisible)
        groupScroll.frame = CGRect(x: body.minX, y: body.minY, width: compact ? body.width : 236, height: body.height)
        let detail = compact ? body : CGRect(x: 262, y: body.minY, width: w - 274, height: body.height)
        for child in [groupLabel, ignoreButton, previewButton, keepButton, removalButton, revealButton] { child.isHidden = !detailVisible }
        backButton.isHidden = !compact || !detailVisible
        backButton.title = showsPreview ? "‹ 各个版本" : "‹ 重复组"
        backButton.frame = CGRect(x: detail.minX, y: detail.minY, width: 94, height: 28)
        let labelX = detail.minX + (compact ? 100 : 2)
        groupLabel.frame = CGRect(x: labelX, y: detail.minY + 5, width: max(0, detail.maxX - labelX - 152), height: 18)
        previewButton.frame = CGRect(x: detail.maxX - 154, y: detail.minY, width: 58, height: 28)
        ignoreButton.frame = CGRect(x: detail.maxX - 94, y: detail.minY, width: 94, height: 28)
        let controlsY = detail.maxY - 30
        keepButton.frame = CGRect(x: detail.minX, y: controlsY, width: 166, height: 28)
        removalButton.frame = CGRect(x: detail.minX + 173, y: controlsY + 4, width: 84, height: 20)
        revealButton.frame = CGRect(x: detail.maxX - 136, y: controlsY, width: 136, height: 28)
        // 极窄窗口把 Finder 操作收起，路径仍可在每个版本的提示和确认清单中完整查看。
        revealButton.isHidden = !detailVisible || detail.width < 450
        let content = CGRect(x: detail.minX, y: detail.minY + 33, width: detail.width, height: max(0, detail.height - 65))
        fileScroll.isHidden = !detailVisible || (compact && showsPreview)
        preview.view.isHidden = !detailVisible || (compact && !showsPreview)
        if compact {
            fileScroll.frame = content
            preview.view.frame = content
        } else {
            let tableHeight = min(max(90, CGFloat(displayedFiles.count) * 90), max(90, content.height * 0.45))
            fileScroll.frame = CGRect(x: content.minX, y: content.maxY - tableHeight, width: content.width, height: tableHeight)
            preview.view.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, content.height - tableHeight - 8))
        }
        emptyLabel.isHidden = !displayedGroups.isEmpty
        emptyLabel.frame = CGRect(x: body.minX + 18, y: body.midY - 35, width: max(0, body.width - 36), height: 70)
        preview.setVisible(windowVisible && !preview.view.isHidden && !session.isCleaning)
    }

    func setVisible(_ visible: Bool) { windowVisible = visible; if isViewLoaded { layoutContent() } }
    func stop() { session.cancelActivity(); preview.stop() }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === groupTable ? displayedGroups.count : displayedFiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupTable {
            guard displayedGroups.indices.contains(row) else { return nil }
            let group = displayedGroups[row]
            let cell = NSTableCellView()
            let label = NSTextField(wrappingLabelWithString: "\(group.match.title) · \(group.files.count) 个版本\n\(group.files.first?.name ?? "")")
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = CGRect(x: 10, y: 7, width: max(0, tableView.bounds.width - 24), height: 44)
            label.autoresizingMask = [.width]
            cell.addSubview(label)
            cell.textField = label
            cell.setAccessibilityLabel(label.stringValue)
            return cell
        }
        guard displayedFiles.indices.contains(row) else { return nil }
        let file = displayedFiles[row]
        let cell = DuplicateFileCell()
        cell.configure(file, root: session.root, picked: pickedPaths.contains(file.path), decoder: preview.decoder)
        cell.onRemove = { [weak self, weak cell] checked in
            guard let self else { return }
            self.session.selectFile(file.path)
            if !self.session.setRemoval(file.path, selected: checked) {
                cell?.removal.state = .off
                self.resultLabel.stringValue = "每组至少保留一个文件"
            }
        }
        cell.onKeep = { [weak self] in self?.session.selectFile(file.path); self?.session.keepOnly(file.path) }
        updateDecision(cell, file: file)
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView.view(atColumn: 0) as? DuplicateFileCell)?.cancelThumbnail()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let table = notification.object as? NSTableView else { return }
        if table === groupTable, displayedGroups.indices.contains(table.selectedRow) {
            showsDetail = true
            showsPreview = false
            session.selectGroup(displayedGroups[table.selectedRow].id)
            layoutContent()
        } else if table === fileTable, displayedFiles.indices.contains(table.selectedRow) {
            session.selectFile(displayedFiles[table.selectedRow].path)
        }
    }

    private func navigateVersion(_ delta: Int) {
        guard let current = displayedFiles.firstIndex(where: { $0.path == session.record.path }),
              displayedFiles.indices.contains(current + delta) else { return }
        session.selectFile(displayedFiles[current + delta].path)
    }

    @objc private func scanOrCancel() {
        if session.isScanning || session.isCleaning { session.cancelActivity() } else { session.startScan() }
    }
    @objc private func exitReview() { onExit?() }
    @objc private func changeFilter() { session.setFilter(DuplicateFilter.allCases[filters.selectedSegment]) }
    @objc private func ignoreGroup() { session.toggleIgnored() }
    @objc private func retrySave() { session.retrySave() }
    @objc private func keepSelected() { if let path = session.record.path { session.keepOnly(path) } }
    @objc private func toggleRemoval() {
        if let path = session.record.path, !session.setRemoval(path, selected: removalButton.state == .on) {
            removalButton.state = .off
            resultLabel.stringValue = "每组至少保留一个文件"
        }
    }
    @objc private func goBack() {
        if showsPreview { showsPreview = false } else { showsDetail = false }
        layoutContent()
    }
    @objc private func showPreview() {
        guard session.selectedFile != nil else { return }
        showsDetail = true
        showsPreview = true
        layoutContent()
        view.window?.makeFirstResponder(preview.canvas)
    }
    @objc private func revealSelected() {
        if let file = session.selectedFile { NSWorkspace.shared.activateFileViewerSelecting([file.url(in: session.root)]) }
    }

    @objc private func confirmCleanup() {
        guard session.canClean, let window = view.window, window.attachedSheet == nil else { return }
        let files = session.pendingFiles
        let identities = Set(files.map(\.identity))
        let picked = files.filter { pickedPaths.contains($0.path) }.count
        let alert = NSAlert()
        alert.messageText = "将 \(files.count) 个副本移到废纸篓？"
        alert.informativeText = "请核对下面的清单。每组保留的文件不会移动，已移动的文件可以在废纸篓中找回。"
            + (picked > 0 ? "\n其中 \(picked) 项已在选片中入选；清理后该选片记录会提示文件缺失。" : "")
        alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.accessoryView = detailsView(files.map { "\($0.path)\n\($0.detail)" }.joined(separator: "\n\n"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  Set(self.session.pendingFiles.map(\.identity)) == identities else { return }
            self.preview.stop()
            self.session.clean()
        }
    }

    @objc private func showIssues() {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let issues = session.issues + (session.lastCleanup?.issues ?? [])
        let alert = NSAlert()
        alert.messageText = "检查与清理中遇到的问题"
        alert.informativeText = "无法读取或发生变化的文件不会作为已确认的清理结果处理。"
        alert.addButton(withTitle: "关闭")
        alert.accessoryView = detailsView(issues.map { "\($0.path)\n\($0.message)" }.joined(separator: "\n\n"))
        alert.beginSheetModal(for: window)
    }

    private func detailsView(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 180))
        let field = NSTextView(frame: scroll.bounds)
        field.isEditable = false
        field.font = .systemFont(ofSize: 12)
        field.isVerticallyResizable = true
        field.textContainer?.widthTracksTextView = true
        field.string = text
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        return scroll
    }
}

@MainActor
private final class DuplicateWorkspaceView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
final class DuplicateTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRow >= 0 { onActivate?() }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode), !event.isARepeat,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class DuplicateFileCell: NSTableCellView {
    let removal = NSButton(checkboxWithTitle: "待清理", target: nil, action: nil)
    let keep = NSButton(title: "保留此版本", target: nil, action: nil)
    var onRemove: ((Bool) -> Void)?
    var onKeep: (() -> Void)?
    private let thumbnail = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var path: String?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12, weight: .medium)
        for label in [name, detail, location] { label.lineBreakMode = .byTruncatingMiddle }
        for label in [detail, location] { label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor }
        keep.bezelStyle = .rounded
        keep.controlSize = .small
        keep.font = .systemFont(ofSize: 11)
        keep.target = self
        keep.action = #selector(keepFile)
        removal.font = .systemFont(ofSize: 11)
        removal.target = self
        removal.action = #selector(removeFile)
        for child in [thumbnail, name, detail, location, removal, keep] { addSubview(child) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }

    override func layout() {
        super.layout()
        let w = bounds.width
        thumbnail.frame = CGRect(x: 6, y: 8, width: 62, height: 64)
        name.frame = CGRect(x: 78, y: 9, width: max(0, w - 182), height: 18)
        detail.frame = CGRect(x: 78, y: 31, width: max(0, w - 184), height: 16)
        location.frame = CGRect(x: 78, y: 53, width: max(0, w - 184), height: 18)
        removal.frame = CGRect(x: w - 94, y: 8, width: 86, height: 22)
        keep.frame = CGRect(x: w - 104, y: 46, width: 100, height: 28)
    }

    func configure(_ file: DuplicateFile, root: URL, picked: Bool, decoder: ImageDecoder) {
        cancelThumbnail()
        path = file.path
        name.stringValue = file.name
        detail.stringValue = file.detail
        location.stringValue = (picked ? "✓ 已入选 · " : "") + file.path
        toolTip = file.url(in: root).path + "\n" + file.detail + (picked ? "\n已在选片中入选" : "")
        removal.setAccessibilityLabel("待清理：\(file.path)")
        keep.setAccessibilityLabel("保留 \(file.path)，勾选本组其他副本")
        thumbnail.image = NSImage(systemSymbolName: file.kind == .video ? "film" : "photo", accessibilityDescription: nil)
        task = Task { [weak self] in
            do {
                let result = try await decoder.thumbnail(file.url(in: root), maxPixelDimension: 144)
                try Task.checkCancellation()
                guard let self, self.path == file.path else { return }
                self.thumbnail.image = NSImage(cgImage: result.image, size: .zero)
            } catch {}
        }
    }

    func cancelThumbnail() { task?.cancel(); task = nil; thumbnail.image = nil }
    @objc private func removeFile() { onRemove?(removal.state == .on) }
    @objc private func keepFile() { onKeep?() }
}
