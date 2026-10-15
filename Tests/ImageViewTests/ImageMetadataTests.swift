import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ImageView

@Suite(.serialized)
final class ImageMetadataTests: FixtureTestCase {
    @Test
    func testBasicMetadataDoesNotDecodePixelsOrFillImageCaches() async throws {
        let url = try writeImage("plain.png", width: 240, height: 120)
        let recorder = DecodeRecorder()
        let decoder = ImageDecoder(loader: { request, _ in
            recorder.record(request.url)
            throw ImageDecodeError.invalidImage
        })
        let metadata = try await decoder.metadata(of: url)
        let fields = Dictionary(uniqueKeysWithValues: metadata.fields.map { ($0.name, $0.value) })
        #expect(fields["格式"] == "PNG" && fields["尺寸"] == "240 × 120")
        #expect(fields["大小"] != nil && fields["修改时间"] != nil)
        #expect(fields["相机"] == nil && fields["拍摄时间"] == nil)
        #expect(recorder.urls.isEmpty)
        #expect(await decoder.cachedByteCount == 0)
        #expect(await decoder.thumbnailCachedByteCount == 0)
    }

    @Test
    func testEXIFFieldsAndOrientedDimensions() async throws {
        let url = fixtureDirectory.appendingPathComponent("camera.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera", kCGImagePropertyTIFFModel: "Camera One"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:14 12:34:56",
                kCGImagePropertyExifLensModel: "Prime 50mm",
                kCGImagePropertyExifFocalLength: 50,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 1.0 / 125,
                kCGImagePropertyExifISOSpeedRatings: [200],
            ],
        ]
        CGImageDestinationAddImage(destination, try testBitmap(), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let result = try await ImageDecoder().metadata(of: url)
        let fields = Dictionary(uniqueKeysWithValues: result.fields.map { ($0.name, $0.value) })
        #expect(fields["尺寸"] == "40 × 80" && fields["相机"] == "Camera One")
        #expect(fields["镜头"] == "Prime 50mm" && fields["焦距"] == "50 mm")
        #expect(fields["光圈"] == "f/2.8" && fields["快门"] == "1/125 s" && fields["ISO"] == "200")
        #expect(fields["拍摄时间"] == "2026:10:14 12:34:56")
    }

    @Test
    func testMetadataCancellationSharesBackgroundQueueAndDoesNotBlockMainImage() async throws {
        let url = fixtureDirectory.appendingPathComponent("image.png")
        let metadataStarted = TestSignal()
        let thumbnailStarted = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let bitmap = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let decoder = ImageDecoder(loader: { request, _ in
            if case .thumbnail = request { thumbnailStarted.signal() }
            return bitmap
        }, metadataLoader: { _, _ in
            metadataStarted.signal()
            _ = gate.wait(timeout: .now() + 5)
            return ImageMetadata(fields: [])
        })
        let metadata = Task { try await decoder.metadata(of: url) }
        try await waitFor([metadataStarted], timeout: 2)
        let thumbnail = Task { try await decoder.thumbnail(url, maxPixelDimension: 100) }
        _ = try await decoder.load(url, quality: .original)
        #expect(!thumbnailStarted.isSet, "Metadata and thumbnails must share the same native-call slot")
        metadata.cancel()
        await #expect(throws: CancellationError.self) { try await metadata.value }
        #expect(!thumbnailStarted.isSet, "Cancellation cannot free a still-running native-call slot")
        gate.signal()
        _ = try await thumbnail.value
        #expect(await decoder.cachedURLs == [url])
    }

    @Test
    func testURLInvalidationReloadsAllQualitiesAndLeavesOtherFilesCached() async throws {
        let url = try writeImage("image.png", width: 400, height: 200)
        let other = try writeImage("other.png")
        let decoder = ImageDecoder()
        _ = try await decoder.load(url, quality: .screen(maxPixelDimension: 200))
        _ = try await decoder.load(url, quality: .original)
        _ = try await decoder.thumbnail(url, maxPixelDimension: 100)
        _ = try await decoder.load(other, quality: .original)
        try writeImage("image.png", width: 300, height: 150, red: 0, blue: 1)
        await decoder.invalidate([url])
        #expect(await decoder.cachedURLs == [other])
        #expect(await decoder.thumbnailCachedURLs.isEmpty)
        let fresh = try await decoder.load(url, quality: .original)
        let thumbnail = try await decoder.thumbnail(url, maxPixelDimension: 100)
        #expect(fresh.pixelSize == CGSize(width: 300, height: 150))
        #expect(try testPixels(fresh.image)[2] > 240 && testPixels(thumbnail.image)[2] > 240)
    }

    @Test
    func testInvalidationRejectsLateMainAndThumbnailForSameURL() async throws {
        let url = fixtureDirectory.appendingPathComponent("image.png")
        let mainStarted = TestSignal()
        let thumbnailStarted = TestSignal()
        let mainGate = DispatchSemaphore(value: 0)
        let thumbnailGate = DispatchSemaphore(value: 0)
        defer { mainGate.signal(); thumbnailGate.signal() }
        let old = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: true)
        let fresh = DecodedImage(image: try testBitmap(red: 0, blue: 1), pixelSize: old.pixelSize, isFullResolution: true)
        let decoder = ImageDecoder(loader: { request, _ in
            switch request {
            case .mainImage where !mainStarted.isSet:
                mainStarted.signal()
                _ = mainGate.wait(timeout: .now() + 5)
                return old
            case .thumbnail where !thumbnailStarted.isSet:
                thumbnailStarted.signal()
                _ = thumbnailGate.wait(timeout: .now() + 5)
                return old
            default: return fresh
            }
        })
        let oldMain = Task { try await decoder.load(url, quality: .original) }
        let oldThumbnail = Task { try await decoder.thumbnail(url, maxPixelDimension: 100) }
        try await waitFor([mainStarted, thumbnailStarted], timeout: 2)
        await decoder.invalidate([url])
        await #expect(throws: CancellationError.self) { try await oldMain.value }
        await #expect(throws: CancellationError.self) { try await oldThumbnail.value }
        let current = Task { try await decoder.load(url, quality: .original) }
        let thumbnail = Task { try await decoder.thumbnail(url, maxPixelDimension: 100) }
        mainGate.signal()
        thumbnailGate.signal()
        let loaded = try await current.value
        let small = try await thumbnail.value
        #expect(try testPixels(loaded.image)[2] > 240 && testPixels(small.image)[2] > 240)
        #expect(await decoder.cachedURLs == [url])
        #expect(await decoder.thumbnailCachedURLs == [url])
    }
}
