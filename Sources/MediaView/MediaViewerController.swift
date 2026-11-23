import AppKit

@MainActor
final class MediaViewerController: NSViewController, NSMenuItemValidation {
    let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    let thumbnailStrip: ThumbnailStripController
    let previousButton = ViewerIconButton(symbol: "chevron.left", label: "上一项", style: .navigation)
    let nextButton = ViewerIconButton(symbol: "chevron.right", label: "下一项", style: .navigation)
    let playback: GIFPlaybackController
    let videoPlayback: VideoPlaybackController
    var onOpenPanel: (() -> Void)?
    var onCommandStateChanged: (() -> Void)?
    private(set) var images: [URL] = []
    private(set) var currentIndex: Int?
    private(set) var isScanning = false
    private(set) var isLoading = false
    private(set) var showsThumbnails = true
    private(set) var libraryOptions = LibraryOptions()
    private(set) var isSorting = false
    private(set) var isRefreshing = false
    private(set) var isTrashing = false
    private(set) var isSearchVisible = false
    private(set) var isSearching = false
    private(set) var searchMatches: [URL] = []
    private(set) var showsInfo = false
    // NSTextView 会初始化文本系统，默认浏览无需为尚未打开的信息卡付出这部分开销。
    private(set) lazy var searchBar = ImageSearchBar(frame: .zero)
    private(set) lazy var infoCard = ImageInfoCard(frame: .zero)
    private var infoTop: NSLayoutConstraint?
    private var searchQuery = ""
    private var pendingSearchDirection: Int?
    private var appliedScope = true
    private var stripHeight: NSLayoutConstraint?
    private var isWindowVisible = true
    private var isOpening = false
    private var directory: URL?
    private var displayedImage: DecodedImage?
    private var requestedQuality: DecodeQuality?
    private let decoder: ImageDecoder
    private let trashItem: @Sendable (URL) throws -> Void
    private var session = UUID()
    private var loadID = UUID()
    private var scanID = UUID()
    private var libraryRevision = UUID()
    private var sortID = UUID()
    private var searchID = UUID()
    private var infoID = UUID()
    private var scanTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var trashTask: Task<Void, Never>?

    init(decoder: ImageDecoder = ImageDecoder(),
         videoPlayback: VideoPlaybackController? = nil,
         trashItem: @escaping @Sendable (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         })
    {
        self.decoder = decoder
        self.trashItem = trashItem
        thumbnailStrip = ThumbnailStripController(decoder: decoder)
        playback = GIFPlaybackController(decoder: decoder)
        self.videoPlayback = videoPlayback ?? VideoPlaybackController()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var currentURL: URL? { currentIndex.map { images[$0] } }
    var hasImage: Bool { displayedImage != nil }
    var hasVideo: Bool { videoPlayback.state == .ready && videoPlayback.url == currentURL }
    var hasContent: Bool { hasImage || hasVideo }
    var canGoBack: Bool { !isOpening && (currentIndex ?? 0) > 0 }
    var canGoForward: Bool { !isOpening && (currentIndex.map { $0 + 1 < images.count } ?? false) }
    var isThumbnailStripVisible: Bool { showsThumbnails && !images.isEmpty }
    var canReloadImage: Bool { currentURL != nil && !isOpening && !isTrashing }
    var canCopyImage: Bool { currentURL != nil && !isOpening && !isTrashing }
    // 扫描和排序会提交整份快照，完成后再允许删除，避免旧列表重新带回已移走的文件。
    var canTrashImage: Bool { canCopyImage && !isScanning && !isSorting }
    var canRefreshDirectory: Bool { directory != nil && !isOpening && !isTrashing }
    var canChangeLibraryOptions: Bool { !isOpening && !isTrashing }
    var isEditingText: Bool {
        guard isViewLoaded, let responder = view.window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    override func loadView() {
        view = NSView(frame: canvas.frame)
        addChild(thumbnailStrip)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        thumbnailStrip.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        view.addSubview(thumbnailStrip.view)
        stripHeight = thumbnailStrip.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: thumbnailStrip.view.topAnchor),
            thumbnailStrip.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailStrip.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailStrip.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stripHeight!,
        ])
        thumbnailStrip.view.isHidden = true
        thumbnailStrip.onSelect = { [weak self] in self?.selectImage($0) }
        thumbnailStrip.onNavigate = { [weak self] in self?.navigate(by: $0) }
        thumbnailStrip.onFocusCanvas = { [weak self] in
            guard let self else { return }
            self.canvas.cancelInteraction()
            self.view.window?.makeFirstResponder(self.canvas)
        }
        canvas.onOpenFiles = { [weak self] in self?.open($0) }
        canvas.onOpenPanel = { [weak self] in self?.onOpenPanel?() }
        canvas.onNavigate = { [weak self] in self?.navigate(by: $0) }
        canvas.onDismissOverlay = { [weak self] in
            guard let self else { return false }
            if self.isSearchVisible { self.hideSearch(); return true }
            if self.showsInfo { self.toggleInfo(); return true }
            return false
        }
        canvas.onActualSize = { [weak self] in self?.loadOriginal() }
        canvas.onZoomChanged = { [weak self] in self?.updateTitle() }
        canvas.onDisplayChanged = { [weak self] in self?.scheduleDisplayRefresh() }
        canvas.onToggleVideoPlayback = { [weak self] in self?.videoPlayback.togglePlayback() }
        videoPlayback.onStateChanged = { [weak self] in self?.updateVideoState() }
        playback.onFrame = { [weak self] image in
            self?.displayedImage = image
            self?.canvas.displayFrame(image)
        }
        playback.onFailure = { [weak self] error in
            self?.canvas.showNotice("GIF 播放已停止：\(error.localizedDescription)。可继续使用方向键浏览。")
        }
        for (button, hint, action) in [
            (previousButton, "上一项（←）", #selector(previousImage)),
            (nextButton, "下一项（→）", #selector(nextImage)),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = action
            button.toolTip = hint
            // 兄弟视图不会自动把滚轮交给画布，显式转发以保留光标处缩放。
            button.onScroll = { [weak self] in self?.canvas.scrollWheel(with: $0) }
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
                button.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            ])
            if button === previousButton {
                button.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16).isActive = true
            } else {
                button.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -16).isActive = true
            }
        }
        updateNavigationButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowVisibility()
    }

    func open(_ inputs: [URL]) {
        _ = view
        cancelTasks()
        // 验证输入期间暂停旧 GIF 和视频；若拖入无效文件，仍能从原位置继续播放。
        isOpening = true
        playback.setVisible(false)
        videoPlayback.setVisible(false)
        thumbnailStrip.setLoadingEnabled(false)
        session = UUID()
        loadID = UUID()
        isLoading = false
        let openingSession = session
        scanID = UUID()
        let openingScan = scanID
        let options = libraryOptions
        isScanning = true
        if images.isEmpty {
            canvas.showStatus(title: "正在扫描…", detail: "", symbol: "folder")
        } else {
            canvas.showNotice("正在打开…")
        }
        updateTitle()
        scanTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.session == openingSession else { return }
            await self.decoder.reset()
            do {
                var receivedSelection = false
                for try await snapshot in ImageLibrary.scan(opening: inputs, options: options) {
                    try Task.checkCancellation()
                    guard self.session == openingSession, self.scanID == openingScan else { return }
                    if !receivedSelection {
                        // 验证成功后才替换图库；误拖入不支持的文件仍可继续浏览原目录。
                        self.images = []
                        self.currentIndex = nil
                        self.displayedImage = nil
                        self.requestedQuality = nil
                        self.playback.stop()
                        self.videoPlayback.stop()
                        self.isOpening = false
                        self.appliedScope = options.includesSubdirectories
                        self.hideSearch()
                        self.canvas.showStatus(title: "正在扫描…", detail: "", symbol: "folder")
                        receivedSelection = true
                    }
                    self.apply(snapshot, sortedBy: options.sort)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.session == openingSession, self.scanID == openingScan, !Task.isCancelled else { return }
                self.isScanning = false
                self.isOpening = false
                // 无效输入可能打断尚未提交的范围切换；恢复当前图库实际采用的范围。
                self.libraryOptions.includesSubdirectories = self.appliedScope
                let failure = error as? LocalizedError
                if self.currentURL == nil {
                    self.canvas.showStatus(title: failure?.errorDescription ?? "扫描失败",
                                           detail: failure?.recoverySuggestion ?? error.localizedDescription,
                                           symbol: "exclamationmark.folder", showOpenButton: true)
                } else {
                    if !self.hasContent, !self.isLoading {
                        // 无效输入也可能打断尚未完成的首张解码，恢复该请求以保留原会话。
                        self.loadCurrent(quality: self.canvas.screenQuality, preservingImage: false)
                    }
                    if self.hasVideo { self.updateVideoState() }
                    self.canvas.showNotice(failure?.errorDescription ?? "部分路径无法读取")
                }
                self.setWindowVisible(self.isWindowVisible)
                self.scheduleSort()
                self.scheduleSearch()
                self.refreshInfo()
                self.updateTitle()
            }
        }
        view.window?.makeFirstResponder(canvas)
    }

    func apply(_ snapshot: LibrarySnapshot, sortedBy order: LibrarySort? = nil) {
        sortTask?.cancel()
        sortID = UUID()
        isSorting = false
        libraryRevision = UUID()
        let previousURL = currentURL
        images = snapshot.images
        currentIndex = snapshot.currentIndex(keeping: previousURL)
        directory = snapshot.directory
        isScanning = !snapshot.isComplete
        thumbnailStrip.update(images: images, selectedURL: currentURL, rootDirectory: directory)
        updateThumbnailVisibility()
        if let currentURL, currentURL != previousURL {
            loadCurrent(quality: canvas.screenQuality, preservingImage: false)
            refreshInfo()
        } else if currentURL == nil, snapshot.isComplete {
            decodeTask?.cancel()
            cancelLoadingIndicator()
            playback.stop()
            videoPlayback.stop()
            loadID = UUID()
            displayedImage = nil
            requestedQuality = nil
            isLoading = false
            canvas.showStatus(title: "没有找到图片或视频",
                              detail: snapshot.skippedPaths > 0
                                ? "部分路径无法读取。请检查权限，或打开其他文件夹。"
                                : (libraryOptions.includesSubdirectories
                                    ? "此文件夹及其子目录中没有支持的图片或视频。" : "此文件夹中没有支持的图片或视频。"),
                              symbol: "folder", showOpenButton: true)
            refreshInfo()
        } else if hasContent {
            prefetchNeighbors()
        }
        scheduleSearch()
        // 扫描过程中允许修改排序偏好；最终快照必须服从最新偏好，而非启动扫描时的旧值。
        if snapshot.isComplete, let order, order != libraryOptions.sort { scheduleSort() }
        updateTitle()
    }

    func navigate(by delta: Int) {
        guard let index = currentIndex else { return }
        let next = index + delta
        guard images.indices.contains(next), next != index else { return }
        selectImage(images[next])
    }

    // 点击控件可能消费空格的 keyUp，切图前结束画布拖拽，选择入口随后归还键盘焦点。
    @objc private func previousImage() { canvas.cancelInteraction(); navigate(by: -1) }
    @objc private func nextImage() { canvas.cancelInteraction(); navigate(by: 1) }

    func selectImage(_ url: URL, focusCanvas: Bool = true) {
        guard !isOpening, let index = images.firstIndex(of: url) else { return }
        thumbnailStrip.select(url, reveal: true)
        if focusCanvas { view.window?.makeFirstResponder(canvas) }
        guard index != currentIndex else { return }
        currentIndex = index
        loadCurrent(quality: canvas.screenQuality, preservingImage: false)
        refreshInfo()
        updateSearchStatus()
        updateTitle()
    }

    func setSort(_ order: LibrarySort) {
        guard canChangeLibraryOptions, libraryOptions.sort != order else { return }
        libraryOptions.sort = order
        // 目录刷新最后会读取最新排序；不同时为旧列表启动一轮无效排序。
        if !isRefreshing { scheduleSort() }
    }

    private func scheduleSort() {
        sortTask?.cancel()
        sortID = UUID()
        guard !images.isEmpty else { isSorting = false; return }
        isSorting = true
        let id = sortID
        let revision = libraryRevision
        let images = images
        let order = libraryOptions.sort
        updateTitle()
        sortTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { try ImageLibrary.sortedImages(images, by: order) }
            do {
                // detached 不自动继承父任务取消，需要显式传递才能停止磁盘属性读取和比较。
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.sortID == id, self.libraryRevision == revision else { return }
                let selected = self.currentURL
                self.images = result
                self.currentIndex = selected.flatMap { result.firstIndex(of: $0) }
                self.libraryRevision = UUID()
                self.isSorting = false
                self.thumbnailStrip.update(images: result, selectedURL: selected, rootDirectory: self.directory)
                self.prefetchNeighbors()
                self.scheduleSearch()
                self.updateTitle()
            } catch {
                guard let self, self.sortID == id else { return }
                self.isSorting = false
                if !(error is CancellationError) { self.canvas.showNotice("排序失败：\(error.localizedDescription)") }
                self.updateTitle()
            }
        }
    }

    func setIncludesSubdirectories(_ includes: Bool) {
        guard canChangeLibraryOptions, libraryOptions.includesSubdirectories != includes else { return }
        libraryOptions.includesSubdirectories = includes
        if directory != nil { rescanDirectory(resetCache: false) }
    }

    func refreshDirectory() {
        guard canRefreshDirectory else { return }
        rescanDirectory(resetCache: true)
    }

    /// 原图库保持可浏览，完整新快照成功后才提交；失败不能把当前会话清空。
    private func rescanDirectory(resetCache: Bool) {
        guard let directory else { return }
        scanTask?.cancel()
        sortTask?.cancel()
        sortID = UUID()
        isSorting = false
        scanID = UUID()
        let id = scanID
        let session = session
        let options = libraryOptions
        isRefreshing = true
        isScanning = true
        updateTitle()
        scanTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                var final: LibrarySnapshot?
                for try await snapshot in ImageLibrary.scan(opening: [directory], options: options) {
                    try Task.checkCancellation()
                    if snapshot.isComplete { final = snapshot }
                }
                guard let self, self.session == session, self.scanID == id, let final else { return }
                var ordered = final.images
                var order = options.sort
                while order != self.libraryOptions.sort {
                    order = self.libraryOptions.sort
                    let input = final.images
                    let selectedOrder = order
                    let worker = Task.detached(priority: .userInitiated) {
                        try ImageLibrary.sortedImages(input, by: selectedOrder)
                    }
                    ordered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard self.session == session, self.scanID == id else { return }
                }
                let selected = self.currentURL
                let quality = self.requestedQuality ?? self.canvas.screenQuality
                if resetCache {
                    // 提交期间暂缓导航与缩略请求，防止 reset 前的视图立即重新填入旧缓存。
                    self.isOpening = true
                    self.decodeTask?.cancel()
                    self.cancelLoadingIndicator()
                    self.resizeTask?.cancel()
                    self.infoTask?.cancel()
                    self.infoID = UUID()
                    self.playback.stop()
                    self.videoPlayback.stop()
                    self.loadID = UUID()
                    self.isLoading = false
                    self.thumbnailStrip.setLoadingEnabled(false)
                    self.updateTitle()
                    await self.decoder.reset()
                    try Task.checkCancellation()
                    guard self.session == session, self.scanID == id else { return }
                    self.isOpening = false
                }
                self.appliedScope = options.includesSubdirectories
                self.isRefreshing = false
                self.apply(LibrarySnapshot(directory: directory, images: ordered, preferredImage: nil,
                                           isComplete: true, skippedPaths: final.skippedPaths), sortedBy: order)
                if resetCache, self.currentURL == selected, selected != nil {
                    self.loadCurrent(quality: quality, preservingImage: self.hasImage)
                    self.refreshInfo()
                }
                if final.skippedPaths > 0 { self.canvas.showNotice("刷新完成，部分路径无法读取。") }
            } catch {
                guard let self, self.session == session, self.scanID == id, !Task.isCancelled else { return }
                self.libraryOptions.includesSubdirectories = self.appliedScope
                self.isRefreshing = false
                self.isScanning = false
                self.isOpening = false
                self.canvas.showNotice("刷新失败：\(error.localizedDescription)")
                self.setWindowVisible(self.isWindowVisible)
                self.updateTitle()
            }
        }
    }

    func reloadCurrentImage() {
        guard canReloadImage else { return }
        loadCurrent(quality: requestedQuality ?? canvas.screenQuality,
                    preservingImage: hasImage, invalidateCache: true)
    }

    @objc func copy(_ sender: Any?) { copyCurrentImage() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return canCopyImage && view.window?.attachedSheet == nil
    }

    /// 写入原文件 URL，Finder 粘贴时保留图片、视频及其元数据，不复制预览内容。
    @discardableResult
    func copyCurrentImage(to pasteboard: NSPasteboard = .general) -> Bool {
        guard canCopyImage, let url = currentURL else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            canvas.showNotice("复制失败，请重试。")
            return false
        }
        return true
    }

    /// 文件移动可能访问外置盘或网络盘；后台完成后才更新列表，失败保留原会话。
    func trashCurrentImage() {
        guard canTrashImage, let url = currentURL, let directory else { return }
        isTrashing = true
        let session = session
        let trashItem = trashItem
        updateTitle()
        trashTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try trashItem(url)
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.session == session else { return }
                if let index = self.images.firstIndex(of: url) {
                    var remaining = self.images
                    remaining.remove(at: index)
                    // 按删除时的列表位置选择下一张，末尾则选上一张；期间主动切图就保留新选择。
                    if self.currentURL == url, !remaining.isEmpty {
                        self.selectImage(remaining[min(index, remaining.count - 1)], focusCanvas: false)
                    }
                    self.apply(LibrarySnapshot(directory: directory, images: remaining, preferredImage: nil,
                                               isComplete: true, skippedPaths: 0))
                }
                await self.decoder.invalidate([url])
                // 系统移动一旦开始便无法撤回；切换目录或关窗后不能再把旧结果写进新会话。
                guard !Task.isCancelled, self.session == session else { return }
                self.thumbnailStrip.invalidate([url])
                self.isTrashing = false
                self.updateTitle()
            } catch {
                guard let self, !Task.isCancelled, self.session == session else { return }
                self.isTrashing = false
                self.canvas.showNotice("删除失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
                self.updateTitle()
            }
        }
    }

    private func loadOriginal() {
        guard hasImage else { return }
        if playback.animation != nil {
            requestedQuality = .original
            playback.changeQuality(to: .original)
            return
        }
        guard displayedImage?.isFullResolution != true else { return }
        loadCurrent(quality: .original, preservingImage: true)
    }

    private func loadCurrent(quality: DecodeQuality, preservingImage: Bool, invalidateCache: Bool = false) {
        guard let url = currentURL else { return }
        decodeTask?.cancel()
        cancelLoadingIndicator()
        resizeTask?.cancel()
        playback.stop()
        videoPlayback.stop()
        loadID = UUID()
        let requestID = loadID
        let loadingSession = session
        let isVideo = MediaFileTypes.kind(for: url) == .video
        requestedQuality = isVideo ? nil : quality
        isLoading = true
        // 旧图仅由画布暂留，不能被当作当前 URL 已解码，否则新图会继承旧图视角或错误回退。
        if !preservingImage || isVideo { displayedImage = nil }
        if isVideo {
            canvas.prepareForVideo(videoPlayback.player, filename: url.lastPathComponent)
        } else {
            canvas.prepareForLoading()
        }
        loadingIndicatorTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            // 连切、换目录和关闭都会撤销等待；同时校验归属，避免已唤醒的旧任务回填提示。
            guard let self, !Task.isCancelled, self.session == loadingSession,
                  self.loadID == requestID, self.currentURL == url, self.isLoading else { return }
            self.canvas.setLoadingIndicatorVisible(true)
            self.loadingIndicatorTask = nil
        }
        decodeTask = Task { [weak self] in
            // 取消可能发生在 Task 首次执行前；失效缓存和信息卡前先确认请求仍属于当前图片。
            guard let self, !Task.isCancelled, self.loadID == requestID, self.currentURL == url else { return }
            do {
                if invalidateCache {
                    self.infoTask?.cancel()
                    self.infoID = UUID()
                    await self.decoder.invalidate([url])
                    try Task.checkCancellation()
                    guard self.loadID == requestID, self.currentURL == url else { return }
                    self.thumbnailStrip.invalidate([url])
                    self.refreshInfo()
                }
                if isVideo {
                    self.videoPlayback.prepare(url, visible: self.isWindowVisible && !self.isOpening)
                    self.prefetchNeighbors()
                    return
                }
                let decoded = try await self.decoder.load(url, quality: quality)
                try Task.checkCancellation()
                guard self.loadID == requestID, self.currentURL == url else { return }
                self.cancelLoadingIndicator()
                self.isLoading = false
                self.displayedImage = decoded
                self.canvas.display(decoded, filename: url.lastPathComponent,
                                    resetTransform: !preservingImage)
                if let animation = decoded.animation {
                    self.playback.start(animation, firstFrame: decoded, quality: quality,
                                        visible: self.isWindowVisible && !self.isOpening)
                }
                self.prefetchNeighbors()
            } catch is CancellationError {
                return
            } catch {
                guard self.loadID == requestID, self.currentURL == url, !Task.isCancelled else { return }
                self.cancelLoadingIndicator()
                self.isLoading = false
                let failure = error as? LocalizedError
                if preservingImage, self.displayedImage != nil {
                    let action = invalidateCache ? "重新载入失败" : "图片加载失败"
                    self.canvas.showNotice("\(action)：\(failure?.errorDescription ?? error.localizedDescription)。仍显示上次载入的图片。")
                } else {
                    self.canvas.showStatus(title: failure?.errorDescription ?? "无法打开图片",
                                           detail: failure?.recoverySuggestion ?? error.localizedDescription,
                                           symbol: "exclamationmark.triangle")
                }
                self.updateTitle()
                self.prefetchNeighbors()
            }
        }
    }

    private func cancelLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = nil
        canvas.setLoadingIndicatorVisible(false)
    }

    private func updateVideoState() {
        guard !isOpening, let url = currentURL, videoPlayback.url == url else { return }
        switch videoPlayback.state {
        case .loading:
            isLoading = true
        case .ready:
            cancelLoadingIndicator()
            isLoading = false
            canvas.finishVideoLoading()
        case .failed:
            cancelLoadingIndicator()
            isLoading = false
            let failure = videoPlayback.error as? LocalizedError
            canvas.showStatus(title: failure?.errorDescription ?? "无法打开视频",
                              detail: failure?.recoverySuggestion ?? VideoLoadError.invalidVideo.recoverySuggestion!,
                              symbol: "exclamationmark.triangle")
        case .idle: return
        }
        updateTitle()
    }

    private func prefetchNeighbors() {
        guard let index = currentIndex else { return }
        let urls = [index + 1, index - 1].filter { images.indices.contains($0) }.map { images[$0] }
        let quality = canvas.screenQuality
        let requestID = loadID
        let revision = libraryRevision
        Task { [weak self] in
            guard let self, self.loadID == requestID, self.libraryRevision == revision else { return }
            await self.decoder.prefetch(urls, quality: quality)
        }
    }

    func showSearch() {
        _ = view
        guard !images.isEmpty else { return }
        if searchBar.superview == nil {
            searchBar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(searchBar)
            let width = searchBar.widthAnchor.constraint(equalToConstant: 560)
            // 浮层的首选尺寸要低于 windowSizeStayPut（500），否则 AppKit 会反过来撑大窗口。
            width.priority = .defaultLow
            NSLayoutConstraint.activate([
                searchBar.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12),
                searchBar.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                searchBar.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 12),
                searchBar.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -12),
                width,
                searchBar.heightAnchor.constraint(equalToConstant: 40),
            ])
            searchBar.onQueryChanged = { [weak self] in self?.setSearchQuery($0) }
            searchBar.onNavigate = { [weak self] in self?.navigateSearch(by: $0) }
            searchBar.onClose = { [weak self] in self?.hideSearch() }
        }
        isSearchVisible = true
        searchBar.isHidden = false
        infoTop?.constant = 60
        canvas.cancelInteraction()
        view.window?.makeFirstResponder(searchBar.searchField)
        searchBar.searchField.selectText(nil)
        scheduleSearch()
    }

    func hideSearch() {
        guard isSearchVisible else { return }
        isSearchVisible = false
        searchTask?.cancel()
        searchID = UUID()
        isSearching = false
        pendingSearchDirection = nil
        searchMatches = []
        searchQuery = ""
        searchBar.searchField.stringValue = ""
        searchBar.isHidden = true
        infoTop?.constant = 12
        view.window?.makeFirstResponder(canvas)
    }

    func setSearchQuery(_ query: String) {
        guard isSearchVisible else { return }
        searchQuery = query
        if searchBar.searchField.stringValue != query { searchBar.searchField.stringValue = query }
        pendingSearchDirection = nil
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchID = UUID()
        searchMatches = []
        isSearching = false
        guard isSearchVisible else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchBar.setStatus("输入文件名"); return }
        isSearching = true
        searchBar.setStatus("查找中…")
        let id = searchID
        let revision = libraryRevision
        let images = images
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let worker = Task.detached(priority: .userInitiated) {
                    try ImageLibrary.matchingImages(in: images, query: query)
                }
                let matches = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.searchID == id, self.libraryRevision == revision, self.isSearchVisible else { return }
                self.searchMatches = matches
                self.isSearching = false
                self.updateSearchStatus()
                if let direction = self.pendingSearchDirection {
                    self.pendingSearchDirection = nil
                    self.navigateSearch(by: direction)
                }
            } catch {
                // 查询被新输入或新快照替换时不更新计数，也不导航到旧图库。
            }
        }
    }

    func navigateSearch(by delta: Int) {
        if isSearching { pendingSearchDirection = delta; return }
        guard !searchMatches.isEmpty else { return }
        let target: Int
        if let url = currentURL, let index = searchMatches.firstIndex(of: url) {
            target = (index + delta + searchMatches.count) % searchMatches.count
        } else {
            target = delta > 0 ? 0 : searchMatches.count - 1
        }
        selectImage(searchMatches[target], focusCanvas: false)
        updateSearchStatus()
    }

    private func updateSearchStatus() {
        guard isSearchVisible, !isSearching else { return }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchBar.setStatus("输入文件名")
        } else if searchMatches.isEmpty {
            searchBar.setStatus("未找到", isFailure: true)
        } else if let url = currentURL, let index = searchMatches.firstIndex(of: url) {
            searchBar.setStatus("\(index + 1) / \(searchMatches.count)", canNavigate: true)
        } else {
            searchBar.setStatus("\(searchMatches.count) 项", canNavigate: true)
        }
    }

    func toggleInfo() {
        _ = view
        showsInfo.toggle()
        if !showsInfo {
            infoTask?.cancel()
            infoID = UUID()
            infoCard.isHidden = true
            infoCard.showStatus("")
            view.window?.makeFirstResponder(isSearchVisible ? searchBar.searchField : canvas)
            return
        }
        if infoCard.superview == nil {
            infoCard.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(infoCard)
            infoTop = infoCard.topAnchor.constraint(equalTo: canvas.topAnchor, constant: isSearchVisible ? 60 : 12)
            let height = infoCard.heightAnchor.constraint(equalToConstant: 360)
            // 高度不足时交给卡片内的滚动视图，不能为容纳浮层改变预览区域的几何。
            height.priority = .defaultLow
            NSLayoutConstraint.activate([
                infoTop!, height,
                infoCard.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -12),
                infoCard.widthAnchor.constraint(equalToConstant: 320),
                infoCard.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -12),
            ])
            infoCard.onClose = { [weak self] in self?.toggleInfo() }
        }
        infoCard.isHidden = false
        refreshInfo()
    }

    private func refreshInfo() {
        infoTask?.cancel()
        infoID = UUID()
        guard showsInfo else { return }
        guard let url = currentURL else { infoCard.showStatus("未选择文件"); return }
        let id = infoID
        let session = session
        infoCard.showStatus("\(url.lastPathComponent)\n\n正在读取…")
        infoTask = Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await self.decoder.metadata(of: url)
                try Task.checkCancellation()
                guard self.infoID == id, self.session == session, self.currentURL == url, self.showsInfo else { return }
                self.infoCard.show(metadata)
            } catch {
                guard self.infoID == id, self.session == session, self.showsInfo, !Task.isCancelled else { return }
                self.infoCard.showStatus("无法读取文件信息：\(error.localizedDescription)")
            }
        }
    }

    private func scheduleDisplayRefresh() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.hasImage, self.displayedImage?.isFullResolution != true,
                  case .screen(let previousSize) = self.requestedQuality,
                  case .screen(let neededSize) = self.canvas.screenQuality,
                  neededSize > previousSize
            else { return }
            if self.playback.animation != nil {
                self.requestedQuality = self.canvas.screenQuality
                self.playback.changeQuality(to: self.canvas.screenQuality)
            } else {
                self.loadCurrent(quality: self.canvas.screenQuality, preservingImage: true)
            }
        }
    }

    func toggleThumbnails() {
        showsThumbnails.toggle()
        updateThumbnailVisibility()
    }

    private func updateThumbnailVisibility() {
        stripHeight?.constant = isThumbnailStripVisible ? ThumbnailStripController.height : 0
        thumbnailStrip.view.isHidden = !isThumbnailStripVisible
        thumbnailStrip.setLoadingEnabled(isThumbnailStripVisible && isWindowVisible && !isOpening)
    }

    func updateWindowVisibility() {
        guard isViewLoaded else { return }
        let window = view.window
        setWindowVisible(window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden)
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        playback.setVisible(visible && !isOpening)
        videoPlayback.setVisible(visible && !isOpening)
        updateThumbnailVisibility()
    }

    private func updateNavigationButtons() {
        // 导航取决于图库位置而非解码结果，加载中和损坏媒体仍可跳过，空图库则不显示控件。
        previousButton.isHidden = currentURL == nil
        nextButton.isHidden = currentURL == nil
        previousButton.isEnabled = canGoBack
        nextButton.isEnabled = canGoForward
        previousButton.setAccessibilityHelp(canGoBack ? "显示上一项" : "已是第一项或暂不可切换")
        nextButton.setAccessibilityHelp(canGoForward ? "显示下一项" : "已是最后一项或暂不可切换")
    }

    private func updateTitle() {
        updateNavigationButtons()
        onCommandStateChanged?()
        guard isViewLoaded, let window = view.window else { return }
        if let url = currentURL, let index = currentIndex {
            let activity = isTrashing ? " · 正在删除" : (isScanning ? " · 扫描中" : (isSorting ? " · 排序中" : ""))
            window.title = "\(url.lastPathComponent) — \(index + 1) / \(images.count)\(activity)"
            window.representedURL = url
            if let image = displayedImage {
                let percent = Int((canvas.geometry.scale * canvas.geometry.backingScale * 100).rounded())
                window.subtitle = "\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)) · \(percent)%"
            } else if hasVideo, let info = videoPlayback.info {
                window.subtitle = "\(Int(info.pixelSize.width.rounded())) × \(Int(info.pixelSize.height.rounded())) · \(info.durationText)"
            } else {
                window.subtitle = ""
            }
        } else {
            window.title = directory.map { "\($0.lastPathComponent) — MediaView" } ?? "MediaView"
            window.subtitle = isScanning ? "正在扫描…" : ""
            window.representedURL = nil
        }
    }

    func closeLibrary() {
        cancelTasks()
        hideSearch()
        if showsInfo { toggleInfo() }
        playback.stop()
        videoPlayback.stop()
        session = UUID()
        loadID = UUID()
        libraryRevision = UUID()
        images = []
        currentIndex = nil
        displayedImage = nil
        directory = nil
        isScanning = false
        isLoading = false
        isOpening = false
        requestedQuality = nil
        thumbnailStrip.update(images: [], selectedURL: nil, rootDirectory: nil)
        updateThumbnailVisibility()
        canvas.cancelInteraction()
        canvas.showWelcome()
        updateTitle()
        let closingSession = session
        Task { [weak self] in
            guard let self, self.session == closingSession else { return }
            await self.decoder.reset()
        }
    }

    private func cancelTasks() {
        scanTask?.cancel()
        decodeTask?.cancel()
        cancelLoadingIndicator()
        resizeTask?.cancel()
        sortTask?.cancel()
        searchTask?.cancel()
        infoTask?.cancel()
        trashTask?.cancel()
        sortID = UUID()
        searchID = UUID()
        infoID = UUID()
        isSorting = false
        isSearching = false
        isRefreshing = false
        isTrashing = false
    }
}
