import AppKit
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class DuplicateViewerTests: FixtureTestCase {
    private func makeViewer(trash: @escaping @Sendable (URL) throws -> Void = { _ in }) -> MediaViewerController {
        _ = NSApplication.shared
        return MediaViewerController(
            selectionStore: SelectionStore(directory: fixtureDirectory.appendingPathComponent(".selections")),
            duplicateStore: DuplicateStore(directory: fixtureDirectory.appendingPathComponent(".duplicates")), trashItem: trash)
    }

    private func start(_ viewer: MediaViewerController, url: URL) async throws {
        viewer.open([url])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading }
        viewer.startDuplicateCheck()
        try await waitUntil(timeout: 10) { viewer.duplicateReview?.session.hasCompleted == true && !viewer.isDuplicateStarting }
    }

    private func makeWindow(_ viewer: NSViewController, size: CGSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        viewer.view.frame.size = size
        viewer.view.layoutSubtreeIfNeeded()
        return window
    }

    @Test
    func testCheckIncludesSubdirectoriesAndRestoresBrowsingScopeAndPhoto() async throws {
        let photo = try writeDuplicatePhoto("original.jpg")
        try makeFile("other-phone/copy.jpg", data: Data(contentsOf: photo))
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        viewer.setIncludesSubdirectories(false)
        try await start(viewer, url: photo)
        let review = try #require(viewer.duplicateReview)
        #expect(review.session.groups.count == 1 && review.session.groups[0].files.count == 2)
        #expect(!viewer.libraryOptions.includesSubdirectories && viewer.images == [photo])
        #expect(!viewer.canCopyImage && !viewer.canTrashImage && !viewer.canMarkSelection && !viewer.canRefreshDirectory)
        viewer.endDuplicateCheck()
        try await waitUntil { viewer.duplicateReview == nil && !viewer.isSelectionTransition }
        #expect(viewer.currentURL == photo && viewer.hasImage && viewer.canCopyImage)
        #expect(!viewer.libraryOptions.includesSubdirectories)
    }

    @Test
    func testReturningFromReviewRestoresAccessibleBrowsingControls() async throws {
        let photo = try writeDuplicatePhoto("original.jpg")
        try makeFile("copy.jpg", data: Data(contentsOf: photo))
        let viewer = makeViewer()
        let window = makeWindow(viewer, size: CGSize(width: 1100, height: 760))
        defer { viewer.closeLibrary(); window.close() }
        try await start(viewer, url: photo)
        let review = try #require(viewer.duplicateReview)
        #expect(viewer.view.accessibilityChildren()?.contains { ($0 as? NSView) === review.view } == true)
        #expect(viewer.view.accessibilityChildren()?.contains { ($0 as? NSView) === viewer.canvas } == false)

        // 返回后不能只恢复视觉内容；读屏仍需发现画布，以及随后显示的选片控件。
        viewer.endDuplicateCheck()
        try await waitUntil { viewer.duplicateReview == nil && !viewer.isSelectionTransition }
        #expect(viewer.view.accessibilityChildren()?.contains { ($0 as? NSView) === viewer.canvas } == true)
        viewer.startSelection()
        try await waitUntil { viewer.selection != nil && !viewer.isSelectionStarting }
        #expect(viewer.view.accessibilityChildren()?.isEmpty == false)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testSelectionIsSuspendedWithoutLosingMarksOrRespondingToOldCommands() async throws {
        let first = try writeDuplicatePhoto("1.jpg")
        let second = try writeDuplicatePhoto("2.jpg", variant: 1)
        try makeFile("copy.jpg", data: Data(contentsOf: first))
        let calls = DecodeRecorder()
        let viewer = makeViewer(trash: { calls.record($0) })
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.startSelection()
        try await waitUntil { viewer.selection != nil && !viewer.isSelectionStarting }
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == second && !viewer.isLoading }
        let selection = try #require(viewer.selection)
        let before = selection.record
        viewer.startDuplicateCheck()
        try await waitUntil(timeout: 10) { viewer.duplicateReview?.session.hasCompleted == true }
        viewer.markSelection(.skipped)
        viewer.undo(nil)
        viewer.trashCurrentImage()
        viewer.navigate(by: 1)
        #expect(calls.urls.isEmpty && selection.record == before && viewer.currentURL == second)
        viewer.endDuplicateCheck()
        try await waitUntil { viewer.duplicateReview == nil && !viewer.isSelectionTransition }
        #expect(viewer.selection === selection && selection.record == before && viewer.currentURL == second)
        #expect(viewer.canMarkSelection)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testCleanupRefreshesOriginalLibraryAndPreservesMissingPickedRecord() async throws {
        let first = try writeDuplicatePhoto("1.jpg")
        let second = try makeFile("2.jpg", data: Data(contentsOf: first))
        let trash = fixtureDirectory.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let viewer = makeViewer(trash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.startSelection()
        try await waitUntil { viewer.selection != nil && !viewer.isSelectionStarting }
        viewer.markSelection(.picked)
        try await waitUntil { viewer.currentURL == second && !viewer.isLoading }
        viewer.startDuplicateCheck()
        try await waitUntil(timeout: 10) { viewer.duplicateReview?.session.hasCompleted == true }
        let duplicates = try #require(viewer.duplicateReview?.session)
        duplicates.keepOnly("2.jpg")
        duplicates.clean()
        try await waitUntil(timeout: 10) { duplicates.lastCleanup != nil && !duplicates.isBusy && duplicates.hasCompleted }
        viewer.endDuplicateCheck()
        try await waitUntil { viewer.duplicateReview == nil && !viewer.isScanning }
        #expect(viewer.selection?.status(of: first) == .picked)
        #expect(viewer.selection?.missingURLs == [first])
        #expect(viewer.currentURL == second && FileManager.default.fileExists(atPath: second.path))
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testOpeningAnotherDirectorySavesReviewAndRejectsOldWorkspace() async throws {
        let photo = try writeDuplicatePhoto("photos/first.jpg")
        try makeFile("photos/copy.jpg", data: Data(contentsOf: photo))
        let other = try writeDuplicatePhoto("other/new.jpg", variant: 1)
        let viewer = makeViewer()
        defer { viewer.closeLibrary() }
        try await start(viewer, url: photo)
        let review = try #require(viewer.duplicateReview)
        review.session.keepOnly("first.jpg")
        viewer.open([other])
        try await waitUntil { viewer.duplicateReview == nil && viewer.currentURL == other && !viewer.isLoading && !viewer.isScanning }
        let store = DuplicateStore(directory: fixtureDirectory.appendingPathComponent(".duplicates"))
        let record = try await store.loadReview(root: photo.deletingLastPathComponent())
        #expect(record.decisions.values.first?.removals == ["copy.jpg"])
        #expect(viewer.canCheckDuplicates)
    }

    @Test(arguments: [CGSize(width: 420, height: 292), CGSize(width: 420, height: 320),
                      CGSize(width: 700, height: 420), CGSize(width: 1100, height: 760)])
    func testReviewControlsFitNarrowWindowsAndVersionsCanBePreviewed(size: CGSize) async throws {
        let photo = try writeDuplicatePhoto("长文件名－照片原版.jpg")
        try makeFile("手机传回/副本.jpg", data: Data(contentsOf: photo))
        let viewer = makeViewer()
        let window = makeWindow(viewer, size: size)
        defer { viewer.closeLibrary(); window.close() }
        try await start(viewer, url: photo)
        let review = try #require(viewer.duplicateReview)
        review.view.frame.size = size
        review.render()
        review.view.layoutSubtreeIfNeeded()
        review.groupTable.onActivate?()
        review.previewButton.performClick(nil)
        #expect(!review.preview.view.isHidden && review.preview.view.frame.height >= 60)
        for child in review.view.subviews where !child.isHidden {
            #expect(review.view.bounds.contains(child.frame), "\(type(of: child)) 超出工作区：\(child.frame)")
        }
        #expect(review.session.pendingFiles.isEmpty && !review.cleanupButton.isEnabled)
        review.keepButton.performClick(nil)
        #expect(review.session.pendingFiles.count == 1 && review.cleanupButton.isEnabled)
        #expect(await viewer.prepareForLibraryDeparture())
    }

    @Test
    func testFileRowsOnlyCreateThumbnailsForVisibleVersions() async throws {
        let photo = try writeDuplicatePhoto("original.jpg")
        for index in 0..<120 { try makeFile("copies/\(index).jpg", data: Data(contentsOf: photo)) }
        let viewer = makeViewer()
        let window = makeWindow(viewer, size: CGSize(width: 1100, height: 760))
        defer { viewer.closeLibrary(); window.close() }
        try await start(viewer, url: photo)
        let review = try #require(viewer.duplicateReview)
        review.view.layoutSubtreeIfNeeded()
        review.fileTable.layoutSubtreeIfNeeded()
        try await waitUntil { await review.preview.decoder.thumbnailCachedCount > 0 }
        #expect(await review.preview.decoder.thumbnailCachedCount < 20)
        #expect(review.fileTable.numberOfRows == 121)
        #expect(await viewer.prepareForLibraryDeparture())
    }
}
