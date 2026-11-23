import Foundation
import Testing
@testable import MediaView

@Suite(.serialized)
@MainActor
final class GIFPlaybackControllerTests: FixtureTestCase {
    @Test
    func testFramesAdvanceAtTheirOwnDelaysWithoutCatchingUpInBursts() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(), quality: .original)
        let animation = try #require(first.animation)
        var time: TimeInterval = 0
        let player = GIFPlaybackController(decoder: decoder, now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.start(animation, firstFrame: first, quality: .original, visible: true)
        try await waitUntil { player.bufferedFrameCount == 2 }
        time = 0.019
        player.tick()
        #expect(player.currentFrameIndex == 0)
        time = 0.02
        player.tick()
        #expect(player.currentFrameIndex == 1)
        time = 0.089
        player.tick()
        #expect(player.currentFrameIndex == 1)
        time = 0.091
        player.tick()
        #expect(player.currentFrameIndex == 2)
        try await waitUntil { player.bufferedFrameCount == 2 }
        time = 10
        player.tick()
        #expect(player.currentStep == 3, "A delayed clock displays only the next frame")
        player.tick()
        #expect(player.currentStep == 3, "The next delay begins when its frame is actually displayed")
    }

    @Test(arguments: [nil, 0, 1, 2] as [Int?])
    func testFiniteAndInfiniteLoops(loopCount: Int?) async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(delays: [0.02, 0.03], loopCount: loopCount), quality: .original)
        let animation = try #require(first.animation)
        var time: TimeInterval = 0
        let player = GIFPlaybackController(decoder: decoder, now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.start(animation, firstFrame: first, quality: .original, visible: true)
        let framesToPlay = loopCount == 0 ? 10 : ((loopCount ?? 0) + 1) * 2
        for step in 1..<framesToPlay {
            try await waitUntil { player.bufferedFrameCount > 0 }
            time += 1
            player.tick()
            #expect(player.currentStep == step)
            #expect(!player.isFinished)
        }
        time += 1
        player.tick()
        if loopCount == 0 {
            #expect(!player.isFinished)
        } else {
            #expect(player.isFinished)
            #expect(player.currentFrameIndex == 1)
            #expect(player.bufferedFrameCount == 0 && player.pendingFrameCount == 0)
        }
    }

    @Test
    func testPausePreservesRemainingFrameTimeAndCancelsPrefetch() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(delays: [0.1, 0.3, 0.1]), quality: .original)
        var time: TimeInterval = 0
        let player = GIFPlaybackController(decoder: decoder, now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.start(try #require(first.animation), firstFrame: first, quality: .original, visible: true)
        try await waitUntil { player.bufferedFrameCount == 2 }
        time = 0.04
        player.setVisible(false)
        #expect(player.pendingFrameCount == 0 && player.bufferedFrameCount == 0)
        time = 100
        player.tick()
        #expect(player.currentStep == 0)
        player.setVisible(true)
        try await waitUntil { player.bufferedFrameCount == 2 }
        time = 100.05
        player.tick()
        #expect(player.currentStep == 0)
        time = 100.061
        player.tick()
        #expect(player.currentStep == 1)
    }

    @Test
    func testQualityChangeKeepsFrameLoopAndRemainingDelay() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(delays: [0.1, 0.1], width: 1024, height: 512),
                                           quality: .screen(maxPixelDimension: 64))
        var time: TimeInterval = 0
        var lastWidth = first.image.width
        let player = GIFPlaybackController(decoder: decoder, now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.onFrame = { lastWidth = $0.image.width }
        player.start(try #require(first.animation), firstFrame: first,
                     quality: .screen(maxPixelDimension: 64), visible: true)
        for _ in 0..<3 {
            try await waitUntil { player.bufferedFrameCount > 0 }
            time += 1
            player.tick()
        }
        #expect(player.currentStep == 3 && lastWidth == 64)
        time += 0.03
        player.changeQuality(to: .original)
        try await waitUntil { !player.needsQualityRefresh && player.bufferedFrameCount == 2 }
        #expect(player.currentStep == 3 && lastWidth == 1024)
        time += 0.069
        player.tick()
        #expect(player.currentStep == 3)
        time += 0.002
        player.tick()
        #expect(player.currentStep == 4)

        player.setVisible(false)
        player.changeQuality(to: .screen(maxPixelDimension: 32))
        #expect(player.needsQualityRefresh && player.pendingFrameCount == 0)
        player.setVisible(true)
        try await waitUntil { !player.needsQualityRefresh }
        #expect(player.currentStep == 4 && lastWidth == 32)
    }

    @Test(arguments: [0, 1, 2])
    func testLookAheadAndByteBudget(frameCapacity: Int) async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(), quality: .original)
        // 0 表示连一帧也放不下，仍须在到期时按需解码并继续播放。
        let budget = frameCapacity == 0 ? first.memoryCost - 1 : first.memoryCost * frameCapacity
        var time: TimeInterval = 0
        let player = GIFPlaybackController(decoder: decoder, byteBudget: budget,
                                            now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.start(try #require(first.animation), firstFrame: first, quality: .original, visible: true)
        try await waitUntil { player.bufferedFrameCount == frameCapacity }
        for step in 1...8 {
            time += 1
            player.tick()
            try await waitUntil { player.currentStep == step && player.pendingFrameCount == 0 }
            #expect(player.bufferedFrameCount <= 2)
            #expect(player.bufferedByteCount <= budget)
            if frameCapacity == 0 { #expect(player.bufferedFrameCount == 0) }
        }
    }

    @Test
    func testDamagedFrameStopsAtLastValidFrameAndReportsOnce() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try gifFixture("damaged-frame"), quality: .original)
        var time: TimeInterval = 0
        var displayed: [Int] = []
        var errorCount = 0
        let player = GIFPlaybackController(decoder: decoder, now: { time }, schedulesTimers: false)
        defer { player.stop() }
        player.onFrame = { _ in displayed.append(player.currentFrameIndex) }
        player.onFailure = { _ in errorCount += 1 }
        player.start(try #require(first.animation), firstFrame: first, quality: .original, visible: true)
        for step in 1...2 {
            try await waitUntil { player.bufferedFrameCount > 0 }
            time += 1
            player.tick()
            #expect(player.currentStep == step)
        }
        try await waitUntil { player.pendingFrameCount == 0 }
        time += 1
        player.tick()
        #expect(player.hasFailed)
        #expect(player.currentFrameIndex == 2 && displayed == [1, 2])
        #expect(errorCount == 1 && player.bufferedFrameCount == 0)
        time += 10
        player.tick()
        #expect(errorCount == 1)
        player.onFrame = nil
    }

    @Test
    func testStopDiscardsInFlightFrames() async throws {
        let first = try await ImageDecoder().load(try writeGIF(), quality: .original)
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let decoder = ImageDecoder { _, _ in
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            finished.signal()
            return first
        }
        var displayed = 0
        let player = GIFPlaybackController(decoder: decoder, schedulesTimers: false)
        defer { gate.signal(); player.stop() }
        player.onFrame = { _ in displayed += 1 }
        player.start(try #require(first.animation), firstFrame: first, quality: .original, visible: true)
        try await waitFor([started], timeout: 2)
        player.stop()
        gate.signal()
        try await waitFor([finished], timeout: 2)
        #expect(displayed == 0 && player.animation == nil)
        #expect(player.bufferedFrameCount == 0 && player.pendingFrameCount == 0)
    }

    @Test
    func testRealClockAutomaticallyAdvances() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try writeGIF(), quality: .original)
        let player = GIFPlaybackController(decoder: decoder)
        defer { player.stop() }
        player.start(try #require(first.animation), firstFrame: first, quality: .original, visible: true)
        try await waitUntil { player.currentStep >= 3 }
        #expect(player.isPlaying)
    }
}
