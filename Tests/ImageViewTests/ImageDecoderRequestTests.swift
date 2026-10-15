import Foundation
import Testing
@testable import ImageView

@Suite(.serialized)
final class ImageDecoderRequestTests: FixtureTestCase {
    @Test
    func testThumbnailDoesNotReplaceMainAndAnimationUsesForegroundQueue() async throws {
        let first = try await ImageDecoder().load(try writeGIF(), quality: .original)
        let animation = try #require(first.animation)
        let mainStarted = TestSignal()
        let frameStarted = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let decoder = ImageDecoder { request, _ in
            switch request {
            case .mainImage:
                mainStarted.signal()
                _ = gate.wait(timeout: .now() + 5)
            case .animationFrame:
                frameStarted.signal()
            default: break
            }
            return first
        }
        let current = fixtureDirectory.appendingPathComponent("current.png")
        let thumbnailURL = fixtureDirectory.appendingPathComponent("thumb.png")
        let main = Task { try await decoder.load(current, quality: .original) }
        try await waitFor([mainStarted], timeout: 2)
        let frame = Task { try await decoder.frame(of: animation, at: 1, quality: .original) }
        let thumbnail = try await decoder.thumbnail(thumbnailURL, maxPixelDimension: 100)
        #expect(thumbnail.image.width == first.image.width)
        #expect(!frameStarted.isSet, "GIF must wait on the same serial queue as the main image")
        gate.signal()
        _ = try await main.value
        _ = try await frame.value
        #expect(await decoder.cachedURLs == [current])
        #expect(await decoder.thumbnailCachedURLs == [thumbnailURL])
    }

    @Test
    func testCancellingThumbnailImmediatelyReleasesWaiterAndKeepsMain() async throws {
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let started = TestSignal()
        let finished = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let decoder = ImageDecoder { request, _ in
            if case .thumbnail = request {
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
                finished.signal()
            }
            return image
        }
        let url = fixtureDirectory.appendingPathComponent("image.png")
        let thumbnail = Task { try await decoder.thumbnail(url, maxPixelDimension: 100) }
        try await waitFor([started], timeout: 2)
        thumbnail.cancel()
        await #expect(throws: CancellationError.self) { try await thumbnail.value }
        #expect(!finished.isSet)
        let current = try await decoder.load(url, quality: .original)
        #expect(current.image.width == 80)
        gate.signal()
        try await waitFor([finished], timeout: 2)
        #expect(await decoder.thumbnailCachedCount == 0)
        #expect(await decoder.cachedURLs == [url])
    }

    @Test
    func testThumbnailCacheEnforces128ItemsAnd32MiBSeparatelyFromMain() async throws {
        let small = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { _, _ in small }
        let urls = (0..<130).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        _ = try await decoder.load(urls[0], quality: .original)
        for url in urls { _ = try await decoder.thumbnail(url, maxPixelDimension: 200) }
        #expect(await decoder.thumbnailCachedCount == 128)
        #expect(await decoder.thumbnailCachedURLs == Set(urls.suffix(128)))
        #expect(await decoder.cachedURLs == [urls[0]], "Thumbnail eviction does not evict the main image")

        let large = DecodedImage(image: try testBitmap(width: 1024, height: 1024),
                                 pixelSize: CGSize(width: 1024, height: 1024), isFullResolution: true)
        let limited = ImageDecoder { _, _ in large }
        for url in urls.prefix(12) { _ = try await limited.thumbnail(url, maxPixelDimension: 1024) }
        #expect(await limited.thumbnailCachedByteCount <= 32 * 1024 * 1024)
        #expect(await limited.thumbnailCachedCount == 8)
        await limited.reset()
        #expect(await limited.thumbnailCachedCount == 0)
    }

    @Test
    func testThumbnailCacheNeverSatisfiesOriginalImageRequest() async throws {
        let url = try writeImage("large.png", width: 1600, height: 900)
        let decoder = ImageDecoder()
        let thumbnail = try await decoder.thumbnail(url, maxPixelDimension: 200)
        let original = try await decoder.load(url, quality: .original)
        #expect(thumbnail.image.width == 200)
        #expect(original.image.width == 1600 && original.isFullResolution)
    }
}
