import AppKit
import Testing
@testable import ImageView

@Suite(.serialized)
final class ImageViewerControllerTests: FixtureTestCase {
    @MainActor
    @Test
    func testNavigationBoundsAndCorruptImageRecovery() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let corrupt = try makeFile("2.png", data: Data("corrupt".utf8))
        let last = try writeImage("3.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(viewer.currentURL == first)
        viewer.navigate(by: -1)
        #expect(viewer.currentURL == first)
        viewer.navigate(by: 1)
        #expect(viewer.isLoading && viewer.previousButton.isEnabled && viewer.nextButton.isEnabled)
        try await waitUntil { viewer.currentURL == corrupt && !viewer.isLoading }
        #expect(!viewer.hasImage)
        #expect(viewer.previousButton.isEnabled && viewer.nextButton.isEnabled)
        viewer.nextButton.performClick(nil)
        try await waitUntil { viewer.currentURL == last && viewer.hasImage }
        viewer.navigate(by: 1)
        #expect(viewer.currentURL == last)
    }

    @MainActor
    @Test
    func testInvalidDropKeepsExistingBrowsingSession() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let second = try writeImage("2.png")
        let unsupported = try makeFile("notes.txt")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.open([unsupported])
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.currentURL == first)
        #expect(viewer.hasImage)
        viewer.navigate(by: 1)
        try await waitUntil { viewer.currentURL == second && viewer.hasImage }
    }

    @MainActor
    @Test
    func testInvalidDropRestartsInterruptedInitialDecode() async throws {
        _ = NSApplication.shared
        let first = try makeFile("1.png")
        let unsupported = try makeFile("notes.txt")
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let recorder = DecodeRecorder()
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                 isFullResolution: true)
        let decoder = ImageDecoder { request, _ in
            if case .thumbnail = request { return image }
            recorder.record(request.url)
            if recorder.urls.count == 1 {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            return image
        }
        let viewer = ImageViewerController(decoder: decoder)
        defer {
            gate.signal()
            viewer.closeLibrary()
        }
        viewer.open([first])
        try await waitFor([started], timeout: 2)
        viewer.open([unsupported])
        try await waitUntil { !viewer.isScanning }
        gate.signal()
        try await waitUntil { viewer.hasImage && !viewer.isLoading }
        #expect(viewer.currentURL == first)
        #expect(recorder.urls.count == 2, "The cancelled first decode must be resumed after invalid input")
    }

    @MainActor
    @Test
    func testNewOpenWinsOverInFlightScanAndDecode() async throws {
        _ = NSApplication.shared
        let first = try writeImage("1.png")
        let last = try writeImage("2.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        viewer.open([last])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(viewer.currentURL == last)
    }

    @MainActor
    @Test
    func testThumbnailClickArrowAndScanSortShareURLSelection() async throws {
        _ = NSApplication.shared
        let first = try writeGIF("1.gif")
        let second = try writeImage("2.png")
        let last = try writeImage("3.jpg", type: .jpeg)
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.thumbnailStrip.collectionView(viewer.thumbnailStrip.collectionView,
            didSelectItemsAt: [IndexPath(item: 2, section: 0)])
        try await waitUntil { viewer.currentURL == last && !viewer.isLoading }
        #expect(viewer.thumbnailStrip.selectedURL == last && viewer.playback.animation == nil)
        viewer.navigate(by: -1)
        try await waitUntil { viewer.currentURL == second && !viewer.isLoading }
        #expect(viewer.thumbnailStrip.collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
        viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [last, first, second],
                                     preferredImage: first, isComplete: true, skippedPaths: 0))
        #expect(viewer.currentURL == second && viewer.currentIndex == 2)
        #expect(viewer.thumbnailStrip.selectedURL == second)
        #expect(viewer.thumbnailStrip.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0)])
    }

    @MainActor
    @Test
    func testGIFVisibilityAndInvalidInputPreservePlaybackPosition() async throws {
        _ = NSApplication.shared
        let gif = try writeGIF(delays: [0.03, 0.07, 0.15])
        let invalid = try makeFile("notes.txt")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([gif])
        try await waitUntil { viewer.playback.currentStep >= 2 }
        viewer.setWindowVisible(false)
        let pausedStep = viewer.playback.currentStep
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(viewer.playback.currentStep == pausedStep)
        #expect(viewer.playback.pendingFrameCount == 0 && viewer.thumbnailStrip.requestedURLs.isEmpty)
        viewer.open([invalid])
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.currentURL == gif && viewer.playback.currentStep == pausedStep)
        viewer.setWindowVisible(true)
        try await waitUntil { viewer.playback.currentStep > pausedStep }
    }

    @MainActor
    @Test(arguments: ["select", "directory", "close"])
    func testSwitchingOrClosingRejectsOldGIFFrame(action: String) async throws {
        _ = NSApplication.shared
        let gif = try writeGIF()
        let staticImage = try writeImage("static.png", width: 160, height: 80)
        let otherImage = try makeFile("other/new.png", data: Data(contentsOf: staticImage))
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder { request, cancelled in
            if case .animationFrame = request {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                // 模拟原生调用即使已取消也迟到返回；Operation 和会话必须共同拒绝它。
                let image = try ImageDecoder.decode(request, isCancelled: { false })
                finished.signal()
                return image
            }
            return try ImageDecoder.decode(request, isCancelled: cancelled)
        }
        let viewer = ImageViewerController(decoder: decoder)
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.open([gif])
        try await waitFor([started], timeout: 2)
        switch action {
        case "select": viewer.selectImage(staticImage)
        case "directory": viewer.open([otherImage.deletingLastPathComponent()])
        default: viewer.closeLibrary()
        }
        gate.signal()
        try await waitFor([finished], timeout: 2)
        if action == "close" {
            #expect(viewer.currentURL == nil && !viewer.hasImage)
            #expect(viewer.canvas.layer?.sublayers?.first?.contents == nil)
        } else {
            try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
            #expect(viewer.currentURL == (action == "select" ? staticImage : otherImage))
            #expect(viewer.canvas.geometry.imageSize == CGSize(width: 160, height: 80))
        }
        #expect(viewer.playback.animation == nil && viewer.playback.pendingFrameCount == 0)
    }

    @MainActor
    @Test
    func testDamagedGIFKeepsImageAndAllowsBrowsing() async throws {
        _ = NSApplication.shared
        let gif = try makeFile("1.gif", data: Data(contentsOf: try gifFixture("damaged-frame")))
        let next = try writeImage("2.png")
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([gif])
        try await waitUntil { viewer.playback.hasFailed }
        #expect(viewer.hasImage && viewer.playback.currentFrameIndex == 2)
        let notices = viewer.canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(notices.contains { $0.contains("GIF 播放已停止") })
        viewer.navigate(by: 1)
        try await waitUntil { viewer.currentURL == next && viewer.hasImage && !viewer.isLoading }
    }

    @MainActor
    @Test
    func testThumbnailVisibilityPersistsForThisRunAndWheelStaysInStrip() async throws {
        _ = NSApplication.shared
        let first = try writeImage("0.png")
        for index in 1..<10 { try writeImage("\(index).png") }
        let viewer = ImageViewerController()
        defer { viewer.closeLibrary() }
        viewer.view.frame.size = CGSize(width: 500, height: 400)
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        viewer.view.layoutSubtreeIfNeeded()
        #expect(viewer.isThumbnailStripVisible && viewer.thumbnailStrip.view.frame.height == 112)
        let scale = viewer.canvas.geometry.scale
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                           wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        viewer.thumbnailStrip.scrollView.scrollWheel(with: event)
        #expect(viewer.thumbnailStrip.scrollView.contentView.bounds.minX > 0)
        #expect(viewer.canvas.geometry.scale == scale)
        viewer.toggleThumbnails()
        viewer.view.layoutSubtreeIfNeeded()
        #expect(!viewer.isThumbnailStripVisible && viewer.thumbnailStrip.view.frame.height == 0)
        viewer.closeLibrary()
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && viewer.hasImage }
        #expect(!viewer.showsThumbnails && !viewer.isThumbnailStripVisible)
        viewer.toggleThumbnails()
        #expect(viewer.isThumbnailStripVisible)
    }
}
