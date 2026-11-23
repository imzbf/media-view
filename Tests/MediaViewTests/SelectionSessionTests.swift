import AppKit
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class SelectionSessionTests: FixtureTestCase {
    private func makeSession(store: SelectionStore? = nil) -> SelectionSession {
        SelectionSession(root: fixtureDirectory, record: SelectionRecord(rootPath: fixtureDirectory.path),
            store: store ?? SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records")))
    }

    @Test
    func testThreeStatesAdvanceUndoRedoAndFinishWithoutWrapping() async throws {
        let urls = try (1...3).map { try makeFile("\($0).jpg") }
        let session = makeSession()
        session.updatePhotos(urls, complete: true)
        session.mark(.picked)
        #expect(session.status(of: urls[0]) == .picked && session.currentURL == urls[1])
        session.mark(.skipped)
        #expect(session.currentURL == urls[2] && session.counts.reviewed == 2)
        session.undoManager.undo()
        #expect(session.status(of: urls[1]) == .pending && session.currentURL == urls[1])
        #expect(session.filter == .pending && !session.showsGrid)
        session.undoManager.redo()
        #expect(session.status(of: urls[1]) == .skipped && session.currentURL == urls[2])
        session.mark(.picked)
        #expect(session.currentURL == nil && session.visibleURLs.isEmpty)
        #expect(session.counts == SelectionSession.Counts(all: 3, pending: 0, picked: 2, skipped: 1))
        session.undoManager.undo()
        #expect(session.currentURL == urls[2] && session.status(of: urls[2]) == .pending)
        try await session.flush()
    }

    @Test
    func testManualAdvanceReviewRemovalAndIdempotentMark() async throws {
        let urls = try (1...3).map { try makeFile("\($0).png") }
        let session = makeSession()
        session.updatePhotos(urls, complete: true)
        session.setFilter(.all)
        session.setAutoAdvance(false)
        session.mark(.picked)
        #expect(session.currentURL == urls[0])
        session.mark(.picked)
        session.undoManager.undo()
        #expect(session.status(of: urls[0]) == .pending, "Repeated marking must not add an undo step")
        session.undoManager.redo()
        session.mark(.picked, url: urls[2])
        session.setFilter(.picked)
        #expect(session.showsGrid && session.visibleURLs == [urls[0], urls[2]])
        session.mark(.pending, url: urls[2])
        #expect(session.visibleURLs == [urls[0]] && session.showsGrid)
        session.undoManager.undo()
        #expect(session.visibleURLs == [urls[0], urls[2]] && session.showsGrid)
        session.openPhoto(urls[2])
        #expect(!session.showsGrid && session.currentURL == urls[2])
        session.mark(.skipped)
        #expect(session.currentURL == urls[0], "Removing the last visible photo falls back to its predecessor")
        session.undoManager.undo()
        #expect(session.currentURL == urls[2] && !session.showsGrid)
        try await session.flush()
    }

    @Test
    func testSnapshotKeepsMarksAcrossSortRefreshAndMissingFiles() async throws {
        let first = try makeFile("one/same.jpg")
        let second = try makeFile("two/same.jpg")
        let video = try makeFile("video.mp4")
        let added = try makeFile("new.heic")
        let session = makeSession()
        session.updatePhotos([first, second, video], complete: true)
        #expect(session.photos == [first, second])
        session.mark(.picked)
        session.mark(.skipped)
        session.updatePhotos([second, added], complete: false)
        #expect(session.missingURLs.isEmpty)
        session.updatePhotos([second, added], complete: true)
        #expect(session.missingURLs == [first])
        #expect(session.status(of: second) == .skipped && session.status(of: added) == .pending)
        session.setFilter(.picked)
        #expect(session.pickedURLs == [first] && session.visibleURLs == [first])
        session.updatePhotos([added, second, first], complete: true)
        #expect(session.missingURLs.isEmpty && session.status(of: first) == .picked)
        try await session.flush()
    }

    @Test
    func testFlushPersistsLatestStatePositionAndRootIsolation() async throws {
        let urls = try (0..<50).map { try makeFile("\($0).jpg", data: Data("original".utf8)) }
        let store = SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records"))
        let session = makeSession(store: store)
        session.updatePhotos(urls, complete: true)
        // 不等待每次保存，覆盖慢盘时连续变更的合并写入路径。
        for url in urls { session.mark(.picked, url: url) }
        session.setFilter(.picked)
        session.openPhoto(urls[23])
        session.setAutoAdvance(false)
        try await session.flush()
        #expect(session.saveState == .saved)
        let record = try await store.load(root: fixtureDirectory)
        #expect(record == session.record && record.marks.count == urls.count)
        let restored = SelectionSession(root: fixtureDirectory, record: record, store: store)
        restored.updatePhotos(urls, complete: true)
        #expect(restored.currentURL == urls[23] && !restored.showsGrid && !restored.autoAdvance)
        #expect(restored.filter == .picked)
        let other = try await store.load(root: fixtureDirectory.appendingPathComponent("another"))
        #expect(other.marks.isEmpty)
        #expect(try Data(contentsOf: urls[0]) == Data("original".utf8))
    }

    @Test
    func testUndoAfterRefreshRestoresMissingSelectionInExportList() async throws {
        let photo = try makeFile("photo.jpg")
        let session = makeSession()
        session.updatePhotos([photo], complete: true)
        session.mark(.picked)
        session.setFilter(.picked)
        session.mark(.pending, url: photo)
        session.updatePhotos([], complete: true)
        #expect(session.photos.isEmpty)
        session.undoManager.undo()
        #expect(session.pickedURLs == [photo] && session.missingURLs == [photo])
        #expect(session.currentURL == photo)
        session.undoManager.redo()
        #expect(session.pickedURLs.isEmpty && session.photos.isEmpty && session.currentURL == nil)
        try await session.flush()
    }

    @Test
    func testFailedWriteRetainsPreviousRecordAndRetrySavesLatest() async throws {
        let failure = SelectionWriteFailure()
        let store = SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records"), writer: { data, url in
            if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let urls = try (1...2).map { try makeFile("\($0).jpg") }
        let session = makeSession(store: store)
        session.updatePhotos(urls, complete: true)
        session.mark(.picked)
        try await session.flush()
        let before = try await store.load(root: fixtureDirectory)
        failure.enabled = true
        session.mark(.skipped)
        do { try await session.flush(); Issue.record("Expected failed save") } catch {}
        if case .failed = session.saveState {} else { Issue.record("Expected visible save failure") }
        #expect(try await store.load(root: fixtureDirectory) == before)
        failure.enabled = false
        try await session.flush()
        #expect(try await store.load(root: fixtureDirectory) == session.record)
    }

    @Test
    func testInvalidSavedPathsCannotEscapeRootOrBeOverwrittenOnLoad() async throws {
        let store = SelectionStore(directory: fixtureDirectory.appendingPathComponent(".records"))
        var record = SelectionRecord(rootPath: fixtureDirectory.path)
        record.marks["../outside.jpg"] = .picked
        try await store.save(record)
        let url = await store.recordURL(for: fixtureDirectory)
        let before = try Data(contentsOf: url)
        do { _ = try await store.load(root: fixtureDirectory); Issue.record("Expected invalid record") } catch {}
        #expect(try Data(contentsOf: url) == before)
        #expect(record.relativePath(for: fixtureDirectory.deletingLastPathComponent().appendingPathComponent("outside.jpg")) == nil)
        #expect(!SelectionRecord.isValidPath("/absolute.jpg"))
    }

    @Test
    func testLargeSelectionKeepsCountsAndFiltersConsistentAcrossEdits() async throws {
        let urls = (0..<5000).map { fixtureDirectory.appendingPathComponent("旅行/\($0).jpg") }
        let session = makeSession()
        session.updatePhotos(urls, complete: true)
        // 模拟连续选片时界面读取列表和进度，覆盖大图库中缓存与标记同步的边界。
        session.onChange = {
            #expect(session.counts.all == 5000)
            #expect(session.counts.picked == session.pickedURLs.count)
            #expect(session.counts.pending == session.visibleURLs.count)
        }
        for _ in 0..<20 { session.mark(.picked) }
        #expect(session.pickedURLs == Array(urls.prefix(20)) && session.currentURL == urls[20])
        session.undoManager.undo()
        #expect(session.counts.picked == 19 && session.currentURL == urls[19])
        session.undoManager.redo()
        #expect(session.counts.picked == 20 && session.currentURL == urls[20])
        session.onChange = nil
        session.updatePhotos(Array(urls.reversed()), complete: true)
        session.setFilter(.picked)
        #expect(session.visibleURLs == Array(urls.prefix(20).reversed()))
        try await session.flush()
    }

    @Test
    func testUndoRestoresProjectionAfterChangingFilter() async throws {
        let urls = try (1...2).map { try makeFile("\($0).jpg") }
        let session = makeSession()
        session.updatePhotos(urls, complete: true)
        session.mark(.picked)
        session.setFilter(.picked)
        #expect(session.visibleURLs == [urls[0]] && session.showsGrid)
        // 用户已转到入选网格，撤销仍要回到标记前的筛选、照片和进度。
        session.undoManager.undo()
        #expect(session.filter == .pending && !session.showsGrid && session.currentURL == urls[0])
        #expect(session.visibleURLs == urls && session.pickedURLs.isEmpty && session.counts.pending == 2)
        session.undoManager.redo()
        #expect(session.filter == .pending && session.currentURL == urls[1])
        #expect(session.visibleURLs == [urls[1]] && session.pickedURLs == [urls[0]])
        try await session.flush()
    }
}

/// 写入失败由测试注入，避免依赖当前用户是否能绕过文件系统权限。
final class SelectionWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
