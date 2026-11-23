import Foundation
import Testing
@testable import MediaView

@Suite(.serialized)
final class SelectionExporterTests: FixtureTestCase {
    @Test
    func testCopiesOriginalBytesResolvesSameNamesAndNeverReusesOutputDirectory() async throws {
        let a = try makeFile("one/same.jpg", data: Data([1, 2, 3]))
        let b = try makeFile("two/same.jpg", data: Data([4, 5, 6]))
        let root = try makeFile("original.raw", data: Data([7, 8, 9]))
        let result = try await SelectionExporter.export([a, b, root], rootName: "旅行", destination: fixtureDirectory)
        #expect(result.failures.isEmpty && result.copied.count == 3 && !result.cancelled)
        #expect(result.copied.map(\.lastPathComponent) == ["same.jpg", "same（2）.jpg", "original.raw"])
        for (source, output) in zip([a, b, root], result.copied) {
            #expect(try Data(contentsOf: source) == Data(contentsOf: output))
        }
        let again = try await SelectionExporter.export([a], rootName: "旅行", destination: fixtureDirectory)
        #expect(again.directory != result.directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.directory.path).count == 3)
        #expect(try Data(contentsOf: again.copied[0]) == Data([1, 2, 3]))
    }

    @Test
    func testFailureCleansPartialFileAndContinuesWithRemainingPhotos() async throws {
        let a = try makeFile("bad.jpg", data: Data([1]))
        let b = try makeFile("good.jpg", data: Data([2]))
        let missing = fixtureDirectory.appendingPathComponent("missing.jpg")
        let result = try await SelectionExporter.export([a, missing, b], rootName: "照片", destination: fixtureDirectory,
            copy: { source, output in
                if source == a {
                    try Data([0]).write(to: output)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try FileManager.default.copyItem(at: source, to: output)
            })
        #expect(result.failures.map(\.source) == [a, missing])
        #expect(result.copied.map(\.lastPathComponent) == ["good.jpg"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.directory.path) == ["good.jpg"])
        #expect(try Data(contentsOf: a) == Data([1]))
    }

    @Test
    func testCancellationFinishesCurrentCopyAndKeepsCompleteFiles() async throws {
        let urls = try (1...3).map { try makeFile("\($0).png", data: Data([UInt8($0)])) }
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let destination = fixtureDirectory
        let task = Task.detached {
            try await SelectionExporter.export(urls, rootName: "旅行", destination: destination, copy: { source, output in
                if source == urls[0] { started.signal(); _ = gate.wait(timeout: .now() + 5) }
                try FileManager.default.copyItem(at: source, to: output)
            })
        }
        try await waitFor([started], timeout: 3)
        task.cancel()
        gate.signal()
        let result = try await task.value
        #expect(result.cancelled && result.copied.count == 1 && result.failures.isEmpty)
        #expect(try Data(contentsOf: result.copied[0]) == Data([1]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.directory.path).count == 1)
    }

    @Test
    func testInvalidDestinationAndReplacedSymlinkDoNotModifyOriginals() async throws {
        let original = try makeFile("photo.jpg", data: Data([1, 2]))
        do {
            _ = try await SelectionExporter.export([original], rootName: "照片", destination: original)
            Issue.record("A file cannot be used as an export directory")
        } catch {}
        let link = fixtureDirectory.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let result = try await SelectionExporter.export([link, original], rootName: "照片", destination: fixtureDirectory)
        #expect(result.failures.map(\.source) == [link] && result.copied.count == 1)
        #expect(try Data(contentsOf: original) == Data([1, 2]))
    }

    @Test(arguments: [false, true])
    func testExportRechecksCachedFileTypeAfterSourceReplacement(withDirectory: Bool) async throws {
        var photo = try makeFile("photo.jpg", data: Data([1, 2]))
        let other = try makeFile("other.jpg", data: Data([3, 4]))
        // 目录扫描会在 URL 上缓存属性；之后同一路径可能被替换成目录或符号链接。
        photo.setTemporaryResourceValue(true, forKey: .isRegularFileKey)
        photo.setTemporaryResourceValue(false, forKey: .isSymbolicLinkKey)
        try FileManager.default.removeItem(at: photo)
        if withDirectory {
            try FileManager.default.createDirectory(at: photo, withIntermediateDirectories: false)
        } else {
            try FileManager.default.createSymbolicLink(at: photo, withDestinationURL: other)
        }
        let result = try await SelectionExporter.export([photo], rootName: "照片", destination: fixtureDirectory)
        #expect(result.copied.isEmpty && result.failures.map(\.source) == [photo])
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.directory.path).isEmpty)
        #expect(try Data(contentsOf: other) == Data([3, 4]))
    }
}
