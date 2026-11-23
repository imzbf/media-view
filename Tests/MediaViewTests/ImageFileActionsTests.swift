import AppKit
import Testing
@testable import MediaView

@Suite(.serialized)
@MainActor
final class ImageFileActionsTests: FixtureTestCase {
    @Test(arguments: [false, true])
    func testCopyUsesOriginalFileAndPreservesPasteboardWhenUnavailable(corrupt: Bool) async throws {
        _ = NSApplication.shared
        let url = corrupt ? try makeFile("损坏 图片.png", data: Data("invalid image".utf8))
                          : try writeGIF("相册 图片.gif")
        let viewer = MediaViewerController()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { viewer.closeLibrary(); pasteboard.releaseGlobally() }
        pasteboard.setString("原有剪贴板", forType: .string)
        let changeCount = pasteboard.changeCount
        #expect(!viewer.copyCurrentImage(to: pasteboard))
        viewer.open([url])
        #expect(!viewer.copyCurrentImage(to: pasteboard))
        #expect(pasteboard.changeCount == changeCount)
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }

        // 复制不依赖解码成功，也不能把 GIF 变成当前帧或屏幕尺寸的位图。
        #expect(viewer.hasImage == !corrupt)
        viewer.canvas.rotate(clockwise: true)
        #expect(viewer.copyCurrentImage(to: pasteboard))
        let copied = pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(copied == [url])
        #expect(pasteboard.pasteboardItems?.count == 1)
        let item = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(viewer.validateMenuItem(item))
        viewer.closeLibrary()
        #expect(!viewer.validateMenuItem(item))
    }

    @Test
    func testCopyResponderKeepsTextEditingNative() async throws {
        _ = NSApplication.shared
        let url = try writeImage("image.png")
        let viewer = MediaViewerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        defer { viewer.closeLibrary(); window.close() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }

        func copyTarget() -> NSResponder? {
            var responder = window.firstResponder
            while let candidate = responder {
                if candidate.responds(to: #selector(NSText.copy(_:))) { return candidate }
                responder = candidate.nextResponder
            }
            return nil
        }
        window.makeFirstResponder(viewer.canvas)
        #expect(copyTarget() === viewer)
        viewer.showSearch()
        viewer.setSearchQuery("image")
        let editor = try #require(viewer.searchBar.searchField.currentEditor())
        #expect(copyTarget() === editor, "Text copy must not fall through to the image file action")
        viewer.hideSearch()
        #expect(copyTarget() === viewer)
    }

    @Test(arguments: [0, 1, 2])
    func testTrashSelectsAdjacentImageAndUpdatesOverlays(index: Int) async throws {
        _ = NSApplication.shared
        let urls = try (1...3).map { try writeImage("image\($0).png") }
        let trash = try localTrashDirectory()
        let viewer = MediaViewerController(trashItem: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        defer { viewer.closeLibrary() }
        viewer.open([urls[index]])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.showSearch()
        viewer.setSearchQuery("image")
        viewer.toggleInfo()
        viewer.canvas.rotate(clockwise: true)
        let original = try Data(contentsOf: urls[index])

        viewer.trashCurrentImage()
        #expect(viewer.isTrashing && !viewer.canTrashImage && !viewer.canCopyImage)
        #expect(!viewer.canRefreshDirectory && !viewer.canChangeLibraryOptions)
        var remaining = urls
        remaining.remove(at: index)
        let selected = remaining[min(index, remaining.count - 1)]
        try await waitUntil {
            !viewer.isTrashing && !viewer.isLoading && !viewer.isSearching
                && viewer.infoCard.metadata?.fields.first?.value == selected.lastPathComponent
        }
        #expect(viewer.images == remaining && viewer.currentURL == selected)
        #expect(viewer.thumbnailStrip.images == remaining && viewer.thumbnailStrip.selectedURL == selected)
        #expect(viewer.searchMatches == remaining && viewer.canvas.geometry.orientation == .identity)
        #expect(!FileManager.default.fileExists(atPath: urls[index].path))
        #expect(try Data(contentsOf: trash.appendingPathComponent(urls[index].lastPathComponent)) == original)
        #expect(viewer.canTrashImage && viewer.canRefreshDirectory && viewer.canChangeLibraryOptions)
    }

    @Test
    func testTrashingOnlyGIFClearsPlaybackAndPreservesDirectory() async throws {
        _ = NSApplication.shared
        let url = try writeGIF("only.gif")
        let trash = try localTrashDirectory()
        let viewer = MediaViewerController(trashItem: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        defer { viewer.closeLibrary() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.playback.isPlaying }
        viewer.toggleInfo()
        viewer.showSearch()
        viewer.setSearchQuery("only")
        viewer.trashCurrentImage()
        try await waitUntil { !viewer.isTrashing && !viewer.isSearching }
        #expect(viewer.images.isEmpty && viewer.currentURL == nil && !viewer.hasImage)
        #expect(!viewer.isLoading && viewer.playback.animation == nil && !viewer.playback.isPlaying)
        #expect(viewer.thumbnailStrip.images.isEmpty && !viewer.isThumbnailStripVisible)
        #expect(viewer.searchMatches.isEmpty && viewer.infoCard.text == "未选择文件")
        #expect(!viewer.canCopyImage && !viewer.canTrashImage && viewer.canRefreshDirectory)

        let added = try writeImage("new.png")
        viewer.refreshDirectory()
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(viewer.images == [added] && viewer.currentURL == added)
    }

    @Test
    func testTrashFailurePreservesFileSelectionAndView() async throws {
        _ = NSApplication.shared
        let url = try writeImage("image.png")
        let viewer = MediaViewerController(trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        defer { viewer.closeLibrary() }
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.canvas.rotate(clockwise: true)
        viewer.canvas.zoom(by: 2)
        let geometry = viewer.canvas.geometry
        viewer.trashCurrentImage()
        try await waitUntil { !viewer.isTrashing }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(viewer.images == [url] && viewer.currentURL == url && viewer.hasImage)
        #expect(viewer.thumbnailStrip.selectedURL == url)
        #expect(viewer.canvas.geometry.orientation == geometry.orientation && viewer.canvas.geometry.scale == geometry.scale)
        #expect(viewer.canTrashImage)
        #expect(viewer.canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            .contains { $0.contains("删除失败") && $0.contains(url.lastPathComponent) })
    }

    @Test(arguments: ["select", "open", "close"])
    func testLateTrashPreservesNewSelectionOrSession(action: String) async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try writeImage("2.png")
        let other = try makeFile("other/new.png", data: Data(contentsOf: first))
        let trash = try localTrashDirectory()
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let viewer = MediaViewerController(trashItem: { url in
            started.signal()
            // 系统移动进入磁盘调用后不可取消，迟到成功仍只能影响最初指定的文件。
            _ = gate.wait(timeout: .now() + 5)
            defer { finished.signal() }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.trashCurrentImage()
        try await waitFor([started], timeout: 2)
        switch action {
        case "select":
            viewer.selectImage(second)
            try await waitUntil { viewer.hasImage }
        case "open":
            viewer.open([other])
            try await waitUntil { !viewer.isScanning && viewer.hasImage }
        default:
            viewer.closeLibrary()
        }
        gate.signal()
        try await waitFor([finished], timeout: 2)
        try await waitUntil { !viewer.isTrashing }
        // 给已经开始且无法取消的文件移动结果一次回到主线程的机会。
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        switch action {
        case "select":
            #expect(viewer.currentURL == second && !viewer.images.contains(first))
            #expect(viewer.thumbnailStrip.selectedURL == second)
        case "open":
            #expect(viewer.images == [other] && viewer.currentURL == other && viewer.hasImage)
        default:
            #expect(viewer.images.isEmpty && viewer.currentURL == nil && !viewer.hasImage)
        }
    }

    @Test
    func testTrashWaitsForScanAndSortSnapshots() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try writeImage("2.png")
        let calls = DecodeRecorder()
        let viewer = MediaViewerController(trashItem: { calls.record($0) })
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [first, second], preferredImage: first,
                                     isComplete: false, skippedPaths: 0))
        #expect(viewer.canCopyImage && !viewer.canTrashImage)
        viewer.trashCurrentImage()
        viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [first, second], preferredImage: first,
                                     isComplete: true, skippedPaths: 0))
        viewer.setSort(.nameDescending)
        #expect(viewer.isSorting && !viewer.canTrashImage)
        viewer.trashCurrentImage()
        try await waitUntil { !viewer.isSorting }
        #expect(calls.urls.isEmpty && viewer.canTrashImage)
        #expect(viewer.images == [second, first] && viewer.currentURL == first)
    }

    /// 成功路径模拟移动到被忽略的测试目录，避免测试污染用户的系统废纸篓。
    private func localTrashDirectory() throws -> URL {
        let trash = fixtureDirectory.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return trash
    }
}
