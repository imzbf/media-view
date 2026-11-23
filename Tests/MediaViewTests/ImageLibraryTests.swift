import Foundation
import Darwin
import Testing
@testable import MediaView

@Suite(.serialized)
final class ImageLibraryTests: FixtureTestCase {
    @Test
    func testRecursiveScanFiltersHiddenPackagesLinksAndUnsupportedFiles() async throws {
        let first = try makeFile("visible.JPG")
        let nested = try makeFile("album/deep/image.png")
        try makeFile(".hidden.jpg")
        try makeFile(".private/hidden.png")
        try makeFile("Example.app/Contents/inside.jpg")
        try makeFile("notes.txt")
        try makeFile("document.pdf")
        try makeFile("unknown.xyz")
        try FileManager.default.createSymbolicLink(at: fixtureDirectory.appendingPathComponent("album/loop"),
                                                   withDestinationURL: fixtureDirectory)

        let snapshot = try await finalSnapshot(opening: [fixtureDirectory])
        #expect(Set(snapshot.images) == [first, nested])
        #expect(snapshot.isComplete)
    }

    @Test
    func testLocalizedNumericSortAndPathTieBreak() async throws {
        let ten = try makeFile("photo10.jpg")
        let twoB = try makeFile("b/photo2.jpg")
        let twoA = try makeFile("a/photo2.jpg")
        let one = try makeFile("photo1.jpg")
        let snapshot = try await finalSnapshot(opening: [fixtureDirectory])
        #expect(snapshot.images == [one, twoA, twoB, ten])
    }

    @Test
    func testOpeningSingleImageScansParentRecursivelyAndAnchorsURL() async throws {
        try makeFile("outside.jpg")
        let selected = try makeFile("album/photo10.jpg")
        let sibling = try makeFile("album/photo2.jpg")
        let nested = try makeFile("album/sub/photo1.png")
        let snapshot = try await finalSnapshot(opening: [selected])
        #expect(snapshot.images == [nested, sibling, selected])
        #expect(snapshot.currentIndex(keeping: nil) == 2)
        #expect(snapshot.currentIndex(keeping: sibling) == 1)
        #expect(snapshot.preferredImage == selected)
    }

    @Test
    func testReanchoringUsesURLInsteadOfPreviousIndex() {
        let first = URL(fileURLWithPath: "/photos/1.jpg")
        let second = URL(fileURLWithPath: "/photos/2.jpg")
        let snapshot = LibrarySnapshot(directory: first.deletingLastPathComponent(), images: [first, second],
                                       preferredImage: first, isComplete: true, skippedPaths: 0)
        // 扫描期间用户已切到第二张，最终排序不得跳回最初打开的文件。
        #expect(snapshot.currentIndex(keeping: second) == 1)
    }

    @Test
    func testOnlyFirstValidDroppedItemIsOpened() async throws {
        let unsupported = try makeFile("notes.txt")
        let first = try makeFile("first/image.png")
        let other = try makeFile("other/image.jpg")
        let snapshot = try await finalSnapshot(opening: [unsupported, first, other])
        #expect(snapshot.images == [first])
        #expect(snapshot.preferredImage == first)
    }

    @Test
    func testEmptyAndNoImageDirectories() async throws {
        let empty = try await finalSnapshot(opening: [fixtureDirectory])
        #expect(empty.images.isEmpty)
        #expect(empty.currentIndex(keeping: nil) == nil)
        try makeFile("notes.txt")
        let noImages = try await finalSnapshot(opening: [fixtureDirectory])
        #expect(noImages.images.isEmpty)
    }

    @Test
    func testMissingAndUnsupportedInputsReportError() async throws {
        let unsupported = try makeFile("notes.txt")
        do {
            _ = try await finalSnapshot(opening: [fixtureDirectory.appendingPathComponent("missing"), unsupported])
            Issue.record("Expected unsupported input error")
        } catch LibraryError.noSupportedInput {
        }
    }

    @Test(.enabled(if: getuid() != 0, "POSIX permission checks require an unprivileged user"))
    func testUnreadableRootAndSubdirectory() async throws {
        let readable = try makeFile("visible.jpg")
        try makeFile("private/secret.jpg")
        let privateDirectory = fixtureDirectory.appendingPathComponent("private")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: privateDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDirectory.path) }
        try #require(!FileManager.default.isReadableFile(atPath: privateDirectory.path))
        let snapshot = try await finalSnapshot(opening: [fixtureDirectory])
        #expect(snapshot.images == [readable])
        #expect(snapshot.skippedPaths > 0)
        do {
            _ = try await finalSnapshot(opening: [privateDirectory])
            Issue.record("Expected unreadable directory error")
        } catch LibraryError.unreadableDirectory(let url) {
            #expect(url == privateDirectory)
        }
    }

    @Test
    func testKnownRasterAndRawTypes() {
        for ext in ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "webp", "dng", "cr2", "nef", "arw"] {
            #expect(MediaFileTypes.kind(for: URL(fileURLWithPath: "/image.\(ext)")) == .image, "\(ext)")
        }
        #expect(MediaFileTypes.kind(for: URL(fileURLWithPath: "/file.txt")) == nil)
    }

    @Test
    func testShallowScanKeepsRootFilesAndSingleImageSelection() async throws {
        let first = try makeFile("photo1.png")
        let selected = try makeFile("photo2.png")
        try makeFile("nested/photo3.png")
        let options = LibraryOptions(includesSubdirectories: false, sort: .nameDescending)
        var result: LibrarySnapshot?
        for try await snapshot in ImageLibrary.scan(opening: [selected], options: options) { result = snapshot }
        let snapshot = try #require(result)
        #expect(snapshot.directory.path == fixtureDirectory.path)
        #expect(snapshot.images == [selected, first])
        #expect(snapshot.currentIndex(keeping: nil) == 0)
    }

    @Test
    func testDateSortUsesFreshAttributesStableTiesAndMissingDatesLast() throws {
        let first = try makeFile("a.png")
        let second = try makeFile("b.png")
        let third = try makeFile("c.png")
        let missing = fixtureDirectory.appendingPathComponent("missing.png")
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        for url in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: third.path)
        let urls = [missing, second, third, first]
        #expect(try ImageLibrary.sortedImages(urls, by: .modifiedNewest) == [third, first, second, missing])
        #expect(try ImageLibrary.sortedImages(urls, by: .modifiedOldest) == [first, second, third, missing])
        _ = try first.resourceValues(forKeys: [.contentModificationDateKey])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: first.path)
        #expect(try ImageLibrary.sortedImages(urls, by: .modifiedNewest) == [first, third, second, missing])
    }

    @Test
    func testNameSearchUsesOnlyNamesAndKeepsDuplicatePathsInLibraryOrder() throws {
        let urls = ["目录匹配/other.png", "a/相册 IMG2.PNG", "b/相册 IMG2.PNG", "IMG10.jpg"]
            .map { fixtureDirectory.appendingPathComponent($0) }
        #expect(try ImageLibrary.matchingImages(in: urls, query: "img") == Array(urls[1...]))
        #expect(try ImageLibrary.matchingImages(in: urls, query: "相册") == Array(urls[1...2]))
        #expect(try ImageLibrary.matchingImages(in: urls, query: "目录匹配").isEmpty)
        #expect(try ImageLibrary.matchingImages(in: urls, query: "  ").isEmpty)
        #expect(try ImageLibrary.matchingImages(in: urls, query: "missing").isEmpty)
    }
}
