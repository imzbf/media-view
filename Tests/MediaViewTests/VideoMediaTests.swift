import AppKit
import AVFoundation
import Testing
@testable import MediaView

@Suite(.serialized)
final class VideoMediaTests: FixtureTestCase {
    @Test
    func testMixedScanUsesSharedTypesSortSearchAndScope() async throws {
        let image = try makeFile("1-photo.PNG")
        let video = try makeFile("2-video.MP4")
        let movie = try makeFile("3-movie.mov")
        let nested = try makeFile("album/4-video.m4v")
        for name in ["unsupported.mkv", "unsupported.webm", "sound.mp3", ".hidden.mp4", "Example.app/inside.mov"] {
            try makeFile(name)
        }
        #expect(MediaFileTypes.kind(for: image) == .image)
        for url in [video, movie, nested] {
            #expect(MediaFileTypes.kind(for: url) == .video)
        }
        let snapshot = try await finalSnapshot(opening: [video])
        #expect(snapshot.images == [image, video, movie, nested] && snapshot.preferredImage == video)
        #expect(snapshot.currentIndex(keeping: nil) == 1)
        #expect(try ImageLibrary.matchingImages(in: snapshot.images, query: "VIDEO") == [video, nested])
        var shallow: LibrarySnapshot?
        for try await value in ImageLibrary.scan(opening: [video], options: .init(includesSubdirectories: false, sort: .nameDescending)) {
            shallow = value
        }
        #expect(shallow?.images == [movie, video, image] && shallow?.currentIndex(keeping: video) == 1)
    }

    @Test(arguments: ["sample.mp4", "sample.mov", "sample.M4V"])
    func testVideoMetadataAndOrientedThumbnailUseNativeLoader(name: String) async throws {
        let rotated = name.hasSuffix("mov")
        let url = try await writeVideo(name, rotated: rotated)
        let decoder = ImageDecoder(loader: { _, _ in
            Issue.record("Video requests must not reach ImageIO")
            throw ImageDecodeError.unsupportedFormat
        })
        let metadata = try await decoder.metadata(of: url)
        let fields = Dictionary(uniqueKeysWithValues: metadata.fields.map { ($0.name, $0.value) })
        #expect(fields["格式"] == url.pathExtension.uppercased())
        #expect(fields["尺寸"] == (rotated ? "90 × 160" : "160 × 90"))
        #expect(fields["时长"] == "0:02" && fields["大小"] != nil && fields["修改时间"] != nil)
        let thumbnail = try await decoder.thumbnail(url, maxPixelDimension: 64)
        #expect(thumbnail.image.width <= 64 && thumbnail.image.height <= 64)
        #expect((thumbnail.image.height > thumbnail.image.width) == rotated)
        #expect(await decoder.cachedURLs.isEmpty)
        #expect(await decoder.thumbnailCachedURLs == [url])
        #expect(await decoder.thumbnailCachedByteCount <= 32 * 1024 * 1024)
    }

    @Test
    func testReloadInvalidatesVideoThumbnailAndMetadata() async throws {
        let url = try await writeVideo()
        let decoder = ImageDecoder()
        let first = try await decoder.thumbnail(url, maxPixelDimension: 64)
        #expect(try testPixels(first.image)[0] > 180)
        try await writeVideo(width: 320, height: 180, blue: true)
        await decoder.invalidate([url])
        let fresh = try await decoder.thumbnail(url, maxPixelDimension: 64)
        let metadata = try await decoder.metadata(of: url)
        #expect(try testPixels(fresh.image)[2] > 180)
        #expect(metadata.fields.contains { $0.name == "尺寸" && $0.value == "320 × 180" })
    }

    @Test(arguments: [false, true])
    func testInvalidationRejectsLateVideoThumbnailAndKeepsConcurrencyBound(reset: Bool) async throws {
        let url = fixtureDirectory.appendingPathComponent("slow.mp4")
        let started = TestSignal()
        let secondStarted = TestSignal()
        let gate = VideoTestGate()
        let old = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: false)
        let fresh = DecodedImage(image: try testBitmap(red: 0, blue: 1), pixelSize: old.pixelSize, isFullResolution: false)
        let loader = VideoThumbnailLoader(concurrency: 1) { _, _ in
            if !started.isSet {
                started.signal()
                // 模拟已进入原生解码的工作忽略取消，检验名额与迟到结果都能被正确处理。
                await gate.wait()
                return old
            }
            secondStarted.signal()
            return fresh
        }
        let decoder = ImageDecoder(videoThumbnails: loader)
        let first = Task { try await decoder.thumbnail(url, maxPixelDimension: 64) }
        try await waitFor([started], timeout: 3)
        if reset { await decoder.reset() } else { await decoder.invalidate([url]) }
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task { try await decoder.thumbnail(url, maxPixelDimension: 64) }
        await Task.yield()
        let cached = await decoder.thumbnailCachedURLs
        #expect(!secondStarted.isSet && cached.isEmpty)
        await gate.open()
        let result = try await second.value
        #expect(try testPixels(result.image)[2] > 240)
        #expect(await decoder.thumbnailCachedURLs == [url])
    }

    @Test
    func testVideoIsExcludedFromNeighborImagePrefetch() async throws {
        let image = fixtureDirectory.appendingPathComponent("photo.png")
        let video = fixtureDirectory.appendingPathComponent("video.mp4")
        let recorder = DecodeRecorder()
        let bitmap = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40), isFullResolution: false)
        let decoder = ImageDecoder(loader: { request, _ in recorder.record(request.url); return bitmap })
        await decoder.prefetch([video, image], quality: .screen(maxPixelDimension: 512))
        try await waitUntil { await decoder.cachedURLs == [image] }
        #expect(recorder.urls == [image])
    }

    @MainActor
    @Test
    func testVideoBadgeSurvivesLoadingAndFailureAndResetsOnReuse() {
        _ = NSApplication.shared
        let item = ThumbnailItem()
        item.configure(url: fixtureDirectory.appendingPathComponent("album/video.mp4"), result: nil, relativeDirectory: "album")
        #expect(!item.videoBadge.isHidden && !item.directoryBadge.isHidden)
        #expect(item.view.accessibilityLabel()?.contains("视频") == true)
        item.clearImage()
        item.show(.failure(VideoLoadError.invalidVideo))
        #expect(!item.videoBadge.isHidden && !item.directoryBadge.isHidden)
        item.prepareForReuse()
        #expect(item.videoBadge.isHidden && item.directoryBadge.isHidden)
        item.configure(url: fixtureDirectory.appendingPathComponent("photo.png"), result: nil, relativeDirectory: nil)
        #expect(item.videoBadge.isHidden && item.view.accessibilityLabel() == "photo.png")
    }
}

/// 可控的异步闸门，不阻塞 Swift 执行器线程，用于复现取消后原生回调才到达的顺序。
actor VideoTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
