import AVFoundation
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class VideoPlaybackControllerTests: FixtureTestCase {
    @Test
    func testPreparationIsPausedAndVisibilityPreservesUserPlaybackIntent() async throws {
        let url = try await writeVideo(includesAudio: true)
        let playback = VideoPlaybackController()
        playback.player.isMuted = true
        defer { playback.stop() }
        playback.prepare(url, visible: true)
        try await waitUntil(timeout: 8) { playback.state == .ready }
        #expect(playback.player.rate == 0 && playback.player.currentTime().seconds == 0)
        #expect(playback.info?.pixelSize == CGSize(width: 160, height: 90))
        playback.togglePlayback()
        try await waitUntil { playback.player.currentTime().seconds > 0.1 }
        playback.setVisible(false)
        playback.setVisible(false)
        let paused = playback.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(playback.player.rate == 0 && abs(playback.player.currentTime().seconds - paused) < 0.02)
        playback.setVisible(true)
        try await waitUntil { playback.player.currentTime().seconds > paused + 0.05 }
        playback.togglePlayback()
        playback.setVisible(false)
        playback.setVisible(true)
        #expect(playback.player.rate == 0, "A manually paused video must stay paused when the window returns")
    }

    @Test
    func testPlayingJustBeforeEndDoesNotRestartVideo() async throws {
        let url = try await writeVideo(frames: 12)
        let playback = VideoPlaybackController()
        defer { playback.stop() }
        playback.prepare(url, visible: true)
        try await waitUntil(timeout: 8) { playback.state == .ready }
        let player = playback.player
        let duration = try #require(playback.info?.duration)
        let nearEnd = CMTime(seconds: duration - 0.005, preferredTimescale: 600)
        let didSeek = await player.seek(to: nearEnd, toleranceBefore: .zero, toleranceAfter: .zero)
        try #require(didSeek && player.currentTime() == nearEnd)

        let crossedMiddle = TestSignal()
        let middle = NSValue(time: CMTime(seconds: duration / 2, preferredTimescale: 600))
        let boundary = player.addBoundaryTimeObserver(forTimes: [middle], queue: .main) { crossedMiddle.signal() }
        defer { player.removeTimeObserver(boundary) }
        let ended = TestSignal()
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in ended.signal() }
        defer { NotificationCenter.default.removeObserver(observer) }
        playback.togglePlayback()
        try await waitFor([ended], timeout: 5)
        #expect(!crossedMiddle.isSet)
    }

    @Test
    func testEndStopsAndBothKeyboardAndNativePlaybackRestartFromBeginning() async throws {
        let url = try await writeVideo(frames: 6)
        let playback = VideoPlaybackController()
        defer { playback.stop() }
        playback.prepare(url, visible: true)
        try await waitUntil(timeout: 8) { playback.state == .ready }
        playback.togglePlayback()
        try await waitUntil { playback.player.rate == 0 && playback.player.currentTime().seconds >= 0.49 }
        playback.togglePlayback()
        try await waitUntil { playback.player.rate > 0 && playback.player.currentTime().seconds < 0.25 }
        playback.pause()
        _ = await playback.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playback.player.play()
        try await waitUntil { playback.player.rate > 0 && playback.player.currentTime().seconds < 0.25 }
        #expect(playback.url == url && playback.state == .ready)
    }

    @Test(arguments: [false, true])
    func testLatePreparationCannotRestoreOldItemAfterReplaceOrStop(close: Bool) async throws {
        let oldURL = try await writeVideo("old.mp4")
        let newURL = try makeFile("new.mp4", data: Data(contentsOf: oldURL))
        let started = TestSignal()
        let finished = TestSignal()
        let gate = VideoTestGate()
        let playback = VideoPlaybackController(infoLoader: { asset in
            if asset.url == oldURL {
                started.signal()
                await gate.wait()
                finished.signal()
                return VideoInfo(pixelSize: CGSize(width: 999, height: 999), duration: 2)
            }
            return try await VideoInfo.load(from: asset)
        })
        defer { playback.stop() }
        playback.prepare(oldURL, visible: true)
        try await waitFor([started], timeout: 3)
        if close { playback.stop() } else { playback.prepare(newURL, visible: true) }
        await gate.open()
        try await waitFor([finished], timeout: 3)
        if close {
            await Task.yield()
            #expect(playback.player.currentItem == nil && playback.state == .idle && playback.url == nil)
        } else {
            try await waitUntil(timeout: 8) { playback.state == .ready }
            #expect(playback.url == newURL && playback.info?.pixelSize == CGSize(width: 160, height: 90))
        }
        #expect(playback.player.rate == 0)
    }

    @Test
    func testCorruptAndAudioOnlyFilesFailAndNextVideoCanLoad() async throws {
        let corrupt = try makeFile("broken.mp4", data: Data("invalid movie".utf8))
        let audio = try await writeVideo("audio.mp4", includesVideo: false, includesAudio: true)
        let valid = try await writeVideo("valid.mov")
        let playback = VideoPlaybackController()
        defer { playback.stop() }
        for url in [corrupt, audio] {
            playback.prepare(url, visible: true)
            try await waitUntil(timeout: 8) { playback.state == .failed }
            #expect(playback.error != nil && playback.player.currentItem == nil)
            if url == audio { #expect((playback.error as? VideoLoadError)?.errorDescription == "文件中没有视频画面") }
            playback.togglePlayback()
            #expect(!playback.isPlaying)
        }
        playback.prepare(valid, visible: true)
        try await waitUntil(timeout: 8) { playback.state == .ready }
        #expect(playback.error == nil && playback.player.rate == 0)
        playback.stop()
        #expect(playback.player.currentItem == nil && playback.info == nil)
    }
}
