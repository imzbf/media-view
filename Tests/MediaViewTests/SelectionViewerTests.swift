import AppKit
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class SelectionViewerTests: FixtureTestCase {
    private func makeViewer(store: SelectionStore? = nil, decoder: ImageDecoder = ImageDecoder()) -> MediaViewerController {
        _ = NSApplication.shared
        return MediaViewerController(decoder: decoder,
            selectionStore: store ?? SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records")))
    }

    private func start(_ viewer: MediaViewerController, opening url: URL) async throws {
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }
        viewer.startSelection()
        try await waitUntil { viewer.selection != nil && !viewer.isSelectionStarting && !viewer.isScanning && !viewer.isLoading }
    }

    @Test
    func testPickSkipUndoGridReviewExportAndReopen() async throws {
        let a = try writeImage("1.png")
        let b = try writeImage("2.png")
        let c = try writeImage("3.png")
        try makeFile("video.mp4")
        let store = SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records"))
        let viewer = makeViewer(store: store)
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: a)
        let session = try #require(viewer.selection)
        #expect(viewer.images == [a, b, c] && viewer.canMarkSelection)
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == b && viewer.hasImage && !viewer.isLoading }
        #expect(session.status(of: a) == .picked && viewer.thumbnailStrip.images == [b, c])
        viewer.markSelection(.skipped)
        try await waitUntil { viewer.currentURL == c && viewer.hasImage && !viewer.isLoading }
        viewer.undo(nil)
        try await waitUntil { viewer.currentURL == b && viewer.hasImage && !viewer.isLoading }
        #expect(session.status(of: b) == .pending)
        viewer.redo(nil)
        try await waitUntil { viewer.currentURL == c && viewer.hasImage && !viewer.isLoading }
        viewer.markSelection(.picked)
        #expect(viewer.currentURL == nil && !viewer.selectionEmpty.isHidden)
        session.setFilter(.picked)
        #expect(session.showsGrid && viewer.canvas.isHidden && !viewer.selectionGrid.view.isHidden)
        #expect(!viewer.canCopyImage && !viewer.canTrashImage, "Grid focus must not operate on a stale viewer URL")
        #expect(viewer.selectionGrid.urls == [a, c])
        session.openPhoto(c)
        try await waitUntil { viewer.currentURL == c && viewer.hasImage && !viewer.isLoading }
        #expect(!viewer.canvas.isHidden && viewer.selectionHeader.backButton.isHidden == false)
        session.mark(.pending, url: c)
        #expect(viewer.images == [a] && session.status(of: c) == .pending)
        let output = fixtureDirectory.appendingPathComponent(".export")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        viewer.exportSelection(to: output)
        try await waitUntil { !viewer.isExportingSelection }
        let exported = try #require(viewer.lastSelectionExport)
        #expect(exported.copied.count == 1 && exported.failures.isEmpty)
        #expect(try Data(contentsOf: exported.copied[0]) == Data(contentsOf: a))
        #expect(session.status(of: a) == .picked, "Export must not clear the user's selection")
        session.setFilter(.pending)
        #expect(await viewer.prepareForLibraryDeparture())
        viewer.closeLibrary()
        try await start(viewer, opening: a)
        #expect(viewer.selection?.status(of: a) == .picked && viewer.selection?.status(of: b) == .skipped)
        #expect(viewer.currentURL == c)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testSelectionUsesFullRootAndRestoresNormalScopeAfterSortingAndRefresh() async throws {
        let a = try writeImage("1.png")
        try makeFile("nested/3.png")
        let nested = try writeImage("nested/3.png")
        let b = try writeImage("2.png")
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        viewer.setIncludesSubdirectories(false)
        try await start(viewer, opening: a)
        let session = try #require(viewer.selection)
        #expect(viewer.images == [a, b, nested] && viewer.libraryOptions.includesSubdirectories)
        viewer.setIncludesSubdirectories(false)
        #expect(viewer.libraryOptions.includesSubdirectories)
        session.mark(.picked, url: nested)
        session.setFilter(.picked)
        viewer.setSort(.nameDescending)
        try await waitUntil { !viewer.isSorting }
        #expect(viewer.images == [nested] && session.counts.all == 3)
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.images == [nested] && session.counts.all == 3)
        session.setFilter(.all)
        #expect(viewer.images == [nested, b, a], "Sorting a filtered view must retain the full source list")
        viewer.endSelection()
        try await waitUntil { viewer.selection == nil && !viewer.isScanning }
        #expect(!viewer.libraryOptions.includesSubdirectories && viewer.images == [b, a])
    }

    @Test
    func testLoadingRepeatKeysAndTextEditingCannotMarkTheWrongPhoto() async throws {
        let a = try writeImage("1.png")
        let b = try writeImage("2.png")
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let decoder = ImageDecoder(cacheCapacity: 0, loader: { request, cancelled in
            if case .mainImage(let url, _) = request, url == b {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            return try ImageDecoder.decode(request, isCancelled: cancelled)
        })
        let viewer = makeViewer(decoder: decoder)
        let window = makeWindow(viewer, size: CGSize(width: 800, height: 650))
        defer { viewer.closeLibrary(); window.close() }
        try await start(viewer, opening: a)
        let session = try #require(viewer.selection)
        viewer.markSelection(.picked)
        try await waitFor([started], timeout: 3)
        #expect(viewer.isLoading && !viewer.canMarkSelection)
        viewer.markSelection(.picked)
        #expect(session.status(of: b) == .pending)
        gate.signal()
        try await waitUntil { viewer.hasImage && !viewer.isLoading }
        window.makeFirstResponder(viewer.canvas)
        #expect(viewer.handleSelectionKey(try key("p", repeatKey: true)))
        #expect(session.status(of: b) == .pending)
        viewer.showSearch()
        try #require(viewer.isEditingText)
        #expect(!viewer.handleSelectionKey(try key("x")))
        #expect(session.status(of: b) == .pending)
        viewer.hideSearch()
        #expect(!viewer.handleSelectionKey(try key("p", modifiers: .command)))
        #expect(viewer.handleSelectionKey(try key("x")))
        #expect(session.status(of: b) == .skipped && viewer.currentURL == nil)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testLeavingGridRestoresPreviewAndClosingRestoresBrowsingScope() async throws {
        let a = try writeImage("1.png")
        let b = try writeImage("2.png")
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: a)
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == b && viewer.hasImage && !viewer.isLoading }
        viewer.selection?.setFilter(.picked)
        #expect(viewer.currentURL == a && !viewer.hasImage)
        viewer.endSelection()
        try await waitUntil { viewer.selection == nil && viewer.hasImage && !viewer.isLoading }
        #expect(viewer.currentURL == a && !viewer.canvas.isHidden)
        viewer.setIncludesSubdirectories(false)
        try await waitUntil { !viewer.isScanning }
        viewer.startSelection()
        try await waitUntil { viewer.selection != nil && !viewer.isSelectionStarting && !viewer.isScanning }
        #expect(viewer.libraryOptions.includesSubdirectories)
        #expect(await viewer.prepareForLibraryDeparture())
        viewer.closeLibrary()
        #expect(!viewer.libraryOptions.includesSubdirectories)
    }

    @Test
    func testFailedSavePreventsDepartureAndPreservesRecordForRetry() async throws {
        let a = try writeImage("photo.png")
        let failure = SelectionWriteFailure()
        failure.enabled = true
        let store = SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records"), writer: { data, url in
            if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let viewer = makeViewer(store: store)
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: a)
        viewer.markSelection(.picked)
        #expect(!(await viewer.prepareForLibraryDeparture()))
        #expect(viewer.selection?.status(of: a) == .picked && !viewer.isSelectionTransition)
        #expect(!viewer.selectionHeader.retryButton.isHidden)
        failure.enabled = false
        #expect(await viewer.prepareForLibraryDeparture())
        #expect(try await store.load(root: fixtureDirectory).marks["photo.png"] == .picked)
    }

    @Test
    func testRefreshShowsMissingPickedPhotoWithoutSilentlyRemovingIt() async throws {
        let a = try writeImage("a.png")
        let b = try writeImage("b.png")
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: a)
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == b && !viewer.isLoading }
        try FileManager.default.removeItem(at: a)
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning }
        let session = try #require(viewer.selection)
        session.setFilter(.picked)
        #expect(session.pickedURLs == [a] && session.missingURLs.contains(a))
        #expect(viewer.selectionGrid.urls == [a] && viewer.canExportSelection)
        #expect(viewer.selectionHeader.progressLabel.stringValue.contains("1 张入选文件缺失"))
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test(arguments: [false, true])
    func testUnchangedSelectionListDoesNotStrandPendingSearch(sort: Bool) async throws {
        let photo = try writeImage("photo.png")
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: photo)
        viewer.showSearch()
        viewer.setSearchQuery("photo")
        // 搜索尚在防抖等待中，刷新或排序改变了图库版本，但没有改变可见照片。
        if sort {
            viewer.setSort(.nameDescending)
        } else {
            viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [photo], preferredImage: nil,
                isComplete: true, skippedPaths: 0))
        }
        try await waitUntil { !viewer.isSearching && !viewer.isSorting }
        #expect(viewer.searchMatches == [photo])
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test(arguments: [false, true])
    func testDecoderResetRestartsInterruptedGridThumbnails(refresh: Bool) async throws {
        let photo = try writeImage("photo.png")
        let invalid = try makeFile("notes.txt")
        let started = TestSignal()
        let interrupted = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let recorder = DecodeRecorder()
        let bitmap = try testBitmap()
        let decoder = ImageDecoder(loader: { request, cancelled in
            if case .thumbnail = request {
                recorder.record(request.url)
                if recorder.urls.count == 1 {
                    started.signal()
                    let deadline = Date().addingTimeInterval(5)
                    while !cancelled(), Date() < deadline {
                        if gate.wait(timeout: .now() + 0.01) == .success { break }
                    }
                    if cancelled() { interrupted.signal() }
                }
            }
            return DecodedImage(image: bitmap, pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        })
        let viewer = makeViewer(decoder: decoder)
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.toggleThumbnails()
        try await start(viewer, opening: photo)
        viewer.markSelection(.picked)
        viewer.selection?.setFilter(.picked)
        try await waitFor([started], timeout: 3)
        // 刷新和无效输入都会重置解码器；原会话的请求登记也必须清除并重新加载。
        if refresh { viewer.refreshDirectory() } else { viewer.open([invalid]) }
        try await waitFor([interrupted], timeout: 3)
        try await waitUntil { await decoder.thumbnailCachedURLs.contains(photo) }
        #expect(recorder.urls.count >= 2)
        #expect(viewer.selection?.showsGrid == true && viewer.selectionGrid.urls == [photo])
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testChangingSelectionFilterRestartsPendingSearch() async throws {
        let first = try writeImage("photo-1.png")
        let second = try writeImage("photo-2.png")
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        try await start(viewer, opening: first)
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == second && !viewer.isLoading }
        viewer.showSearch()
        viewer.setSearchQuery("photo")
        viewer.selection?.setFilter(.all)
        try await waitUntil { !viewer.isSearching }
        #expect(viewer.searchMatches == [first, second])
        viewer.selection?.setFilter(.pending)
        try await waitUntil { !viewer.isSearching }
        #expect(viewer.searchMatches == [second], "隐藏照片不能继续留在查找结果中")
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test(arguments: [CGSize(width: 420, height: 292), CGSize(width: 420, height: 320),
                      CGSize(width: 700, height: 420), CGSize(width: 1100, height: 760)])
    func testControlsFitSmallWindowsAndStayOutsideCanvas(size: CGSize) async throws {
        let a = try writeImage("很长的照片文件名－旅行照片.png")
        let viewer = makeViewer()
        let window = makeWindow(viewer, size: size)
        defer { viewer.closeLibrary(); window.close() }
        try await start(viewer, opening: a)
        viewer.view.layoutSubtreeIfNeeded()
        viewer.selectionHeader.layoutSubtreeIfNeeded()
        viewer.selectionActions.layoutSubtreeIfNeeded()
        #expect(viewer.canvas.frame.height > 60)
        #expect(!viewer.canvas.frame.intersects(viewer.selectionHeader.frame))
        #expect(!viewer.canvas.frame.intersects(viewer.selectionActions.frame))
        for child in viewer.selectionHeader.subviews where !child.isHidden {
            #expect(viewer.selectionHeader.bounds.contains(child.frame))
        }
        for child in viewer.selectionActions.subviews where !child.isHidden {
            #expect(viewer.selectionActions.bounds.contains(child.frame))
        }
        #expect(viewer.isThumbnailStripVisible == (size.height >= 500))
        #expect(viewer.selectionActions.pickedButton.isEnabled)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testGridKeepsRequestsBoundedForFiveThousandPhotosAndPreservesScroll() async throws {
        let recorder = DecodeRecorder()
        let bitmap = try testBitmap()
        let decoder = ImageDecoder(loader: { request, _ in
            recorder.record(request.url)
            return DecodedImage(image: bitmap, pixelSize: CGSize(width: 80, height: 40), isFullResolution: false)
        })
        let grid = SelectionGridController(decoder: decoder)
        let urls = (0..<5000).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        grid.view.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        grid.update(urls: urls, missing: [])
        grid.view.layoutSubtreeIfNeeded()
        grid.setActive(true)
        defer { grid.setActive(false) }
        grid.refreshLoadWindow()
        try await waitUntil { !recorder.urls.isEmpty }
        #expect(!grid.requestedURLs.isEmpty && grid.requestedURLs.count < 100)
        let first = grid.requestedURLs
        grid.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 6000))
        grid.refreshLoadWindow()
        let y = grid.scrollView.contentView.bounds.minY
        #expect(grid.requestedURLs.isDisjoint(with: first) && grid.requestedURLs.count < 100)
        grid.setActive(false)
        grid.update(urls: urls, missing: [])
        grid.setActive(true)
        #expect(grid.scrollView.contentView.bounds.minY == y)
        #expect(grid.requestedURLs.count < 100)
    }

    private func makeWindow(_ viewer: MediaViewerController, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        viewer.view.frame.size = size
        viewer.view.layoutSubtreeIfNeeded()
        return window
    }

    private func key(_ text: String, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeatKey, keyCode: text == "p" ? 35 : 7))
    }
}
