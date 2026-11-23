import AppKit

/// 只维护可见范围及两侧各一屏的请求；图片 LRU 由 ImageDecoder 单独管理。
/// 选择按 URL 同步，扫描重排按可见 URL 锚定，避免把用户拖回当前图片。
@MainActor
final class ThumbnailStripController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 112
    private static let itemSize = CGSize(width: 112, height: 96)
    private static let spacing: CGFloat = 8
    private static let inset: CGFloat = 8

    var onSelect: ((URL) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onFocusCanvas: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    let collectionView = ThumbnailCollectionView()
    let scrollView = HorizontalThumbnailScrollView()
    private(set) var images: [URL] = []
    private(set) var selectedURL: URL?
    private(set) var followsSelection = true
    private(set) var requestedURLs: Set<URL> = []
    private let decoder: ImageDecoder
    private var indexByURL: [URL: Int] = [:]
    private var rootDirectoryComponents: [String]?
    private var loaded: [URL: Result<DecodedImage, Error>] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var isLoadingEnabled = false
    private var isUpdating = false
    private var pixelDimension = 0
    private var previousScrollX: CGFloat = 0
    var pendingRequestCount: Int { tasks.count }

    init(decoder: ImageDecoder) {
        self.decoder = decoder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        tasks.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.itemSize
        layout.minimumLineSpacing = Self.spacing
        layout.minimumInteritemSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: Self.inset, left: Self.inset,
                                           bottom: Self.inset, right: Self.inset)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [NSColor(calibratedWhite: 0.085, alpha: 1)]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.onNavigate = { [weak self] in self?.onNavigate?($0) }
        collectionView.onFinishInteraction = { [weak self] in self?.onFocusCanvas?() }
        collectionView.onContextMenu = { [weak self] path in
            guard let self, let makeMenu = self.onContextMenu else { return nil }
            if let path {
                guard self.images.indices.contains(path.item) else { return nil }
                let url = self.images[path.item]
                self.onSelect?(url)
                // 打开新会话期间选择可能被拒绝，此时不能把旧图片的菜单交给新点击的缩略图。
                guard self.selectedURL == url else { return nil }
            }
            self.onFocusCanvas?()
            return makeMenu()
        }
        collectionView.setAccessibilityLabel("图片和视频缩略条")

        scrollView.frame = NSRect(x: 0, y: 0, width: 1100, height: Self.height)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1)
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak self] in self?.followsSelection = false }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                name: NSView.boundsDidChangeNotification,
                                                object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(userBeganScrolling),
                                                name: NSScrollView.willStartLiveScrollNotification,
                                                object: scrollView)
        let container = NSView(frame: scrollView.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = scrollView.backgroundColor.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        updateDocumentSize()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !isUpdating else { return }
        isUpdating = true
        updateDocumentSize()
        if followsSelection { revealSelection() }
        isUpdating = false
        refreshLoadWindow()
    }

    func setLoadingEnabled(_ enabled: Bool) {
        guard isLoadingEnabled != enabled else { return }
        isLoadingEnabled = enabled
        if enabled {
            _ = view
            refreshLoadWindow()
        } else {
            cancelLoads()
        }
    }

    func update(images: [URL], selectedURL: URL?, rootDirectory: URL?) {
        _ = view
        let rootComponents = rootDirectory?.standardizedFileURL.pathComponents
        let rootChanged = rootDirectoryComponents != rootComponents
        let selectionChanged = self.selectedURL != selectedURL
        let oldBounds = scrollView.contentView.bounds
        let firstVisible = max(0, Int(floor((oldBounds.minX - Self.inset) / Self.stride)))
        let anchorURL = self.images.indices.contains(firstVisible) ? self.images[firstVisible] : nil
        let anchorOffset = oldBounds.minX - (Self.inset + CGFloat(firstVisible) * Self.stride)

        isUpdating = true
        rootDirectoryComponents = rootComponents
        if self.images != images {
            self.images = images
            indexByURL = Dictionary(uniqueKeysWithValues: images.enumerated().map { ($0.element, $0.offset) })
            updateDocumentSize()
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()
            // 只恢复同一个可见 URL 的相对位置；选中项由下面的独立规则决定是否滚入视野。
            if let anchorURL, let index = indexByURL[anchorURL] {
                scroll(to: Self.inset + CGFloat(index) * Self.stride + anchorOffset)
            }
        } else if rootChanged {
            // 同一批图片可以从不同根目录打开；只更新来源，不重置解码占位或手动浏览位置。
            for case let item as ThumbnailItem in collectionView.visibleItems() {
                guard let url = item.representedURL else { continue }
                item.updateSource(relativeDirectory: relativeDirectory(for: url))
            }
        }
        self.selectedURL = selectedURL
        collectionView.selectionIndexPaths = selectionPaths
        if selectionChanged { followsSelection = true }
        if followsSelection { revealSelection() }
        isUpdating = false
        refreshLoadWindow()
    }

    /// 用户切图时保证可见；对同一 URL 的扫描更新则保留手动滚动位置。
    func select(_ url: URL, reveal: Bool) {
        guard indexByURL[url] != nil else { return }
        selectedURL = url
        isUpdating = true
        collectionView.selectionIndexPaths = selectionPaths
        if reveal {
            followsSelection = true
            revealSelection()
        }
        isUpdating = false
        refreshLoadWindow()
    }

    /// 控制器先失效解码器缓存，再清除对应单元格；列表相同也必须允许重新请求缩略图。
    func invalidate(_ urls: Set<URL>) {
        for url in urls {
            tasks.removeValue(forKey: url)?.cancel()
            loaded.removeValue(forKey: url)
        }
        for case let item as ThumbnailItem in collectionView.visibleItems() {
            if let url = item.representedURL, urls.contains(url) { item.clearImage() }
        }
        refreshLoadWindow()
    }

    private var selectionPaths: Set<IndexPath> {
        guard let selectedURL, let index = indexByURL[selectedURL] else { return [] }
        return [IndexPath(item: index, section: 0)]
    }

    private static var stride: CGFloat { itemSize.width + spacing }

    private func updateDocumentSize() {
        let width = max(scrollView.contentSize.width,
                        Self.inset * 2 + CGFloat(images.count) * Self.stride - Self.spacing)
        let size = CGSize(width: width, height: Self.height)
        if collectionView.frame.size != size {
            collectionView.setFrameSize(size)
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    private func revealSelection() {
        guard let selectedURL, let index = indexByURL[selectedURL] else { return }
        let left = Self.inset + CGFloat(index) * Self.stride
        let right = left + Self.itemSize.width
        let bounds = scrollView.contentView.bounds
        // 导航只叠在内容上，不为它补空白；移入或移出缩略条也不会改变滚动位置。
        if left < bounds.minX + Self.inset { scroll(to: left - Self.inset) }
        else if right > bounds.maxX - Self.inset {
            scroll(to: right + Self.inset - bounds.width)
        }
    }

    private func scroll(to x: CGFloat) {
        let clip = scrollView.contentView
        let maximum = max(0, collectionView.bounds.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(maximum, max(0, x)), y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        let x = scrollView.contentView.bounds.minX
        defer { previousScrollX = x }
        guard !isUpdating else { return }
        // 滚动条拖动和辅助功能滚动不一定发出 live-scroll 通知，也要退出选中项跟随。
        if x != previousScrollX { followsSelection = false }
        refreshLoadWindow()
    }

    @objc private func userBeganScrolling(_ notification: Notification) { followsSelection = false }

    /// 范围按一行固定宽度求交，不遍历大目录，也不为离屏条目创建视图。
    func refreshLoadWindow() {
        guard isLoadingEnabled, isViewLoaded, !isUpdating else { return }
        let dimension = Int(ceil(100 * (view.window?.backingScaleFactor ?? 2)))
        if dimension != pixelDimension {
            cancelLoads()
            pixelDimension = dimension
        }
        let visible = scrollView.contentView.bounds
        guard visible.width > 0, !images.isEmpty else {
            cancelLoads()
            return
        }
        let lower = min(images.count, max(0, Int(floor((visible.minX - visible.width - Self.inset) / Self.stride))))
        let upper = min(images.count, Int(ceil((visible.maxX + visible.width - Self.inset) / Self.stride)))
        let desiredIndices = lower..<max(lower, upper)
        let desired = Set(desiredIndices.map { images[$0] })
        requestedURLs = desired
        for (url, task) in tasks where !desired.contains(url) {
            task.cancel()
            tasks.removeValue(forKey: url)
        }
        loaded = loaded.filter { desired.contains($0.key) }
        // 可见项先排队，左右预加载按离视口中心的距离排序，快速滚动时尽快填上当前屏。
        let center = (visible.midX - Self.inset) / Self.stride
        let ordered = desiredIndices.sorted { abs(CGFloat($0) - center) < abs(CGFloat($1) - center) }
        let requestGeneration = generation
        let decoder = decoder
        for index in ordered {
            let url = images[index]
            guard loaded[url] == nil, tasks[url] == nil else { continue }
            tasks[url] = Task { [weak self] in
                let result: Result<DecodedImage, Error>
                do {
                    let image = try await decoder.thumbnail(url, maxPixelDimension: dimension)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch is CancellationError {
                    return
                } catch {
                    result = .failure(error)
                }
                guard let self, self.generation == requestGeneration, !Task.isCancelled,
                      self.requestedURLs.contains(url) else { return }
                self.tasks.removeValue(forKey: url)
                self.loaded[url] = result
                if let index = self.indexByURL[url],
                   let item = self.collectionView.item(at: IndexPath(item: index, section: 0)) as? ThumbnailItem,
                   item.representedURL == url
                {
                    item.show(result)
                }
            }
        }
        for path in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: path) as? ThumbnailItem,
               let url = item.representedURL, let result = loaded[url]
            {
                item.show(result)
            }
        }
    }

    private func cancelLoads() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        requestedURLs.removeAll()
        loaded.removeAll()
        for item in collectionView.visibleItems() { (item as? ThumbnailItem)?.clearImage() }
    }

    /// 只比较规范化后的路径组件，避免把同名前缀的兄弟目录误判为子目录，也无需读取磁盘。
    private func relativeDirectory(for url: URL) -> String? {
        let components = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard let rootDirectoryComponents, components.count > rootDirectoryComponents.count,
              components.starts(with: rootDirectoryComponents) else { return nil }
        return components.dropFirst(rootDirectoryComponents.count).joined(separator: "/")
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        images.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
        let url = images[indexPath.item]
        item.configure(url: url, result: loaded[url], relativeDirectory: relativeDirectory(for: url))
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isUpdating, let path = indexPaths.first, images.indices.contains(path.item) else { return }
        onSelect?(images[path.item])
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath)
    {
        guard images.indices.contains(indexPath.item), let item = item as? ThumbnailItem else { return }
        let url = images[indexPath.item]
        item.configure(url: url, result: loaded[url], relativeDirectory: relativeDirectory(for: url))
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath)
    {
        // AppKit 可能把离屏视图留在复用池中，及时释放图片而不是等待下一次 prepareForReuse。
        (item as? ThumbnailItem)?.clearImage()
    }
}

@MainActor
final class ThumbnailCollectionView: NSCollectionView {
    var onNavigate: ((Int) -> Void)?
    var onFinishInteraction: (() -> Void)?
    var onContextMenu: ((IndexPath?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        // 使用实际布局命中条目，滚动后的坐标和单元格间隙无需单独推算。
        return onContextMenu?(indexPathForItem(at: point)) ?? super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // NSCollectionView 在 didSelect 回调之后还会夺回焦点，必须等它处理完点击再归还。
        onFinishInteraction?()
    }

    override func scrollWheel(with event: NSEvent) {
        // CollectionView/ClipView 的默认处理会先消费滚轮，显式转发才能把纵向滚轮映射为横向。
        if let scrollView = enclosingScrollView as? HorizontalThumbnailScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onNavigate?(-1)
        case 124: onNavigate?(1)
        case 49:
            onFinishInteraction?()
            if let responder = window?.firstResponder, responder !== self {
                responder.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class HorizontalThumbnailScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let distance = delta * (event.hasPreciseScrollingDeltas ? 1 : 16)
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: CGPoint(x: min(maximum, max(0, contentView.bounds.minX - distance)), y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class ThumbnailBadgeView: NSImageView {
    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.cornerRadius = 4
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        imageScaling = .scaleNone
        contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        isHidden = true
        setAccessibilityElement(false)
        // NSImageView 的图像单元格也会暴露给辅助功能；装饰角标没有独立的可朗读子元素。
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // SF Symbol 的光学对齐会扩展 NSImageView 的实际边界；角标背景应按真实边缘固定为 18 pt。
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }

    // 角标只补充来源，点击、右键和滚轮继续交给底下的缩略图。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    let directoryBadge: NSImageView = ThumbnailBadgeView(symbol: "folder")
    let videoBadge: NSImageView = ThumbnailBadgeView(symbol: "play.fill")
    private(set) var representedURL: URL?

    override var isSelected: Bool { didSet { updateSelection() } }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        // NSView 默认被辅助功能忽略，需把整张卡片公开为组，来源标签才会进入实际的辅助功能树。
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        view.addSubview(label)
        directoryBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(directoryBadge)
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoBadge)
        imageView = image
        textField = label
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            image.heightAnchor.constraint(equalToConstant: 64),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            directoryBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            directoryBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            directoryBadge.widthAnchor.constraint(equalToConstant: 18),
            directoryBadge.heightAnchor.constraint(equalToConstant: 18),
            videoBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            videoBadge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            videoBadge.widthAnchor.constraint(equalToConstant: 18),
            videoBadge.heightAnchor.constraint(equalToConstant: 18),
        ])
        updateSelection()
    }

    func configure(url: URL, result: Result<DecodedImage, Error>?, relativeDirectory: String?) {
        _ = view
        representedURL = url
        videoBadge.isHidden = MediaFileTypes.kind(for: url) != .video
        textField?.stringValue = url.lastPathComponent
        updateSource(relativeDirectory: relativeDirectory)
        if let result { show(result) } else { clearImage() }
    }

    /// 来源属于文件而非解码结果；根目录切换可单独更新，加载、失败和缓存失效都不会抹掉角标。
    func updateSource(relativeDirectory: String?) {
        guard let url = representedURL else { return }
        directoryBadge.isHidden = relativeDirectory == nil
        view.toolTip = relativeDirectory.map { "子目录：\($0)\n完整路径：\(url.path)" } ?? url.path
        let name = url.lastPathComponent + (MediaFileTypes.kind(for: url) == .video ? "，视频" : "")
        view.setAccessibilityLabel(relativeDirectory.map { "\(name)，子目录：\($0)" } ?? name)
        view.setAccessibilityHelp(view.toolTip)
    }

    func show(_ result: Result<DecodedImage, Error>) {
        switch result {
        case .success(let decoded):
            imageView?.contentTintColor = nil
            imageView?.image = NSImage(cgImage: decoded.image,
                                       size: CGSize(width: decoded.image.width, height: decoded.image.height))
        case .failure:
            imageView?.contentTintColor = .tertiaryLabelColor
            imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "无法生成缩略图")
        }
    }

    func clearImage() {
        imageView?.contentTintColor = .tertiaryLabelColor
        let isVideo = representedURL.flatMap { MediaFileTypes.kind(for: $0) } == .video
        imageView?.image = NSImage(systemSymbolName: isVideo ? "video" : "photo", accessibilityDescription: "正在载入缩略图")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        isSelected = false
        imageView?.image = nil
        textField?.stringValue = ""
        directoryBadge.isHidden = true
        videoBadge.isHidden = true
        view.toolTip = nil
        view.setAccessibilityLabel(nil)
        view.setAccessibilityHelp(nil)
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : NSColor.clear.cgColor
    }
}
