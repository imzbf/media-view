import AppKit

/// 网格只持有视口及上下各一屏的缩略图；数千张入选照片也不会同时启动解码。
@MainActor
final class SelectionGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collectionView = SelectionCollectionView()
    let scrollView = NSScrollView()
    var onOpen: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?
    private(set) var urls: [URL] = []
    private(set) var requestedURLs: Set<URL> = []
    private var missing: Set<URL> = []
    private let decoder: ImageDecoder
    private let flow = NSCollectionViewFlowLayout()
    private var active = false
    private var generation = UUID()
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var loaded: [URL: Result<DecodedImage, Error>] = [:]
    private var columns = 1
    private var rowHeight: CGFloat = 200
    private var dimension = 0
    private var isUpdating = false

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
        view = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 500))
        flow.scrollDirection = .vertical
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [NSColor(calibratedWhite: 0.06, alpha: 1)]
        collectionView.register(SelectionGridItem.self, forItemWithIdentifier: SelectionGridItem.identifier)
        collectionView.setAccessibilityLabel("入选照片网格，点击照片查看大图")
        collectionView.onOpen = { [weak self] index in
            guard let self, self.urls.indices.contains(index) else { return }
            self.onOpen?(self.urls[index])
        }
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        view.addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        layoutGrid()
    }

    override func viewDidLayout() { super.viewDidLayout(); layoutGrid() }

    func update(urls: [URL], missing: Set<URL>) {
        _ = view
        guard self.urls != urls || self.missing != missing else { return }
        let y = scrollView.contentView.bounds.minY
        self.urls = urls
        self.missing = missing
        isUpdating = true
        collectionView.reloadData()
        layoutGrid()
        scrollView.contentView.scroll(to: CGPoint(x: 0,
            y: min(y, max(0, collectionView.frame.height - scrollView.contentSize.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isUpdating = false
        refreshLoadWindow()
    }

    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        if enabled { refreshLoadWindow() } else { cancelLoads() }
    }

    private func layoutGrid() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        columns = max(1, Int((width - 20) / 188))
        let itemWidth = floor((width - 32 - CGFloat(columns - 1) * 12) / CGFloat(columns))
        let size = CGSize(width: itemWidth, height: floor(itemWidth * 0.66) + 62)
        rowHeight = size.height + 12
        if flow.itemSize != size { flow.itemSize = size }
        let rows = Int(ceil(Double(urls.count) / Double(columns)))
        collectionView.frame = CGRect(x: 0, y: 0, width: width,
            height: max(scrollView.contentSize.height, CGFloat(rows) * rowHeight + 20))
        refreshLoadWindow()
    }

    @objc private func scrolled() { refreshLoadWindow() }

    func refreshLoadWindow() {
        guard active, isViewLoaded, !isUpdating else { return }
        let viewport = scrollView.contentView.bounds
        guard viewport.height > 0 else { return }
        let pixels = Int(ceil(flow.itemSize.width * (view.window?.backingScaleFactor ?? 2)))
        if dimension != pixels { cancelLoads(); dimension = pixels }
        let lower = min(urls.count, max(0, Int(floor((viewport.minY - viewport.height - 16) / rowHeight))) * columns)
        let upper = min(urls.count, max(0, Int(ceil((viewport.maxY + viewport.height - 16) / rowHeight))) * columns)
        let visible = Array(urls[lower..<max(lower, upper)])
        requestedURLs = Set(visible).subtracting(missing)
        for (url, task) in tasks where !requestedURLs.contains(url) { task.cancel(); tasks.removeValue(forKey: url) }
        loaded = loaded.filter { requestedURLs.contains($0.key) }
        let generation = generation
        let decoder = decoder
        for url in visible where requestedURLs.contains(url) && tasks[url] == nil && loaded[url] == nil {
            tasks[url] = Task { [weak self] in
                let result: Result<DecodedImage, Error>
                do { result = .success(try await decoder.thumbnail(url, maxPixelDimension: pixels)) }
                catch is CancellationError { return }
                catch { result = .failure(error) }
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.requestedURLs.contains(url) else { return }
                self.tasks.removeValue(forKey: url)
                self.loaded[url] = result
                for case let item as SelectionGridItem in self.collectionView.visibleItems() where item.url == url {
                    item.show(result)
                }
            }
        }
        for case let item as SelectionGridItem in collectionView.visibleItems() {
            if let url = item.url, let result = loaded[url] { item.show(result) }
        }
    }

    private func cancelLoads() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        loaded.removeAll()
        requestedURLs.removeAll()
        if isViewLoaded {
            for case let item as SelectionGridItem in collectionView.visibleItems() { item.imageView?.image = nil }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SelectionGridItem.identifier, for: indexPath) as! SelectionGridItem
        configure(item, at: indexPath)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if let item = item as? SelectionGridItem { configure(item, at: indexPath) }
    }

    private func configure(_ item: SelectionGridItem, at path: IndexPath) {
        guard urls.indices.contains(path.item) else { return }
        let url = urls[path.item]
        item.configure(url, missing: missing.contains(url), result: loaded[url])
        item.onRemove = { [weak self] url in self?.onRemove?(url) }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) { item.imageView?.image = nil }
}

@MainActor
final class SelectionCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if let path { onOpen?(path.item) }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode), !event.isARepeat, let path = selectionIndexPaths.first {
            onOpen?(path.item)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class SelectionGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SelectionGridItem")
    private(set) var url: URL?
    private let badge = NSTextField(labelWithString: "✓ 入选")
    let removeButton = NSButton(title: "移出入选", target: nil, action: nil)
    var onRemove: ((URL) -> Void)?

    override var isSelected: Bool { didSet { view.layer?.borderWidth = isSelected ? 2 : 0 } }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.font = .systemFont(ofSize: 11)
        removeButton.target = self
        removeButton.action = #selector(removePhoto)
        imageView = image
        textField = label
        for control in [image, label, badge, removeButton] { control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control) }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            image.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            badge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            badge.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            removeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

    func configure(_ url: URL, missing: Bool, result: Result<DecodedImage, Error>?) {
        _ = view
        self.url = url
        textField?.stringValue = url.lastPathComponent
        view.toolTip = url.path
        view.setAccessibilityLabel("\(url.lastPathComponent)，\(missing ? "入选，文件缺失" : "入选")")
        badge.stringValue = missing ? "⚠ 文件缺失" : "✓ 入选"
        badge.textColor = missing ? .systemOrange : .systemGreen
        removeButton.setAccessibilityLabel("将 \(url.lastPathComponent) 移出入选，恢复为待选")
        if let result { show(result) } else {
            imageView?.image = NSImage(systemSymbolName: missing ? "exclamationmark.triangle" : "photo", accessibilityDescription: nil)
            imageView?.contentTintColor = .secondaryLabelColor
        }
    }

    func show(_ result: Result<DecodedImage, Error>) {
        switch result {
        case .success(let image):
            imageView?.image = NSImage(cgImage: image.image, size: .zero)
            imageView?.contentTintColor = nil
        case .failure:
            imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "无法生成缩略图")
            imageView?.contentTintColor = .secondaryLabelColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        url = nil
        onRemove = nil
        imageView?.image = nil
        view.toolTip = nil
        view.setAccessibilityLabel(nil)
    }

    @objc private func removePhoto() { if let url { onRemove?(url) } }
}
