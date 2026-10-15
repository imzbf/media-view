import AppKit
import Testing
@testable import ImageView

@Suite(.serialized)
@MainActor
final class ImageViewerFeaturesTests: FixtureTestCase {
    @Test
    func testNavigationButtonsShareSelectionAndNewImageResetsOrientation() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try writeImage("2.png")
        let metadataReads = DecodeRecorder()
        let decoder = ImageDecoder(metadataLoader: { url, _ in
            metadataReads.record(url)
            return ImageMetadata(fields: [])
        })
        let viewer = ImageViewerController(decoder: decoder)
        let window = makeWindow(viewer)
        defer { viewer.closeLibrary(); window.close() }
        #expect(viewer.previousButton.isHidden && viewer.nextButton.isHidden)
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
        #expect(!viewer.previousButton.isHidden && !viewer.nextButton.isHidden)
        #expect(!viewer.previousButton.isEnabled && viewer.nextButton.isEnabled)
        #expect(viewer.previousButton.image != nil && viewer.nextButton.image != nil)
        viewer.canvas.rotate(clockwise: true)
        viewer.canvas.mirror(horizontal: true)
        // 收起列表后仍可通过预览按钮切图，并从文本编辑恢复到画布键盘操作。
        viewer.toggleThumbnails()
        viewer.showSearch()
        #expect(viewer.isEditingText && !viewer.isThumbnailStripVisible)
        viewer.nextButton.performClick(nil)
        try await waitUntil { viewer.currentURL == second && !viewer.isLoading }
        #expect(window.firstResponder === viewer.canvas)
        #expect(viewer.canvas.geometry.orientation == .identity)
        #expect(viewer.previousButton.isEnabled && !viewer.nextButton.isEnabled)
        #expect(viewer.thumbnailStrip.selectedURL == second)
        viewer.previousButton.performClick(nil)
        try await waitUntil { viewer.currentURL == first && !viewer.isLoading }
        #expect(!viewer.previousButton.isEnabled)
        #expect(metadataReads.urls.isEmpty, "Normal browsing must not start metadata reads")
        let invalid = try makeFile("notes.txt")
        viewer.open([invalid])
        #expect(!viewer.previousButton.isEnabled && !viewer.nextButton.isEnabled)
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.nextButton.isEnabled && viewer.currentURL == first)
        viewer.closeLibrary()
        #expect(viewer.previousButton.isHidden && viewer.nextButton.isHidden)
    }

    @Test(arguments: [CGSize(width: 420, height: 292), CGSize(width: 1100, height: 760)])
    func testPreviewNavigationKeepsCanvasLayoutAndWheelOwnership(size: CGSize) async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        try writeImage("2.png")
        let viewer = ImageViewerController()
        let window = makeWindow(viewer, size: size)
        defer { viewer.closeLibrary(); window.close() }
        #expect(viewer.view.bounds.size == size)
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                           wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: cgEvent))
        for showsThumbnails in [true, false] {
            if viewer.showsThumbnails != showsThumbnails { viewer.toggleThumbnails() }
            viewer.view.layoutSubtreeIfNeeded()
            let canvasFrame = viewer.canvas.frame
            #expect(canvasFrame.width == viewer.view.bounds.width)
            #expect(canvasFrame.height == viewer.view.bounds.height - (showsThumbnails ? ThumbnailStripController.height : 0))
            #expect(viewer.previousButton.frame.minX == canvasFrame.minX + 16)
            #expect(viewer.nextButton.frame.maxX == canvasFrame.maxX - 16)
            for button in [viewer.previousButton, viewer.nextButton] {
                #expect(!button.isHiddenOrHasHiddenAncestor)
                #expect(button.frame.size == CGSize(width: 44, height: 44))
                #expect(button.frame.midY == canvasFrame.midY)
                let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
                #expect(viewer.view.hitTest(center) === button)
                // 按钮之外仍由画布接收点击；左右边缘不能残留整条导航的命中区域。
                let outside = CGPoint(x: center.x, y: button.frame.maxY + 8)
                #expect(viewer.view.hitTest(outside) === viewer.canvas)
                let scale = viewer.canvas.geometry.scale
                let scrollX = viewer.thumbnailStrip.scrollView.contentView.bounds.minX
                button.scrollWheel(with: wheel)
                #expect(viewer.canvas.geometry.scale > scale)
                #expect(viewer.thumbnailStrip.scrollView.contentView.bounds.minX == scrollX)
                #expect(viewer.canvas.frame == canvasFrame)
            }
        }
    }

    @Test
    func testSearchDebouncesNavigatesDuplicatesAndKeepsTextFocus() async throws {
        _ = NSApplication.shared
        let first = try writeImage("0.png")
        let match = try writeImage("相册 IMG.png")
        let duplicate = try makeFile("sub/相册 IMG.png", data: Data(contentsOf: match))
        let viewer = ImageViewerController()
        let window = makeWindow(viewer)
        defer { viewer.closeLibrary(); window.close() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        let original = viewer.images
        viewer.showSearch()
        #expect(!viewer.searchBar.previousMatchButton.isEnabled && !viewer.searchBar.nextMatchButton.isEnabled)
        viewer.setSearchQuery("old query")
        viewer.setSearchQuery("相册 img")
        viewer.navigateSearch(by: 1) // 回车早于防抖完成时，应在本次查询完成后定位一次。
        try await waitUntil { !viewer.isSearching && !viewer.isLoading }
        // 同名项按完整路径排序，ASCII 的 sub/ 排在中文文件名前面。
        #expect(viewer.searchMatches == [duplicate, match])
        #expect(viewer.currentURL == duplicate && viewer.isEditingText)
        #expect(viewer.searchBar.previousMatchButton.isEnabled && viewer.searchBar.nextMatchButton.isEnabled)
        viewer.searchBar.nextMatchButton.performClick(nil)
        #expect(viewer.currentURL == match && viewer.isEditingText)
        viewer.navigateSearch(by: 1)
        #expect(viewer.currentURL == duplicate)
        viewer.searchBar.previousMatchButton.performClick(nil)
        #expect(viewer.currentURL == match && viewer.images == original)
        viewer.setSearchQuery("missing")
        try await waitUntil { !viewer.isSearching }
        #expect(viewer.searchMatches.isEmpty && viewer.searchBar.status == "未找到")
        #expect(!viewer.searchBar.previousMatchButton.isEnabled && !viewer.searchBar.nextMatchButton.isEnabled)
        viewer.searchBar.nextMatchButton.performClick(nil)
        #expect(viewer.currentURL == match)
        let editor = try #require(viewer.searchBar.searchField.currentEditor() as? NSTextView)
        #expect(viewer.searchBar.control(viewer.searchBar.searchField, textView: editor,
                                         doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!viewer.isSearchVisible && window.firstResponder === viewer.canvas)
    }

    @Test
    func testChineseCompositionKeepsReturnForInputMethod() throws {
        _ = NSApplication.shared
        let bar = ImageSearchBar(frame: CGRect(x: 0, y: 0, width: 420, height: 40))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        defer { window.close() }
        var queries: [String] = []
        bar.onQueryChanged = { queries.append($0) }
        window.makeFirstResponder(bar.searchField)
        let editor = try #require(bar.searchField.currentEditor() as? NSTextView)
        editor.setMarkedText("相册", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        #expect(queries.isEmpty)
        #expect(!bar.control(bar.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        editor.unmarkText()
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        #expect(queries.last == "相册")
    }

    @Test
    func testNewScanSnapshotUsesLatestSortAndSearchWithoutChangingSelection() async throws {
        _ = NSApplication.shared
        let one = try writeImage("image1.png")
        let two = try writeImage("image2.png")
        let ten = try writeImage("image10.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([two])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.canvas.rotate(clockwise: false)
        let orientation = viewer.canvas.geometry.orientation
        viewer.showSearch()
        viewer.setSearchQuery("image")
        viewer.setSort(.nameDescending)
        // 模拟扫描结束时到达的旧排序快照；它不能覆盖用户刚选的新排序或旧查询结果。
        viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [one, two, ten], preferredImage: one,
                                     isComplete: true, skippedPaths: 0), sortedBy: .nameAscending)
        try await waitUntil { !viewer.isSorting && !viewer.isSearching }
        #expect(viewer.images == [ten, two, one] && viewer.searchMatches == viewer.images)
        #expect(viewer.currentURL == two && viewer.canvas.geometry.orientation == orientation)
    }

    @Test
    func testScopeStaysAtOriginalRootAndPreferencesSurviveWindowClose() async throws {
        _ = NSApplication.shared
        let first = try writeImage("root.png")
        let nested = try makeFile("sub/nested.png", data: Data(contentsOf: first))
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([fixtureDirectory])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.selectImage(nested)
        try await waitUntil { !viewer.isLoading }
        let strip = viewer.thumbnailStrip
        let nestedIndex = try #require(viewer.images.firstIndex(of: nested))
        let nestedItem = try #require(strip.collectionView(strip.collectionView,
            itemForRepresentedObjectAt: IndexPath(item: nestedIndex, section: 0)) as? ThumbnailItem)
        #expect(!nestedItem.directoryBadge.isHidden)
        #expect(nestedItem.view.toolTip == "子目录：sub\n完整路径：\(nested.path)")
        viewer.setIncludesSubdirectories(false)
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }
        #expect(viewer.images == [first] && viewer.currentURL == first)
        viewer.setIncludesSubdirectories(true)
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.images.contains(nested) && viewer.currentURL == first)
        viewer.setSort(.nameDescending)
        try await waitUntil { !viewer.isSorting }
        let sortedIndex = try #require(viewer.images.firstIndex(of: nested))
        let sortedItem = try #require(strip.collectionView(strip.collectionView,
            itemForRepresentedObjectAt: IndexPath(item: sortedIndex, section: 0)) as? ThumbnailItem)
        #expect(!sortedItem.directoryBadge.isHidden)
        #expect(sortedItem.view.toolTip == "子目录：sub\n完整路径：\(nested.path)")
        viewer.setIncludesSubdirectories(false)
        try await waitUntil { !viewer.isScanning }
        viewer.closeLibrary()
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(!viewer.libraryOptions.includesSubdirectories && viewer.libraryOptions.sort == .nameDescending)
        #expect(viewer.images == [first])
    }

    @Test
    func testOpeningDifferentRootWithSameImagesRefreshesThumbnailSources() async throws {
        _ = NSApplication.shared
        let nested = fixtureDirectory.appendingPathComponent("旅行/杭州", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let url = try writeImage("旅行/杭州/同名.png")
        let viewer = ImageViewerController()
        let window = makeWindow(viewer)
        defer { viewer.closeLibrary(); window.close() }

        // 三次扫描的列表完全相同，查看器仍必须传递每次打开的根目录，而非当前图片所在目录。
        for (root, relativeDirectory) in [(fixtureDirectory, "旅行/杭州"), (nested, ""),
                                          (nested.deletingLastPathComponent(), "杭州")] {
            viewer.open([root])
            try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
            viewer.view.layoutSubtreeIfNeeded()
            #expect(viewer.images == [url] && viewer.currentURL == url)
            let strip = viewer.thumbnailStrip
            let item = try #require(strip.collectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailItem)
            #expect(item.directoryBadge.isHidden == relativeDirectory.isEmpty)
            let tooltip = relativeDirectory.isEmpty ? url.path : "子目录：\(relativeDirectory)\n完整路径：\(url.path)"
            #expect(item.view.toolTip == tooltip && item.view.accessibilityHelp() == tooltip)
            #expect(item.isSelected && strip.view.frame.height == 112)
        }
    }

    @Test
    func testSortingDoesNotScanForNewFilesAndRefreshRetainsCurrentView() async throws {
        _ = NSApplication.shared
        let first = try writeImage("a.png")
        let second = try writeImage("b.png")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: second.path)
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.canvas.rotate(clockwise: true)
        viewer.canvas.zoom(by: 2)
        let before = viewer.canvas.geometry
        let added = try writeImage("added.png")
        viewer.setSort(.modifiedNewest)
        try await waitUntil { !viewer.isSorting }
        #expect(viewer.images == [second, first] && viewer.currentURL == first)
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }
        #expect(viewer.images == [added, second, first] && viewer.currentURL == first)
        #expect(viewer.canvas.geometry.orientation == before.orientation && viewer.canvas.geometry.scale == before.scale)
    }

    @Test
    func testReloadUpdatesMainThumbnailAndMetadataAndPreservesSameSizeView() async throws {
        _ = NSApplication.shared
        let url = try writeImage("image.png")
        let decoder = ImageDecoder()
        let viewer = ImageViewerController(decoder: decoder)
        defer { viewer.closeLibrary() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.view.layoutSubtreeIfNeeded()
        viewer.toggleInfo()
        try await waitUntil { viewer.infoCard.metadata != nil && viewer.thumbnailStrip.pendingRequestCount == 0 }
        viewer.canvas.rotate(clockwise: true)
        viewer.canvas.zoom(by: 2)
        let before = viewer.canvas.geometry
        try writeImage("image.png", red: 0, blue: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: url.path)
        let expected = try ImageMetadata.read(url, isCancelled: { false })
        viewer.reloadCurrentImage()
        try await waitUntil {
            !viewer.isLoading && viewer.infoCard.metadata == expected && viewer.thumbnailStrip.pendingRequestCount == 0
        }
        let displayed = try #require(viewer.canvas.layer?.sublayers?.first?.contents as! CGImage?)
        #expect(try testPixels(displayed)[2] > 240 && testPixels(displayed)[0] < 20)
        #expect(viewer.canvas.geometry.orientation == before.orientation && viewer.canvas.geometry.scale == before.scale)
        let item = try #require(viewer.thumbnailStrip.collectionView(viewer.thumbnailStrip.collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as? ThumbnailItem)
        let thumbnail = try #require(item.imageView?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(try testPixels(thumbnail)[2] > 240 && testPixels(thumbnail)[0] < 20)

        try writeImage("image.png", width: 40, height: 80)
        viewer.reloadCurrentImage()
        try await waitUntil { !viewer.isLoading && viewer.canvas.geometry.imageSize == CGSize(width: 40, height: 80) }
        #expect(viewer.canvas.geometry.orientation == before.orientation && viewer.canvas.geometry.mode == .fit)
    }

    @Test
    func testFailedReloadKeepsLastImageAndCanRecover() async throws {
        _ = NSApplication.shared
        let url = try writeImage("image.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.canvas.rotate(clockwise: true)
        let before = viewer.canvas.geometry
        try Data("damaged".utf8).write(to: url)
        viewer.reloadCurrentImage()
        try await waitUntil { !viewer.isLoading }
        #expect(viewer.hasImage && viewer.canvas.geometry.orientation == before.orientation)
        #expect(viewer.canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("重新载入失败") })
        try writeImage("image.png", width: 160, height: 80)
        viewer.reloadCurrentImage()
        try await waitUntil { !viewer.isLoading && viewer.canvas.geometry.imageSize.width == 160 }
    }

    @Test
    func testDirectoryRefreshRemovesMissingSelectionAndRetainsSessionOnFailure() async throws {
        _ = NSApplication.shared
        let selected = try writeImage("2.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([selected])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        let added = try writeImage("1.png")
        try FileManager.default.removeItem(at: selected)
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }
        #expect(viewer.images == [added] && viewer.currentURL == added && viewer.hasImage)
        let moved = fixtureDirectory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixtureDirectory, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: fixtureDirectory) }
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.images == [added] && viewer.currentURL == added && viewer.hasImage)
        #expect(!viewer.isRefreshing)
        #expect(viewer.canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("刷新失败") })
    }

    @Test(arguments: ["switch", "close"])
    func testLateMetadataCannotReplaceCurrentCard(action: String) async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try writeImage("2.png")
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder(metadataLoader: { url, _ in
            if url == first {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                finished.signal()
            }
            return ImageMetadata(fields: [.init(name: "文件", value: url.lastPathComponent)])
        })
        let viewer = ImageViewerController(decoder: decoder)
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.toggleInfo()
        try await waitFor([started], timeout: 2)
        if action == "switch" {
            viewer.toggleInfo()
            viewer.selectImage(second)
            viewer.toggleInfo()
        } else {
            viewer.closeLibrary()
        }
        gate.signal()
        try await waitFor([finished], timeout: 2)
        if action == "switch" {
            try await waitUntil { viewer.infoCard.metadata?.fields.first?.value == "2.png" }
            #expect(viewer.currentURL == second)
        } else {
            #expect(!viewer.showsInfo && viewer.infoCard.metadata == nil && viewer.currentURL == nil)
        }
    }

    @Test
    func testRefreshRestartsGIFFromFirstFrameAndKeepsDirection() async throws {
        _ = NSApplication.shared
        let url = try writeGIF(delays: [0.02, 0.02, 0.02])
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([url])
        try await waitUntil { viewer.playback.currentStep >= 2 }
        viewer.setWindowVisible(false)
        viewer.canvas.rotate(clockwise: true)
        let direction = viewer.canvas.geometry.orientation
        viewer.reloadCurrentImage()
        try await waitUntil { !viewer.isLoading }
        #expect(viewer.playback.currentStep == 0 && viewer.canvas.geometry.orientation == direction)
        #expect(!viewer.playback.isPlaying)
    }

    @Test(arguments: [CGSize(width: 420, height: 292), CGSize(width: 420, height: 320)])
    func testOverlaysFitSmallWindowAndDoNotChangeCanvasGeometry(size: CGSize) async throws {
        _ = NSApplication.shared
        let url = try writeImage("image.png")
        let viewer = ImageViewerController()
        let window = makeWindow(viewer, size: size)
        defer { viewer.closeLibrary(); window.close() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.view.layoutSubtreeIfNeeded()
        let original = viewer.canvas.frame
        viewer.showSearch()
        viewer.toggleInfo()
        viewer.view.layoutSubtreeIfNeeded()
        #expect(viewer.canvas.frame == original)
        #expect(viewer.canvas.frame.contains(viewer.infoCard.frame))
        #expect(viewer.canvas.frame.contains(viewer.searchBar.frame))
        #expect(!viewer.searchBar.frame.intersects(viewer.infoCard.frame))
        #expect(viewer.infoCard.frame.height > 60)
        #expect(viewer.searchBar.searchField.frame.width >= 100)
        #expect(viewer.searchBar.subviews.allSatisfy { viewer.searchBar.bounds.contains($0.frame) })
        // 小窗口的信息卡会覆盖右侧导航，重叠处必须优先操作信息内容。
        let nextCenter = CGPoint(x: viewer.nextButton.frame.midX, y: viewer.nextButton.frame.midY)
        let hit = try #require(viewer.view.hitTest(nextCenter))
        #expect(hit === viewer.infoCard || hit.isDescendant(of: viewer.infoCard))
        // 信息卡关闭后继续编辑原查询；点击画布后 Esc 仍能逐层收起浮层。
        viewer.toggleInfo()
        #expect(viewer.isEditingText && viewer.isSearchVisible)
        viewer.toggleInfo()
        window.makeFirstResponder(viewer.canvas)
        viewer.canvas.cancelOperation(nil)
        #expect(!viewer.isSearchVisible && viewer.showsInfo)
        viewer.canvas.cancelOperation(nil)
        #expect(!viewer.showsInfo && window.firstResponder === viewer.canvas)
    }

    @Test
    func testScopeCanEmptyLibraryAndRestoreItWithoutLosingRoot() async throws {
        _ = NSApplication.shared
        let template = try writeImage("template.png")
        let nested = try makeFile("sub/only.png", data: Data(contentsOf: template))
        try FileManager.default.removeItem(at: template)
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([fixtureDirectory])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(!viewer.previousButton.isHidden && !viewer.nextButton.isHidden)
        #expect(!viewer.previousButton.isEnabled && !viewer.nextButton.isEnabled)
        viewer.toggleInfo()
        viewer.setIncludesSubdirectories(false)
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.images.isEmpty && !viewer.hasImage && !viewer.isThumbnailStripVisible)
        #expect(viewer.previousButton.isHidden && viewer.nextButton.isHidden)
        #expect(viewer.currentURL == nil && viewer.canRefreshDirectory)
        #expect(viewer.infoCard.metadata == nil && viewer.infoCard.text == "未选择图片")
        viewer.setIncludesSubdirectories(true)
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(viewer.currentURL == nested)
        #expect(!viewer.previousButton.isHidden && !viewer.nextButton.isHidden)
        #expect(!viewer.previousButton.isEnabled && !viewer.nextButton.isEnabled)
    }

    @Test
    func testInvalidOpenRestoresPendingScopeAndFinishesRequestedSort() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let nested = try makeFile("sub/2.png", data: Data(contentsOf: first))
        let invalid = try makeFile("notes.txt")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.setSort(.nameDescending)
        viewer.setIncludesSubdirectories(false)
        viewer.open([invalid])
        try await waitUntil { !viewer.isScanning && !viewer.isSorting }
        #expect(viewer.libraryOptions.includesSubdirectories)
        #expect(viewer.images == [nested, first] && viewer.currentURL == first && viewer.hasImage)
    }

    private func makeWindow(_ viewer: ImageViewerController, size: CGSize = CGSize(width: 500, height: 400)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        // 离屏窗口尚未经过 WindowServer 的尺寸同步，显式设置才能真正覆盖最小窗口布局。
        viewer.view.frame.size = size
        return window
    }
}
