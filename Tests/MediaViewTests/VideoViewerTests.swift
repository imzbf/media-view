import AppKit
import AVFoundation
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class VideoViewerTests: FixtureTestCase {
    @Test
    func testMixedSelectionSearchCopyAndInfoShareCurrentURL() async throws {
        _ = NSApplication.shared
        let image = try writeImage("1-photo.png")
        let gif = try writeGIF("2-animation.gif")
        let video = try await writeVideo("3-video.mp4")
        let viewer = MediaViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([video])
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        #expect(viewer.images == [image, gif, video] && viewer.currentURL == video)
        #expect(viewer.hasContent && !viewer.hasImage && viewer.canvas.isVideoVisible)
        #expect(!viewer.canvas.geometry.hasImage && viewer.videoPlayback.player.rate == 0)
        viewer.toggleInfo()
        try await waitUntil { viewer.infoCard.metadata != nil }
        #expect(viewer.infoCard.text.contains("时长") && viewer.infoCard.text.contains("0:02"))
        let item = viewer.videoPlayback.player.currentItem
        viewer.setSort(.nameDescending)
        try await waitUntil { !viewer.isSorting }
        #expect(viewer.currentURL == video && viewer.videoPlayback.player.currentItem === item)
        viewer.showSearch()
        viewer.setSearchQuery("video")
        try await waitUntil { !viewer.isSearching }
        #expect(viewer.searchMatches == [video])
        let pasteboard = NSPasteboard(name: .init("MediaView.VideoTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(viewer.copyCurrentImage(to: pasteboard))
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(copied == [video])
        viewer.selectImage(gif)
        try await waitUntil { viewer.playback.animation != nil }
        #expect(!viewer.canvas.isVideoVisible && viewer.videoPlayback.player.currentItem == nil)
        viewer.selectImage(video)
        try await waitUntil(timeout: 8) { viewer.hasVideo }
        #expect(viewer.playback.animation == nil && viewer.videoPlayback.player.currentTime().seconds == 0)
        viewer.selectImage(image)
        try await waitUntil { viewer.hasImage }
        #expect(viewer.videoPlayback.player.currentItem == nil && viewer.canvas.videoView?.player == nil)
    }

    @Test
    func testInvalidOpenKeepsVideoPositionAndRestoresPlaybackIntent() async throws {
        _ = NSApplication.shared
        let video = try await writeVideo()
        let invalid = try makeFile("notes.txt")
        let viewer = MediaViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([video])
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        viewer.videoPlayback.togglePlayback()
        try await waitUntil { viewer.videoPlayback.player.currentTime().seconds > 0.1 }
        viewer.setWindowVisible(false)
        let position = viewer.videoPlayback.player.currentTime().seconds
        let item = viewer.videoPlayback.player.currentItem
        viewer.open([invalid])
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.currentURL == video && viewer.videoPlayback.player.currentItem === item)
        #expect(abs(viewer.videoPlayback.player.currentTime().seconds - position) < 0.02)
        #expect(viewer.videoPlayback.player.rate == 0)
        viewer.setWindowVisible(true)
        try await waitUntil { viewer.videoPlayback.player.currentTime().seconds > position + 0.05 }
        viewer.open([invalid])
        try await waitUntil { !viewer.isScanning && viewer.videoPlayback.player.rate > 0 }
        #expect(viewer.videoPlayback.player.currentItem === item)
    }

    @Test
    func testReloadAndRefreshRestartVideoPausedWithFreshMetadata() async throws {
        _ = NSApplication.shared
        let video = try await writeVideo()
        let viewer = MediaViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([video])
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        _ = await viewer.videoPlayback.player.seek(to: CMTime(seconds: 0.8, preferredTimescale: 600))
        let oldItem = viewer.videoPlayback.player.currentItem
        try await writeVideo(width: 320, height: 180, blue: true)
        viewer.reloadCurrentImage()
        try await waitUntil(timeout: 8) { viewer.hasVideo && !viewer.isLoading }
        #expect(viewer.videoPlayback.player.currentItem !== oldItem)
        #expect(viewer.videoPlayback.info?.pixelSize == CGSize(width: 320, height: 180))
        #expect(viewer.videoPlayback.player.rate == 0 && viewer.videoPlayback.player.currentTime().seconds == 0)
        let added = try writeImage("added.png")
        viewer.refreshDirectory()
        try await waitUntil(timeout: 8) { !viewer.isScanning && !viewer.isLoading && viewer.hasVideo }
        #expect(viewer.images.contains(added) && viewer.currentURL == video)
        #expect(viewer.videoPlayback.player.rate == 0 && viewer.videoPlayback.player.currentTime().seconds == 0)
    }

    @Test(arguments: [false, true])
    func testTrashingVideoStopsPlaybackAndSelectsAdjacentFile(onlyVideo: Bool) async throws {
        _ = NSApplication.shared
        let video = try await writeVideo("1-video.mp4")
        let image = onlyVideo ? nil : try writeImage("2-image.png")
        let viewer = MediaViewerController(trashItem: { try FileManager.default.removeItem(at: $0) })
        defer { viewer.closeLibrary() }
        viewer.open([video])
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        viewer.videoPlayback.togglePlayback()
        viewer.trashCurrentImage()
        try await waitUntil { !viewer.isTrashing && !viewer.isLoading }
        #expect(viewer.currentURL == image && !viewer.hasVideo)
        #expect(viewer.videoPlayback.player.currentItem == nil && viewer.videoPlayback.player.rate == 0)
        #expect(!viewer.canvas.isVideoVisible)
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test
    func testScopeAndCloseClearVideoWithoutLosingRootDirectory() async throws {
        _ = NSApplication.shared
        let video = try await writeVideo("nested/video.mp4")
        let viewer = MediaViewerController()
        viewer.open([fixtureDirectory])
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        viewer.setIncludesSubdirectories(false)
        try await waitUntil { !viewer.isScanning }
        #expect(viewer.currentURL == nil && viewer.videoPlayback.player.currentItem == nil)
        #expect(viewer.canRefreshDirectory && !viewer.hasContent)
        viewer.setIncludesSubdirectories(true)
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        #expect(viewer.currentURL == video && viewer.videoPlayback.player.rate == 0)
        viewer.closeLibrary()
        #expect(viewer.videoPlayback.player.currentItem == nil && viewer.canvas.videoView?.player == nil)
    }

    @Test
    func testPlayerKeyboardContextMenuAndSmallWindowKeepExistingInteractions() async throws {
        _ = NSApplication.shared
        let image = try writeImage("1-image.png")
        let video = try await writeVideo("2-video.mp4")
        let viewer = MediaViewerController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        // 离屏窗口尚未同步 WindowServer 的内容尺寸，显式设置后才能验证最小窗口布局。
        viewer.view.frame.size = CGSize(width: 420, height: 320)
        defer { viewer.closeLibrary(); window.close() }
        viewer.open([video])
        viewer.setWindowVisible(true)
        try await waitUntil(timeout: 8) { !viewer.isScanning && viewer.hasVideo }
        viewer.view.layoutSubtreeIfNeeded()
        let playerView = try #require(viewer.canvas.videoView)
        #expect(playerView.frame == viewer.canvas.bounds)
        #expect(viewer.view.frame.width == 420)
        #expect(window.acceptsMouseMovedEvents)
        #expect(playerView.controlsStyle == .inline && playerView.videoGravity == .resizeAspect)
        #expect(!playerView.showsFullScreenToggleButton && !playerView.allowsPictureInPicturePlayback)
        #expect(!playerView.allowsVideoFrameAnalysis)
        window.makeFirstResponder(viewer.canvas)
        let space = try key(49, window: window)
        #expect(playerView.handlePlaybackKey(space))
        try await waitUntil { viewer.videoPlayback.isPlaying }
        #expect(playerView.handlePlaybackKey(try key(49, window: window, repeatKey: true)))
        #expect(viewer.videoPlayback.isPlaying, "Holding space must not toggle playback repeatedly")
        let trackingMenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: trackingMenu)
        #expect(!playerView.handlePlaybackKey(space))
        #expect(!playerView.handlePlaybackKey(try key(123, window: window)))
        #expect(viewer.currentURL == video, "Menu navigation must not change the selected media")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackingMenu)
        viewer.showSearch()
        #expect(!playerView.handlePlaybackKey(space), "Text input must retain space and arrow keys")
        viewer.hideSearch()
        let menu = NSMenu()
        viewer.canvas.onContextMenu = { menu }
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(playerView.menu(for: rightClick) === menu)
        #expect(playerView.handlePlaybackKey(try key(123, window: window)))
        try await waitUntil { viewer.currentURL == image && viewer.hasImage }
        #expect(viewer.videoPlayback.player.currentItem == nil)
    }

    @Test
    func testBrokenVideoShowsFailureKeepsNavigationAndCanReload() async throws {
        _ = NSApplication.shared
        try writeImage("1-photo.png")
        let broken = try makeFile("2-broken.mp4", data: Data("broken".utf8))
        let next = try writeImage("3-photo.png")
        let viewer = MediaViewerController()
        defer { viewer.closeLibrary() }
        viewer.open([broken])
        try await waitUntil(timeout: 8) { !viewer.isScanning && !viewer.isLoading }
        #expect(viewer.videoPlayback.state == .failed && !viewer.hasContent && !viewer.canvas.isVideoVisible)
        #expect(viewer.previousButton.isEnabled && viewer.nextButton.isEnabled)
        try await writeVideo("2-broken.mp4")
        viewer.reloadCurrentImage()
        try await waitUntil(timeout: 8) { viewer.hasVideo }
        #expect(viewer.canvas.isVideoVisible && viewer.videoPlayback.player.rate == 0)
        viewer.navigate(by: 1)
        try await waitUntil { viewer.currentURL == next && viewer.hasImage }
    }

    @Test(arguments: ["select", "directory", "close"])
    func testLeavingDuringVideoPreparationCannotRestoreOldPreview(action: String) async throws {
        _ = NSApplication.shared
        let video = try await writeVideo()
        let image = try writeImage("photo.png")
        let other = try makeFile("other/new.png", data: Data(contentsOf: image))
        let started = TestSignal()
        let finished = TestSignal()
        let gate = VideoTestGate()
        let playback = VideoPlaybackController(infoLoader: { _ in
            started.signal()
            await gate.wait()
            finished.signal()
            return VideoInfo(pixelSize: CGSize(width: 160, height: 90), duration: 2)
        })
        let viewer = MediaViewerController(videoPlayback: playback)
        defer { viewer.closeLibrary() }
        viewer.open([video])
        try await waitFor([started], timeout: 3)
        switch action {
        case "select": viewer.selectImage(image)
        case "directory": viewer.open([other])
        default: viewer.closeLibrary()
        }
        await gate.open()
        try await waitFor([finished], timeout: 3)
        if action == "close" {
            await Task.yield()
            #expect(viewer.currentURL == nil && !viewer.hasContent)
        } else {
            try await waitUntil { !viewer.isScanning && viewer.hasImage }
            #expect(viewer.currentURL == (action == "select" ? image : other))
        }
        #expect(!viewer.isLoading && !viewer.canvas.isVideoVisible && playback.player.currentItem == nil)
    }

    private func key(_ code: UInt16, window: NSWindow, repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "\u{f702}",
            charactersIgnoringModifiers: code == 49 ? " " : "\u{f702}", isARepeat: repeatKey, keyCode: code))
    }
}
