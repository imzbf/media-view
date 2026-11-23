import AppKit
import Testing
@testable import MediaView

@Suite(.serialized)
@MainActor
final class ImageLoadingTransitionTests: FixtureTestCase {
    @Test(arguments: [false, true])
    func testFastAndCachedSwitchesNeverShowLoadingIndicator(warmCache: Bool) async throws {
        _ = NSApplication.shared
        let first = try makeFile("1.png")
        let second = try makeFile("2.png")
        let small = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                 isFullResolution: true)
        let large = DecodedImage(image: try testBitmap(red: 0, blue: 1),
                                 pixelSize: CGSize(width: 2000, height: 1200), isFullResolution: true)
        let decoder = ImageDecoder { request, _ in
            // 预取不能提前填入缓存，分别覆盖普通快速解码与已知缓存命中。
            if case .neighborPrefetch = request { throw CancellationError() }
            return request.url == first ? small : large
        }
        let viewer = MediaViewerController(decoder: decoder)
        defer { viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
        if warmCache { _ = try await decoder.load(second, quality: viewer.canvas.screenQuality) }
        let layer = try #require(viewer.canvas.layer?.sublayers?.first)
        let progress = try #require(viewer.canvas.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let status = try #require(viewer.canvas.subviews.compactMap { $0 as? NSStackView }.first)
        let becameVisible = TestSignal()
        let observation = progress.observe(\.isHidden, options: [.new]) { _, change in
            if change.newValue == false { becameVisible.signal() }
        }
        defer { observation.invalidate() }

        viewer.selectImage(second)
        #expect(viewer.isLoading && !viewer.hasImage)
        #expect((layer.contents as! CGImage?) === small.image)
        #expect(status.isHidden && progress.isHidden)
        try await waitUntil { !viewer.isLoading }
        #expect((layer.contents as! CGImage?) === large.image)
        viewer.selectImage(first)
        #expect((layer.contents as! CGImage?) === large.image)
        try await waitUntil { !viewer.isLoading }
        #expect((layer.contents as! CGImage?) === small.image)
        // 等过旧任务的截止时间，检查完成后的提示不会迟到闪现。
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!becameVisible.isSet && progress.isHidden)
    }

    @Test(arguments: [false, true])
    func testSlowSwitchKeepsOldGeometryUntilSuccessOrFailure(fails: Bool) async throws {
        _ = NSApplication.shared
        let first = try makeFile("1.png")
        let second = try makeFile("2.png")
        let small = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                 isFullResolution: true)
        let large = DecodedImage(image: try testBitmap(red: 0, blue: 1),
                                 pixelSize: CGSize(width: 2000, height: 1200), isFullResolution: true)
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder { request, _ in
            if case .neighborPrefetch = request { throw CancellationError() }
            if case .mainImage(let url, _) = request, url == second {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                if fails { throw ImageDecodeError.invalidImage }
                return large
            }
            return small
        }
        let viewer = MediaViewerController(decoder: decoder)
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
        viewer.view.layoutSubtreeIfNeeded()
        viewer.canvas.zoom(by: 3)
        viewer.canvas.rotate(clockwise: true)
        viewer.canvas.mirror(horizontal: true)
        let before = viewer.canvas.geometry
        let layer = try #require(viewer.canvas.layer?.sublayers?.first)
        let progress = try #require(viewer.canvas.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let status = try #require(viewer.canvas.subviews.compactMap { $0 as? NSStackView }.first)
        let began = ContinuousClock.now
        viewer.selectImage(second)
        #expect(progress.isHidden && status.isHidden)
        try await waitFor([started], timeout: 2)
        try await waitUntil { !progress.isHidden }
        #expect(began.duration(to: .now) >= .milliseconds(200))
        #expect((layer.contents as! CGImage?) === small.image && status.isHidden)
        #expect(viewer.canvas.geometry.imageSize == before.imageSize)
        #expect(viewer.canvas.geometry.scale == before.scale && viewer.canvas.geometry.offset == before.offset)
        #expect(viewer.canvas.geometry.orientation == before.orientation && layer.frame == before.imageFrame)
        #expect(viewer.isLoading && !viewer.hasImage && viewer.previousButton.isEnabled)

        gate.signal()
        try await waitUntil { !viewer.isLoading }
        #expect(progress.isHidden)
        if fails {
            #expect(!viewer.hasImage && layer.contents == nil && !status.isHidden)
            viewer.navigate(by: -1)
            try await waitUntil { viewer.hasImage && !viewer.isLoading }
            #expect(viewer.currentURL == first)
        } else {
            #expect(viewer.hasImage && status.isHidden && (layer.contents as! CGImage?) === large.image)
            #expect(viewer.canvas.geometry.imageSize == large.pixelSize)
            #expect(viewer.canvas.geometry.orientation == .identity && viewer.canvas.geometry.mode == .fit)
            #expect(viewer.canvas.geometry.offset == .zero && layer.frame == viewer.canvas.geometry.imageFrame)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(progress.isHidden)
    }

    @Test(arguments: ["select", "directory", "close", "empty"], [false, true])
    func testSupersededLoadsCannotRestoreIndicatorOrImage(action: String, waitForIndicator: Bool) async throws {
        _ = NSApplication.shared
        let first = try makeFile("1.png")
        let slow = try makeFile("2.png")
        let last = try makeFile("3.png")
        let other = try makeFile("other/new.png")
        let oldImage = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                    isFullResolution: true)
        let newImage = DecodedImage(image: try testBitmap(red: 0, blue: 1), pixelSize: CGSize(width: 160, height: 80),
                                    isFullResolution: true)
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder { request, _ in
            if case .neighborPrefetch = request { throw CancellationError() }
            if case .mainImage(let url, _) = request, url == slow {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                // 原生解码可能在取消后仍返回；旧画面和延迟提示都不能覆盖新会话。
                finished.signal()
                return oldImage
            }
            return request.url == first ? oldImage : newImage
        }
        let viewer = MediaViewerController(decoder: decoder)
        defer { gate.signal(); viewer.closeLibrary() }
        viewer.open([first])
        try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
        let progress = try #require(viewer.canvas.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let layer = try #require(viewer.canvas.layer?.sublayers?.first)
        viewer.selectImage(slow)
        try await waitFor([started], timeout: 2)
        if waitForIndicator { try await waitUntil { !progress.isHidden } }
        switch action {
        case "select": viewer.selectImage(last)
        case "directory": viewer.open([other.deletingLastPathComponent()])
        case "close": viewer.closeLibrary()
        default:
            viewer.apply(LibrarySnapshot(directory: fixtureDirectory, images: [], preferredImage: nil,
                                         isComplete: true, skippedPaths: 0))
        }
        #expect(progress.isHidden)
        gate.signal()
        try await waitFor([finished], timeout: 2)
        if action == "select" || action == "directory" {
            try await waitUntil { !viewer.isScanning && !viewer.isLoading && viewer.hasImage }
            #expect(viewer.currentURL == (action == "select" ? last : other))
            #expect((layer.contents as! CGImage?) === newImage.image)
        } else {
            #expect(viewer.currentURL == nil && !viewer.hasImage && layer.contents == nil)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(progress.isHidden)
    }
}
