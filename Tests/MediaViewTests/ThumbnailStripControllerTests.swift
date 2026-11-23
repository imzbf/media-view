import AppKit
import Testing
@testable import MediaView

@Suite(.serialized)
@MainActor
final class ThumbnailStripControllerTests: FixtureTestCase {
    @Test
    func testLoadsOnlyVisibleAreaAndOneScreenOnEachSide() async throws {
        _ = NSApplication.shared
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { _, _ in image }
        let strip = ThumbnailStripController(decoder: decoder)
        defer { strip.setLoadingEnabled(false) }
        let urls = (0..<1000).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        strip.view.frame.size = CGSize(width: 360, height: 112)
        strip.view.layoutSubtreeIfNeeded()
        #expect(strip.scrollView.contentView.bounds.width == 360)
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: fixtureDirectory)
        strip.setLoadingEnabled(true)
        #expect(strip.requestedURLs == Set(urls[0..<6]))
        try await waitUntil { await decoder.thumbnailCachedURLs.isSuperset(of: strip.requestedURLs) }

        strip.scrollView.onUserScroll?()
        strip.scrollView.contentView.scroll(to: CGPoint(x: 1208, y: 0))
        strip.scrollView.reflectScrolledClipView(strip.scrollView.contentView)
        strip.refreshLoadWindow()
        #expect(strip.requestedURLs == Set(urls[7..<16]))
        try await waitUntil { await decoder.thumbnailCachedURLs.isSuperset(of: strip.requestedURLs) }
        #expect(strip.collectionView.collectionViewLayout is NSCollectionViewFlowLayout)
        strip.setLoadingEnabled(false)
        #expect(strip.requestedURLs.isEmpty)
    }

    @Test
    func testSelectionAndScanReorderPreserveManualViewportAnchor() throws {
        _ = NSApplication.shared
        let strip = ThumbnailStripController(decoder: ImageDecoder())
        let urls = (0..<200).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        strip.view.frame.size = CGSize(width: 360, height: 112)
        strip.view.layoutSubtreeIfNeeded()
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: fixtureDirectory)
        strip.select(urls[150], reveal: true)
        #expect(strip.scrollView.contentView.bounds.maxX >= 8 + 150 * 120 + 112)
        #expect(strip.collectionView.selectionIndexPaths == [IndexPath(item: 150, section: 0)])

        let anchorFrame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: 42, section: 0))?.frame)
        strip.scrollView.contentView.scroll(to: CGPoint(x: anchorFrame.minX + 9, y: 0))
        strip.scrollView.reflectScrolledClipView(strip.scrollView.contentView)
        strip.update(images: urls.reversed(), selectedURL: urls[150], rootDirectory: fixtureDirectory)
        #expect(strip.selectedURL == urls[150])
        #expect(strip.collectionView.selectionIndexPaths == [IndexPath(item: 49, section: 0)])
        #expect(!strip.followsSelection)
        let reorderedFrame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: 157, section: 0))?.frame)
        #expect(abs(strip.scrollView.contentView.bounds.minX - reorderedFrame.minX - 9) < 1)

        strip.select(urls[149], reveal: true)
        #expect(strip.followsSelection)
        #expect(strip.scrollView.contentView.bounds.minX <= CGFloat(50 * 120 + 8))
        strip.update(images: [], selectedURL: nil, rootDirectory: nil)
        #expect(strip.collectionView.selectionIndexPaths.isEmpty)
    }

    @Test
    func testThumbnailEdgesKeepTheirSpacingAndReceiveClicks() throws {
        _ = NSApplication.shared
        let strip = ThumbnailStripController(decoder: ImageDecoder())
        let urls = (0..<100).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        for width in [420, 1100] {
            strip.view.frame.size = CGSize(width: CGFloat(width), height: 112)
            strip.view.layoutSubtreeIfNeeded()
            strip.update(images: urls, selectedURL: urls[0], rootDirectory: fixtureDirectory)
            let firstFrame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame)
            let first = strip.collectionView.convert(firstFrame, to: strip.view)
            #expect(strip.scrollView.frame == strip.view.bounds && first.minX == 8)
            let firstHit = try #require(strip.view.hitTest(CGPoint(x: first.minX + 8, y: first.midY)))
            #expect(firstHit === strip.collectionView || firstHit.isDescendant(of: strip.collectionView))

            strip.select(urls[99], reveal: true)
            let lastFrame = try #require(strip.collectionView.layoutAttributesForItem(at: IndexPath(item: 99, section: 0))?.frame)
            let last = strip.collectionView.convert(lastFrame, to: strip.view)
            #expect(last.maxX == CGFloat(width) - 8 && strip.view.bounds.contains(last))
            let lastHit = try #require(strip.view.hitTest(CGPoint(x: last.maxX - 8, y: last.midY)))
            #expect(lastHit === strip.collectionView || lastHit.isDescendant(of: strip.collectionView))
        }
    }

    @Test
    func testDirectoryBadgesUseNormalizedRootComponentsAndCompleteRelativePaths() throws {
        _ = NSApplication.shared
        let strip = ThumbnailStripController(decoder: ImageDecoder())
        let root = fixtureDirectory.appendingPathComponent("图库", isDirectory: true)
        let longDirectory = "旅行/杭州/很长的子目录名称/原片 #1 100%"
        // 路径无需实际存在；同名前缀、点组件和转义字符不能改变目录归属。
        let cases: [(url: URL, directory: String?)] = [
            (root.appendingPathComponent("同名.png"), nil),
            (root.appendingPathComponent("旅行/同名.png"), "旅行"),
            (root.appendingPathComponent("旅行/杭州/同名.png"), "旅行/杭州"),
            (root.appendingPathComponent("\(longDirectory)/同名.png"), longDirectory),
            (root.appendingPathComponent("临时/../旅行/./同名.png"), "旅行"),
            (root.appendingPathComponent("旅行/../同名.png"), nil),
            (fixtureDirectory.appendingPathComponent("图库备份/旅行/同名.png"), nil),
            (root.appendingPathComponent("../外部/同名.png"), nil),
        ]
        strip.update(images: cases.map(\.url), selectedURL: cases[0].url,
                     rootDirectory: root.appendingPathComponent("临时/..", isDirectory: true))
        for (index, entry) in cases.enumerated() {
            let item = try #require(strip.collectionView(strip.collectionView,
                itemForRepresentedObjectAt: IndexPath(item: index, section: 0)) as? ThumbnailItem)
            #expect(item.directoryBadge.isHidden == (entry.directory == nil))
            let expectedTooltip = entry.directory.map { "子目录：\($0)\n完整路径：\(entry.url.path)" }
                ?? entry.url.path
            #expect(item.view.toolTip == expectedTooltip)
            #expect(item.view.accessibilityHelp() == expectedTooltip)
            // 只设置 label 不会让普通 NSView 出现在辅助功能树中；必须能访问到带来源的整张卡片。
            let accessibleCard = try #require(NSAccessibility.unignoredChildren(from: [item.view]).first as? NSView)
            #expect(accessibleCard === item.view)
            if let directory = entry.directory {
                #expect(accessibleCard.accessibilityLabel()?.contains("子目录：\(directory)") == true)
            } else {
                #expect(item.view.accessibilityLabel() == entry.url.lastPathComponent)
            }
        }
    }

    @Test
    func testRootChangeRefreshesVisibleBadgesWithoutMovingManualViewport() throws {
        _ = NSApplication.shared
        let strip = ThumbnailStripController(decoder: ImageDecoder())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = strip
        defer { window.close() }
        let nested = fixtureDirectory.appendingPathComponent("旅行/杭州", isDirectory: true)
        let urls = (0..<100).map { nested.appendingPathComponent("\($0).png") }
        strip.view.layoutSubtreeIfNeeded()
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: fixtureDirectory)
        strip.scrollView.contentView.scroll(to: CGPoint(x: 1208, y: 0))
        strip.scrollView.reflectScrolledClipView(strip.scrollView.contentView)
        strip.collectionView.layoutSubtreeIfNeeded()
        let item = try #require(strip.collectionView.item(at: IndexPath(item: 10, section: 0)) as? ThumbnailItem)
        #expect(!item.directoryBadge.isHidden)
        #expect(item.view.toolTip == "子目录：旅行/杭州\n完整路径：\(urls[10].path)")
        let bounds = strip.scrollView.contentView.bounds

        // 列表和选择都没变时仍须更新已有单元格，不能依赖 reloadData 或强制滚回选中项。
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: nested)
        #expect(item.directoryBadge.isHidden && item.view.toolTip == urls[10].path)
        #expect(item.view.accessibilityLabel() == urls[10].lastPathComponent)
        #expect(strip.scrollView.contentView.bounds == bounds && !strip.followsSelection)
        #expect(strip.selectedURL == urls[0])
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: nested.deletingLastPathComponent())
        #expect(!item.directoryBadge.isHidden)
        #expect(item.view.toolTip == "子目录：杭州\n完整路径：\(urls[10].path)")
        strip.update(images: urls, selectedURL: urls[0], rootDirectory: nil)
        #expect(item.directoryBadge.isHidden && item.view.accessibilityHelp() == urls[10].path)
    }

    @Test(arguments: [false, true])
    func testRootChangeDuringDecodeKeepsLatestSource(fails: Bool) async throws {
        _ = NSApplication.shared
        let nested = fixtureDirectory.appendingPathComponent("旅行/杭州", isDirectory: true)
        let url = nested.appendingPathComponent("同名.png")
        let decoded = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let requests = DecodeRecorder()
        let decoder = ImageDecoder { request, _ in
            requests.record(request.url)
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            if fails { throw ImageDecodeError.invalidImage }
            return decoded
        }
        let strip = ThumbnailStripController(decoder: decoder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = strip
        defer { gate.signal(); strip.setLoadingEnabled(false); window.close() }
        strip.view.layoutSubtreeIfNeeded()
        strip.update(images: [url], selectedURL: url, rootDirectory: fixtureDirectory)
        strip.setLoadingEnabled(true)
        try await waitFor([started], timeout: 2)
        let item = try #require(strip.collectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailItem)
        #expect(!item.directoryBadge.isHidden)

        // 旧请求完成时只能填图片，不能把来源恢复为发起请求时的扫描根目录。
        strip.update(images: [url], selectedURL: url, rootDirectory: nested)
        #expect(item.directoryBadge.isHidden && item.view.toolTip == url.path)
        gate.signal()
        try await waitUntil { strip.pendingRequestCount == 0 }
        #expect(item.directoryBadge.isHidden && item.view.accessibilityLabel() == url.lastPathComponent)
        #expect(item.imageView?.image != nil)
        #expect(item.imageView?.image?.accessibilityDescription == (fails ? "无法生成缩略图" : nil))

        strip.update(images: [url], selectedURL: url, rootDirectory: nested.deletingLastPathComponent())
        #expect(!item.directoryBadge.isHidden)
        #expect(item.view.toolTip == "子目录：杭州\n完整路径：\(url.path)")
        #expect(item.view.accessibilityHelp() == item.view.toolTip)
        #expect(item.isSelected && item.view.layer?.borderWidth == 2)
        #expect(requests.urls == [url], "只更新根目录不应重新解码已完成或失败的缩略图")
    }

    @Test
    func testReuseClearsPreviousImageNameTooltipAndSelectionStyle() throws {
        _ = NSApplication.shared
        let item = ThumbnailItem()
        let first = fixtureDirectory.appendingPathComponent("旅行/杭州/very-long-file-name.gif")
        let second = fixtureDirectory.appendingPathComponent("broken.png")
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        item.configure(url: first, result: .success(image), relativeDirectory: "旅行/杭州")
        item.view.frame.size = CGSize(width: 112, height: 96)
        item.view.layoutSubtreeIfNeeded()
        item.isSelected = true
        #expect(item.view.toolTip == "子目录：旅行/杭州\n完整路径：\(first.path)")
        #expect(item.textField?.maximumNumberOfLines == 1)
        #expect(item.imageView?.imageScaling == .scaleProportionallyUpOrDown)
        #expect(item.view.layer?.borderWidth == 2)
        #expect(item.imageView?.frame.height == 64)
        let badge = item.directoryBadge
        #expect(badge.frame.size == CGSize(width: 18, height: 18))
        #expect(badge.frame.minX == 8 && item.view.bounds.maxY - badge.frame.maxY == 8)
        let hit = item.view.hitTest(CGPoint(x: badge.frame.midX, y: badge.frame.midY))
        #expect(hit != nil && hit !== badge)
        #expect(!badge.acceptsFirstResponder && !badge.isAccessibilityElement())
        #expect(NSAccessibility.unignoredChildren(from: [badge]).isEmpty, "装饰图标的 NSImageCell 也不能成为独立朗读项")
        item.clearImage()
        #expect(!badge.isHidden, "重新加载只清除图片，必须保留来源角标")
        item.show(.failure(ImageDecodeError.invalidImage))
        #expect(!badge.isHidden, "解码失败仍须标识来源")
        item.prepareForReuse()
        #expect(item.representedURL == nil && item.imageView?.image == nil)
        #expect(item.view.toolTip == nil && item.textField?.stringValue == "")
        #expect(badge.isHidden && item.view.accessibilityLabel() == nil && item.view.accessibilityHelp() == nil)
        item.isSelected = false
        item.configure(url: second, result: .failure(ImageDecodeError.invalidImage), relativeDirectory: nil)
        #expect(item.representedURL == second)
        #expect(item.textField?.stringValue == "broken.png")
        #expect(item.imageView?.image != nil, "Corrupt files retain a visible placeholder")
        #expect(item.view.layer?.borderWidth == 0)
        #expect(badge.isHidden && item.view.toolTip == second.path)
    }

    @Test
    func testOldThumbnailCompletionCannotFillReorderedItem() async throws {
        _ = NSApplication.shared
        let oldURL = fixtureDirectory.appendingPathComponent("old.png")
        let newURL = fixtureDirectory.appendingPathComponent("new.png")
        let red = DecodedImage(image: try testBitmap(red: 1, blue: 0),
                               pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let blue = DecodedImage(image: try testBitmap(red: 0, blue: 1),
                                pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder { request, _ in
            if request.url == oldURL {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                return red
            }
            return blue
        }
        let strip = ThumbnailStripController(decoder: decoder)
        defer { gate.signal(); strip.setLoadingEnabled(false) }
        strip.view.frame.size = CGSize(width: 360, height: 112)
        strip.view.layoutSubtreeIfNeeded()
        strip.update(images: [oldURL], selectedURL: oldURL, rootDirectory: fixtureDirectory)
        strip.setLoadingEnabled(true)
        try await waitFor([started], timeout: 2)
        strip.update(images: [newURL], selectedURL: newURL, rootDirectory: fixtureDirectory)
        gate.signal()
        try await waitUntil { await decoder.thumbnailCachedURLs.contains(newURL) }
        #expect(!(await decoder.thumbnailCachedURLs.contains(oldURL)))
        let item = try #require(strip.collectionView(strip.collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as? ThumbnailItem)
        #expect(item.representedURL == newURL)
        let bitmap = try #require(item.imageView?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = try testPixels(bitmap)
        #expect(pixels[2] > 240 && pixels[0] < 20)
    }

    @Test
    func testCollectionViewForwardsWheelAndSpaceToTheirOwners() throws {
        _ = NSApplication.shared
        let viewer = MediaViewerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        defer { viewer.closeLibrary(); window.close() }
        let urls = (0..<100).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: urls, preferredImage: urls[0],
                                     isComplete: true, skippedPaths: 0))
        viewer.view.layoutSubtreeIfNeeded()
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                           wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        viewer.thumbnailStrip.collectionView.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
        #expect(viewer.thumbnailStrip.scrollView.contentView.bounds.minX > 0)

        window.makeFirstResponder(viewer.thumbnailStrip.collectionView)
        #expect(window.firstResponder === viewer.thumbnailStrip.collectionView)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        viewer.thumbnailStrip.collectionView.keyDown(with: space)
        #expect(window.firstResponder === viewer.canvas)
        viewer.canvas.cancelInteraction()
    }

    @Test
    func testContextMenuTargetsClickedThumbnailAndLeavesBlankSpaceSelectionAlone() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try makeFile("子目录/2.png", data: Data(contentsOf: first))
        let viewer = MediaViewerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        defer { viewer.closeLibrary(); window.close() }
        var targets: [URL] = []
        viewer.thumbnailStrip.onContextMenu = {
            if let url = viewer.currentURL { targets.append(url) }
            return NSMenu()
        }
        defer { viewer.thumbnailStrip.onContextMenu = nil }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.view.layoutSubtreeIfNeeded()
        let collection = viewer.thumbnailStrip.collectionView
        func requestMenu(at point: CGPoint, controlClick: Bool = false) throws -> NSMenu? {
            let event = try #require(NSEvent.mouseEvent(with: controlClick ? .leftMouseDown : .rightMouseDown,
                location: collection.convert(point, to: nil), modifierFlags: controlClick ? [.control] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            return collection.menu(for: event)
        }
        let secondFrame = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame)
        let secondItem = try #require(collection.item(at: IndexPath(item: 1, section: 0)) as? ThumbnailItem)
        let badge = secondItem.directoryBadge
        #expect(!badge.isHidden)
        let badgePoint = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: collection)
        #expect(try requestMenu(at: badgePoint) != nil)
        #expect(targets == [second] && viewer.currentURL == second && viewer.thumbnailStrip.selectedURL == second)
        #expect(window.firstResponder === viewer.canvas)
        try await waitUntil { !viewer.isLoading }
        #expect(try requestMenu(at: CGPoint(x: collection.bounds.maxX - 2, y: collection.bounds.midY)) != nil)
        #expect(targets == [second, second] && viewer.currentURL == second)

        let firstFrame = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame)
        #expect(try requestMenu(at: CGPoint(x: firstFrame.midX, y: firstFrame.midY), controlClick: true) != nil)
        #expect(targets.last == first && viewer.currentURL == first)

        // 输入验证期间不能切图，右键其他缩略图也不能悄悄返回仍针对上一张图的菜单。
        let invalid = try makeFile("notes.txt")
        viewer.open([invalid])
        #expect(try requestMenu(at: CGPoint(x: secondFrame.midX, y: secondFrame.midY)) == nil)
        #expect(targets.count == 3 && viewer.currentURL == first)
    }
}
