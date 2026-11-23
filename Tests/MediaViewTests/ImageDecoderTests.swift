import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MediaView

@Suite(.serialized)
final class ImageDecoderTests: FixtureTestCase {
    @Test
    func testJPEGPNGAndTIFFDecode() async throws {
        let decoder = ImageDecoder()
        for (ext, type) in [("jpg", UTType.jpeg), ("png", .png), ("tiff", .tiff)] {
            let url = try writeImage("sample.\(ext)", type: type)
            let decoded = try await decoder.load(url, quality: .screen(maxPixelDimension: 100))
            #expect(decoded.pixelSize == CGSize(width: 80, height: 40), "\(ext)")
            #expect(decoded.image.width == 80, "\(ext)")
            #expect(decoded.image.height == 40, "\(ext)")
            #expect(decoded.isFullResolution, "\(ext)")
        }
    }

    @Test(.enabled(if: (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier),
                   "HEIC encoder is not available"))
    func testHEICDecodeWhenSystemEncoderIsAvailable() async throws {
        let url = try writeImage("sample.heic", type: .heic)
        let decoded = try await ImageDecoder().load(url, quality: .original)
        #expect(decoded.pixelSize == CGSize(width: 80, height: 40))
        #expect(decoded.image.width == 80)
    }

    @Test
    func testWebPDecode() async throws {
        let url = try #require(Bundle.module.url(forResource: "tiny", withExtension: "webp", subdirectory: "Fixtures"))
        let decoded = try await ImageDecoder().load(url, quality: .original)
        #expect(decoded.image.width == 1)
        #expect(decoded.image.height == 1)
    }

    @Test
    func testGIFUsesFirstFrame() async throws {
        let url = fixtureDirectory.appendingPathComponent("animated.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try testBitmap(red: 1, blue: 0), nil)
        CGImageDestinationAddImage(destination, try testBitmap(red: 0, blue: 1), nil)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try await ImageDecoder().load(url, quality: .original)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[0] > 240)
        #expect(pixels[2] < 20)
    }

    @Test
    func testDownsamplingAndOnDemandOriginal() async throws {
        let url = try writeImage("large.jpg", type: .jpeg, width: 1600, height: 900)
        let decoder = ImageDecoder()
        let thumbnail = try await decoder.load(url, quality: .screen(maxPixelDimension: 320))
        #expect(thumbnail.pixelSize == CGSize(width: 1600, height: 900))
        #expect(thumbnail.image.width == 320)
        #expect(thumbnail.image.height == 180)
        #expect(!(thumbnail.isFullResolution))
        let original = try await decoder.load(url, quality: .original)
        #expect(original.image.width == 1600)
        #expect(original.image.height == 900)
        #expect(original.isFullResolution)
    }

    @Test
    func testEXIFRotationAppliesToImageAndPixelSize() async throws {
        let url = try writeImage("rotated.jpg", type: .jpeg, orientation: 6)
        let decoded = try await ImageDecoder().load(url, quality: .original)
        #expect(decoded.pixelSize == CGSize(width: 40, height: 80))
        #expect(decoded.image.width == 40)
        #expect(decoded.image.height == 80)
    }

    @Test(.enabled(if: (CGImageSourceCopyTypeIdentifiers() as! [String]).contains("com.adobe.raw-image"),
                   "This system does not advertise DNG decoding"))
    func testLinearDNGDecode() async throws {
        let url = try #require(Bundle.module.url(forResource: "linear", withExtension: "dng", subdirectory: "Fixtures"))
        #expect(MediaFileTypes.kind(for: url) == .image)
        let decoded = try await ImageDecoder().load(url, quality: .screen(maxPixelDimension: 128))
        #expect(decoded.pixelSize == CGSize(width: 256, height: 192))
        #expect(max(decoded.image.width, decoded.image.height) <= 128)
        #expect(decoded.image.width > 0)
    }

    @Test
    func testCorruptRAWAndRasterDoNotBreakSubsequentDecodes() async throws {
        let decoder = ImageDecoder()
        for filename in ["corrupt.png", "unknown-camera.cr3", "corrupt.dng"] {
            let url = try makeFile(filename, data: Data("not an image".utf8))
            do {
                _ = try await decoder.load(url, quality: .original)
                Issue.record("Corrupt input should fail")
            } catch let error as ImageDecodeError {
                #expect(error.errorDescription != nil)
            }
        }
        let valid = try writeImage("valid.png")
        let decoded = try await decoder.load(valid, quality: .original)
        #expect(decoded.image.width == 80)
    }

    @Test
    func testMissingFileReportsReadError() async throws {
        do {
            _ = try await ImageDecoder().load(fixtureDirectory.appendingPathComponent("missing.jpg"), quality: .original)
            Issue.record("Expected unreadable file")
        } catch let error as ImageDecodeError {
            #expect(error == .unreadableFile)
        }
    }

    @Test
    func testCancellationResumesBeforeNativeDecodeReturnsAndDoesNotCache() async throws {
        let started = TestSignal()
        let finished = TestSignal()
        let cancelled = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { _, _ in
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            finished.signal()
            return image
        }
        let url = fixtureDirectory.appendingPathComponent("slow.png")
        let request = Task {
            do {
                _ = try await decoder.load(url, quality: .original)
                Issue.record("Cancelled request returned an image")
            } catch is CancellationError {
                cancelled.signal()
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        try await waitFor([started], timeout: 2)
        request.cancel()
        try await waitFor([cancelled], timeout: 1)
        gate.signal()
        try await waitFor([finished], timeout: 2)
        await request.value
        let cache = await decoder.cachedURLs
        #expect(cache.isEmpty)
    }

    @Test
    func testResetRejectsOldDirectoryResults() async throws {
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { _, _ in
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            return image
        }
        let request = Task { try await decoder.load(fixtureDirectory.appendingPathComponent("old.png"), quality: .original) }
        try await waitFor([started], timeout: 2)
        await decoder.reset()
        gate.signal()
        do {
            _ = try await request.value
            Issue.record("Reset must invalidate the in-flight request")
        } catch is CancellationError {
        }
        let cache = await decoder.cachedURLs
        #expect(cache.isEmpty)
    }

    @Test
    func testPrefetchIsLimitedToTwoNeighborsAndCached() async throws {
        let recorder = DecodeRecorder()
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { request, _ in
            recorder.record(request.url)
            return image
        }
        let urls = (0...3).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        let quality = DecodeQuality.screen(maxPixelDimension: 512)
        _ = try await decoder.load(urls[0], quality: quality)
        await decoder.prefetch(Array(urls.dropFirst()), quality: quality)
        try await waitUntil { await decoder.cachedURLs.count == 3 }
        #expect(Set(recorder.urls) == Set(urls.prefix(3)))
        _ = try await decoder.load(urls[1], quality: quality)
        #expect(recorder.urls.count == 3, "Navigating to a prefetched neighbor should use its cache")
    }

    @Test
    func testCurrentRequestDoesNotWaitBehindPrefetch() async throws {
        let neighborStarted = TestSignal()
        let currentStarted = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        let neighbor = fixtureDirectory.appendingPathComponent("neighbor.png")
        let current = fixtureDirectory.appendingPathComponent("current.png")
        let queued = fixtureDirectory.appendingPathComponent("queued.png")
        let recorder = DecodeRecorder()
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder { request, _ in
            let url = request.url
            recorder.record(url)
            if url == neighbor {
                neighborStarted.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            if url == current { currentStarted.signal() }
            return image
        }
        await decoder.prefetch([neighbor], quality: .screen(maxPixelDimension: 512))
        try await waitFor([neighborStarted], timeout: 2)
        // 在第一个预取确定运行后再加入第二个，避免把 Task 调度顺序当成队列保证。
        await decoder.prefetch([neighbor, queued], quality: .screen(maxPixelDimension: 512))
        let request = Task { try await decoder.load(current, quality: .original) }
        try await waitFor([currentStarted], timeout: 1)
        gate.signal()
        _ = try await request.value
        #expect(!(recorder.urls.contains(queued)), "Cancelled queued prefetch should never enter ImageIO")
    }

    @Test
    func testCacheEnforcesCountAndByteLimits() async throws {
        let bitmap = try testBitmap()
        let image = DecodedImage(image: bitmap, pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder(cacheCapacity: 2, byteBudget: image.memoryCost * 2) { _, _ in image }
        let urls = (0...2).map { fixtureDirectory.appendingPathComponent("\($0).png") }
        for url in urls { _ = try await decoder.load(url, quality: .original) }
        let cache = await decoder.cachedURLs
        let bytes = await decoder.cachedByteCount
        #expect(cache == Set(urls.suffix(2)))
        #expect(bytes <= image.memoryCost * 2)

        let noRoom = ImageDecoder(byteBudget: image.memoryCost - 1) { _, _ in image }
        _ = try await noRoom.load(urls[0], quality: .original)
        let oversizedCache = await noRoom.cachedURLs
        #expect(oversizedCache.isEmpty, "Oversized original remains displayable without a cached copy")
    }

    @Test
    func testLargerThumbnailAndOriginalReuseButNotReverse() async throws {
        let url = try writeImage("large.png", width: 1024, height: 768)
        let recorder = DecodeRecorder()
        let decoder = ImageDecoder { request, cancelled in
            recorder.record(request.url)
            return try ImageDecoder.decode(request, isCancelled: cancelled)
        }
        _ = try await decoder.load(url, quality: .screen(maxPixelDimension: 512))
        _ = try await decoder.load(url, quality: .screen(maxPixelDimension: 256))
        #expect(recorder.urls.count == 1)
        _ = try await decoder.load(url, quality: .original)
        #expect(recorder.urls.count == 2)
        _ = try await decoder.load(url, quality: .screen(maxPixelDimension: 2048))
        #expect(recorder.urls.count == 2)
    }
}
