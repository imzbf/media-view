import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MediaView

@Suite(.serialized)
final class DuplicateScannerTests: FixtureTestCase {
    private var store: DuplicateStore { DuplicateStore(directory: fixtureDirectory.appendingPathComponent(".checks")) }

    @Test
    func testRenamedCopiesAcrossSubdirectoriesAndSameNamesWithDifferentContents() async throws {
        let original = try writeDuplicatePhoto("phone-a/photo.jpg")
        try makeFile("phone-b/renamed.jpg", data: Data(contentsOf: original))
        try writeDuplicatePhoto("phone-b/photo.jpg", variant: 1)
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: store)
        #expect(result.fileCount == 3 && result.issues.isEmpty)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1 && group.match == .exact)
        #expect(Set(group.files.map(\.path)) == ["phone-a/photo.jpg", "phone-b/renamed.jpg"])
    }

    @Test
    func testCompressionScalingFormatsAndMetadataChangesAreSuspectedCopies() async throws {
        try writeDuplicatePhoto("original.png", type: .png)
        try writeDuplicatePhoto("forwarded.jpg", width: 300, height: 200, quality: 0.6)
        try writeDuplicatePhoto("metadata.jpg", date: "2024:02:03 04:05:06")
        try writeDuplicatePhoto("another-shot.jpg", variant: 1)
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: store)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1 && group.match == .similar)
        #expect(Set(group.files.map(\.path)) == ["original.png", "forwarded.jpg", "metadata.jpg"])
        #expect(result.issues.isEmpty)
    }

    @Test
    func testOrientationMetadataIsAppliedBeforeComparison() async throws {
        let base = try duplicatePattern()
        let context = try #require(CGContext(data: nil, width: base.height, height: base.width,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(base.width))
        context.rotate(by: -.pi / 2)
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let rotated = try #require(context.makeImage())
        let a = try saveDuplicatePhoto("orientation.jpg", image: base, orientation: 6)
        let b = try saveDuplicatePhoto("pixels.jpg", image: rotated)
        let first = try await DuplicateVisual.read(a, kind: .photo)
        let second = try await DuplicateVisual.read(b, kind: .photo)
        #expect(first.matches(second))
    }

    @Test
    func testVideosUseDurationAndSeveralFramesInsteadOfOnlyTheCover() async throws {
        let source = try await writeVideo("original.mp4", width: 640, height: 360, frames: 36)
        let copy = try await transcodeDuplicateVideo(source, name: "forwarded.mp4")
        let different = try await writeVideo("different.mp4", width: 640, height: 360, frames: 36, changesToBlueAfter: 4)
        let long = try await writeVideo("long.mp4", width: 640, height: 360, frames: 72)
        let a = try await DuplicateVisual.read(source, kind: .video)
        let b = try await DuplicateVisual.read(copy, kind: .video)
        let c = try await DuplicateVisual.read(different, kind: .video)
        let d = try await DuplicateVisual.read(long, kind: .video)
        #expect(a.frames.count == 5 && a.matches(b))
        #expect(!a.matches(c) && !a.matches(d))
        try makeFile("nested/renamed.mov", data: Data(contentsOf: source))
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: store)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1 && group.match == .similar)
        #expect(Set(group.files.map(\.path)) == ["original.mp4", "forwarded.mp4", "nested/renamed.mov"])
    }

    @Test
    func testAnimatedImagesUseOnlyWholeFileIdentity() async throws {
        let a = try writeGIF("one.gif", delays: [0.1, 0.2])
        try makeFile("copy.gif", data: Data(contentsOf: a))
        try writeGIF("other.gif", delays: [0.1, 0.3])
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: store)
        #expect(result.groups.count == 1 && result.groups.first?.match == .exact)
        #expect(result.groups.first?.files.allSatisfy { $0.visual?.frames.isEmpty == true } == true)
    }

    @Test
    func testUnchangedFingerprintsAreReusedAndModifiedFilesAreReanalyzed() async throws {
        let a = try writeDuplicatePhoto("one.jpg")
        let b = try makeFile("copy.jpg", data: Data(contentsOf: a))
        let calls = DecodeRecorder()
        let scanner = DuplicateScanner(analyzer: { url, kind in
            calls.record(url)
            return try await DuplicateVisual.read(url, kind: kind)
        })
        let store = store
        let first = try await scanner.scan(root: fixtureDirectory, store: store)
        #expect(calls.urls.count == 1, "完全相同的多个副本只分析一次画面")
        let second = try await scanner.scan(root: fixtureDirectory, store: store)
        #expect(calls.urls.count == 1 && second.groups.map(\.id) == first.groups.map(\.id))
        try writeDuplicatePhoto(b.lastPathComponent, variant: 1)
        let third = try await scanner.scan(root: fixtureDirectory, store: store)
        #expect(calls.urls.count == 2 && third.groups.isEmpty)
    }

    @Test
    func testSimilarGroupingDoesNotJoinATransitiveChain() throws {
        let image = try testBitmap()
        let first = try DuplicateFrame(image)
        // 通过真实画面的亮度阶梯制造 A≈B、B≈C、A≉C；分组必须保持两两相符。
        let candidates = try (1...30).map { offset -> DuplicateFrame in
            try DuplicateFrame(testBitmap(red: 1, blue: CGFloat(offset) / 100))
        }
        let middle = try #require(candidates.last { first.matches($0, video: false) })
        let tail = try #require(candidates.first { middle.matches($0, video: false) && !first.matches($0, video: false) })
        let stamp = DuplicateFileStamp(device: 1, inode: 1, size: 1, modifiedSeconds: 0, modifiedNanos: 0, changedSeconds: 0, changedNanos: 0)
        let files = [first, middle, tail].enumerated().map { index, frame in
            DuplicateFile(path: "\(index).jpg", kind: .photo, stamp: stamp,
                visual: DuplicateVisual(width: 80, height: 40, duration: nil, frames: [frame]))
        }
        let groups = try DuplicateScanner.makeGroups(files: files, units: [[0], [1], [2]])
        #expect(groups.count == 1 && groups[0].files.count == 2)
    }

    @Test
    func testFiveThousandFilesKeepAnalysisBoundedAndCancelPromptly() async throws {
        for index in 0..<5000 { try makeFile("\(index).\(index.isMultiple(of: 2) ? "jpg" : "mp4")", data: Data("file-\(index)".utf8)) }
        let meter = DuplicateWorkMeter()
        let scanner = DuplicateScanner(analyzer: { _, _ in
            await meter.enter()
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { await meter.leave(); throw error }
            await meter.leave()
            throw CancellationError()
        })
        let root = fixtureDirectory, store = store
        let task = Task { try await scanner.scan(root: root, store: store) }
        try await waitUntil(timeout: 15) { await meter.active == 2 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await meter.maximum == 2)
        #expect(await meter.active == 0)
        var index = DuplicateHashIndex()
        var hashes: [UInt64] = []
        var seed: UInt64 = 123456789
        for value in 0..<5000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            hashes.append(seed)
            index.insert(seed, value: value)
        }
        #expect(index.matches(hashes[2345], radius: 6).contains(2345))
        #expect(index.matches(hashes[2345], radius: 6).count < 10)
    }
}

actor DuplicateWorkMeter {
    private(set) var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

extension FixtureTestCase {
    /// 不用纯色正例校准感知阈值，保留非对称形状、细节和颜色变化来模拟真实转传。
    func duplicatePattern(width: Int = 600, height: Int = 400, variant: Int = 0) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(width) / 600, y: CGFloat(height) / 400)
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(red: 0.12, green: 0.2, blue: 0.45, alpha: 1),
                     CGColor(red: 0.82, green: 0.65, blue: 0.3, alpha: 1)] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 400), options: [])
        for i in 0..<24 {
            context.setFillColor(CGColor(red: CGFloat((i * 37 + 41) % 100) / 100,
                green: CGFloat((i * 23 + 17) % 100) / 100, blue: CGFloat((i * 53 + 11) % 100) / 100, alpha: 0.9))
            let rectangle = CGRect(x: (i * 83 + 31) % 530, y: (i * 47 + 23) % 330, width: 30 + i % 7 * 9, height: 22 + i % 5 * 13)
            if i.isMultiple(of: 2) { context.fillEllipse(in: rectangle) } else { context.fill(rectangle) }
        }
        if variant != 0 {
            context.setFillColor(CGColor(red: 0.05, green: 0.9, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 160, y: 50, width: 260, height: 270))
        }
        return try #require(context.makeImage())
    }

    @discardableResult
    func writeDuplicatePhoto(_ name: String, width: Int = 600, height: Int = 400,
                             type: UTType = .jpeg, quality: Double = 0.92, variant: Int = 0,
                             date: String = "2025:01:02 03:04:05") throws -> URL {
        try saveDuplicatePhoto(name, image: duplicatePattern(width: width, height: height, variant: variant),
            type: type, quality: quality, date: date)
    }

    @discardableResult
    func saveDuplicatePhoto(_ name: String, image: CGImage, type: UTType = .jpeg,
                            quality: Double = 0.92, orientation: Int = 1, date: String = "2025:01:02 03:04:05") throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url.standardizedFileURL
    }

    func transcodeDuplicateVideo(_ input: URL, name: String) async throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetLowQuality))
        if #available(macOS 15.0, *) {
            try await exporter.export(to: url, as: .mp4)
        } else {
            exporter.outputURL = url
            exporter.outputFileType = .mp4
            await exporter.export()
            try #require(exporter.status == .completed)
        }
        return url
    }
}
