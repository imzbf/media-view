import AppKit
import Testing
@testable import MediaView

@MainActor
@Suite(.serialized)
final class DuplicateSessionTests: FixtureTestCase {
    private func makeStore() -> DuplicateStore { DuplicateStore(directory: fixtureDirectory.appendingPathComponent(".checks")) }

    @discardableResult
    private func makeCopies(_ count: Int = 3) throws -> [URL] {
        let original = try writeDuplicatePhoto("original.jpg")
        return [original] + (try (1..<count).map { try makeFile("copy-\($0).jpg", data: Data(contentsOf: original)) })
    }

    private func start(_ session: DuplicateSession) async throws {
        session.startScan()
        try await waitUntil(timeout: 10) { !session.isScanning }
        try #require(session.hasCompleted, "\(session.issues.map(\.message))")
    }

    @Test
    func testManualChoicesKeepOneFileAndResumeIgnoredGroupsAndFocus() async throws {
        let files = try makeCopies()
        let store = makeStore()
        let session = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(session)
        #expect(session.pendingFiles.isEmpty && !session.canClean)
        let group = try #require(session.selectedGroup)
        #expect(session.setRemoval(group.files[0].path, selected: true))
        #expect(session.setRemoval(group.files[1].path, selected: true))
        #expect(!session.setRemoval(group.files[2].path, selected: true), "不能把一组的最后一个保留件也勾选清理")
        session.keepOnly("original.jpg")
        #expect(Set(session.pendingFiles.map(\.path)) == ["copy-1.jpg", "copy-2.jpg"])
        session.selectFile("original.jpg")
        #expect(await session.prepareForDeparture())
        let restored = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(restored)
        #expect(restored.selectedFile?.path == "original.jpg" && restored.pendingFiles.count == 2)
        restored.toggleIgnored()
        #expect(restored.visibleGroups.isEmpty && restored.pendingFiles.isEmpty)
        restored.setFilter(.ignored)
        #expect(restored.visibleGroups.count == 1)
        #expect(await restored.prepareForDeparture())
        let ignored = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(ignored)
        #expect(ignored.record.filter == .ignored && ignored.visibleGroups.count == 1)
        ignored.toggleIgnored()
        ignored.setFilter(.all)
        #expect(ignored.visibleGroups.count == 1 && ignored.pendingFiles.isEmpty)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(await ignored.prepareForDeparture())
    }

    @Test
    func testChangedMembershipInvalidatesOldCleanupDecisions() async throws {
        let files = try makeCopies()
        let store = makeStore()
        let session = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(session)
        session.keepOnly("original.jpg")
        let previous = session.selectedGroup?.id
        #expect(await session.prepareForDeparture())
        try writeDuplicatePhoto(files[1].lastPathComponent, variant: 1)
        let reopened = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(reopened)
        #expect(reopened.groups.count == 1 && reopened.selectedGroup?.id != previous)
        #expect(reopened.pendingFiles.isEmpty && reopened.record.decisions.isEmpty)
        #expect(await reopened.prepareForDeparture())
    }

    @Test
    func testCleanupReportsPartialFailureAndRefreshesRemainingGroup() async throws {
        let files = try makeCopies()
        let trash = fixtureDirectory.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let session = DuplicateSession(root: fixtureDirectory, store: makeStore(), trash: { url in
            if url.lastPathComponent == "copy-1.jpg" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        var removed: Set<URL> = []
        session.onFilesRemoved = { removed.formUnion($0) }
        try await start(session)
        session.keepOnly("original.jpg")
        session.clean()
        try await waitUntil(timeout: 10) { session.lastCleanup != nil && !session.isBusy && session.hasCompleted }
        #expect(session.lastCleanup?.removed == ["copy-2.jpg"])
        #expect(session.lastCleanup?.issues.map(\.path) == ["copy-1.jpg"])
        #expect(removed == [files[2]])
        #expect(FileManager.default.fileExists(atPath: files[0].path) && FileManager.default.fileExists(atPath: files[1].path))
        #expect(try Data(contentsOf: trash.appendingPathComponent("copy-2.jpg")) == Data(contentsOf: files[0]))
        #expect(session.groups.first?.files.count == 2 && session.pendingFiles.isEmpty)
        #expect(await session.prepareForDeparture())
    }

    @Test(arguments: ["replacement", "symlink", "missing-keeper", "all-selected"])
    func testChangedFilesAndInvalidCleanupCannotRemoveOriginals(action: String) async throws {
        let files = try makeCopies(2)
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: makeStore())
        if action == "replacement" { try Data("new file".utf8).write(to: files[1]) }
        if action == "symlink" {
            try FileManager.default.removeItem(at: files[1])
            try FileManager.default.createSymbolicLink(at: files[1], withDestinationURL: files[0])
        }
        if action == "missing-keeper" { try FileManager.default.removeItem(at: files[0]) }
        let calls = DecodeRecorder()
        let selected: Set<String> = action == "all-selected" ? ["copy-1.jpg", "original.jpg"] : ["copy-1.jpg"]
        let cleanup = await DuplicateCleaner.clean(groups: result.groups, removals: selected, root: fixtureDirectory,
            trash: { calls.record($0) })
        #expect(cleanup.removed.isEmpty && !cleanup.issues.isEmpty && calls.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: files[1].path))
    }

    @Test
    func testKeeperDisappearingDuringCleanupPreservesTheLastRemainingCopy() async throws {
        let files = try makeCopies()
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: makeStore())
        let calls = DecodeRecorder()
        let keeper = files[0]
        let cleanup = await DuplicateCleaner.clean(groups: result.groups, removals: ["copy-1.jpg", "copy-2.jpg"],
            root: fixtureDirectory, trash: { url in
                calls.record(url)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.removeItem(at: keeper)
            })
        #expect(cleanup.removed.count == 1 && cleanup.issues.count == 1 && calls.urls.count == 1)
        #expect(files.dropFirst().filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
    }

    @Test
    func testCancellationKeepsCompletedMovesAndStopsFollowingFiles() async throws {
        try makeCopies()
        let result = try await DuplicateScanner().scan(root: fixtureDirectory, store: makeStore())
        let started = TestSignal()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let root = fixtureDirectory
        let task = Task.detached {
            await DuplicateCleaner.clean(groups: result.groups, removals: ["copy-1.jpg", "copy-2.jpg"], root: root,
                trash: { _ in started.signal(); _ = gate.wait(timeout: .now() + 5) })
        }
        try await waitFor([started], timeout: 3)
        task.cancel()
        gate.signal()
        let cleanup = await task.value
        #expect(cleanup.cancelled && cleanup.removed.count == 1 && cleanup.issues.isEmpty)
    }

    @Test
    func testSaveFailurePreventsDepartureAndRetryPersistsChoices() async throws {
        try makeCopies()
        let failure = SelectionWriteFailure()
        let store = DuplicateStore(directory: fixtureDirectory.appendingPathComponent(".checks"), writer: { data, url in
            if failure.enabled && url.lastPathComponent.hasSuffix("-review.json") { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let session = DuplicateSession(root: fixtureDirectory, store: store)
        try await start(session)
        try await session.flush()
        failure.enabled = true
        session.keepOnly("original.jpg")
        #expect(!(await session.prepareForDeparture()))
        #expect(session.pendingFiles.count == 2 && !session.isDeparting)
        failure.enabled = false
        #expect(await session.prepareForDeparture())
        #expect(try await store.loadReview(root: fixtureDirectory) == session.record)
    }

    @Test
    func testInvalidReviewRecordIsPreservedAndNeverRestoresOutsidePaths() async throws {
        try makeCopies()
        let store = makeStore()
        var record = DuplicateReviewRecord(rootPath: fixtureDirectory.path)
        record.decisions["invalid"] = DuplicateDecision(removals: ["../outside.jpg"])
        try await store.saveReview(record)
        let path = await store.recordURL(root: fixtureDirectory)
        let bytes = try Data(contentsOf: path)
        let session = DuplicateSession(root: fixtureDirectory, store: store)
        session.startScan()
        try await waitUntil { !session.isScanning }
        #expect(!session.hasCompleted && !session.issues.isEmpty && !session.canClean)
        #expect(await session.prepareForDeparture())
        #expect(try Data(contentsOf: path) == bytes)
    }
}
