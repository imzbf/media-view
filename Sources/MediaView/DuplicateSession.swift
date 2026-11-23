import Foundation

struct DuplicateCleanupResult: Sendable {
    var removed: Set<String> = []
    var issues: [DuplicateIssue] = []
    var cancelled = false
}

enum DuplicateCleaner {
    /// 清理只接受已复核的快照。每次移动前检查保留件，不允许旧结果删除被替换后的新文件。
    static func clean(groups: [DuplicateGroup], removals: Set<String>, root: URL,
                      trash: @Sendable (URL) throws -> Void,
                      progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> DuplicateCleanupResult
    {
        var result = DuplicateCleanupResult()
        var completed = 0
        let total = groups.flatMap(\.files).filter { removals.contains($0.path) }.count
        for group in groups {
            let selected = group.files.filter { removals.contains($0.path) }
            guard !selected.isEmpty else { continue }
            if Task.isCancelled { result.cancelled = true; break }
            let keepers = group.files.filter { !removals.contains($0.path) }
            do {
                guard !keepers.isEmpty else { throw DuplicateError.noKeeper }
                for file in group.files {
                    guard try DuplicateFileStamp.read(file.url(in: root)) == file.stamp else { throw DuplicateError.changedFile }
                }
            } catch {
                result.issues.append(contentsOf: selected.map { .init(path: $0.path, message: error.localizedDescription) })
                completed += selected.count
                await progress(completed, total)
                continue
            }
            for file in selected {
                if Task.isCancelled { result.cancelled = true; break }
                do {
                    guard try DuplicateFileStamp.read(file.url(in: root)) == file.stamp,
                          keepers.contains(where: { (try? DuplicateFileStamp.read($0.url(in: root))) == $0.stamp })
                    else { throw DuplicateError.changedFile }
                    try trash(file.url(in: root))
                    result.removed.insert(file.path)
                } catch { result.issues.append(.init(path: file.path, message: error.localizedDescription)) }
                completed += 1
                await progress(completed, total)
            }
            if result.cancelled { break }
        }
        return result
    }
}

/// 复核决定由组身份约束，界面排序和过滤不改变清理集合；新扫描只恢复仍完全对应的决定。
@MainActor
final class DuplicateSession {
    enum SaveState: Equatable { case saved, saving, failed(String) }
    let root: URL
    private(set) var groups: [DuplicateGroup] = []
    private(set) var issues: [DuplicateIssue] = []
    private(set) var fileCount = 0
    private(set) var record: DuplicateReviewRecord
    private(set) var progress = DuplicateProgress(phase: "准备检查…", completed: 0, total: 0)
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var isDeparting = false
    private(set) var hasCompleted = false
    private(set) var saveState: SaveState = .saved
    private(set) var lastCleanup: DuplicateCleanupResult?
    var onChange: (() -> Void)?
    var onFilesRemoved: ((Set<URL>) -> Void)?
    private let store: DuplicateStore
    private let scanner: DuplicateScanner
    private let trash: @Sendable (URL) throws -> Void
    private var loaded = false
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private var savedRevision = 0

    init(root: URL, store: DuplicateStore = DuplicateStore(), scanner: DuplicateScanner = DuplicateScanner(),
         trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    {
        self.root = root.standardizedFileURL
        self.store = store
        self.scanner = scanner
        self.trash = trash
        record = DuplicateReviewRecord(rootPath: root.standardizedFileURL.path)
    }

    var isBusy: Bool { isScanning || isCleaning || isDeparting }
    var canReview: Bool { hasCompleted && !isBusy }
    var selectedGroup: DuplicateGroup? { groups.first { $0.id == record.groupID } }
    var selectedFile: DuplicateFile? { selectedGroup?.files.first { $0.path == record.path } }
    var visibleGroups: [DuplicateGroup] {
        groups.filter { group in
            let ignored = record.decisions[group.id]?.ignored == true
            switch record.filter {
            case .all: return !ignored
            case .exact: return !ignored && group.match == .exact
            case .similar: return !ignored && group.match == .similar
            case .ignored: return ignored
            }
        }
    }
    var pendingFiles: [DuplicateFile] {
        groups.flatMap { group -> [DuplicateFile] in
            guard let decision = record.decisions[group.id], !decision.ignored else { return [] }
            return group.files.filter { decision.removals.contains($0.path) }
        }
    }
    var canClean: Bool { canReview && !pendingFiles.isEmpty }

    func startScan() {
        guard !isBusy else { return }
        isScanning = true
        hasCompleted = false
        progress = .init(phase: "正在读取检查记录…", completed: 0, total: 0)
        onChange?()
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isScanning = false; self.scanTask = nil; self.onChange?() }
            do {
                if !self.loaded {
                    self.record = try await self.store.loadReview(root: self.root)
                    self.loaded = true
                    self.saveState = .saved
                }
                try Task.checkCancellation()
                let result = try await self.scanner.scan(root: self.root, store: self.store) { [weak self] value in
                    await self?.report(value)
                }
                try Task.checkCancellation()
                self.groups = result.groups
                self.issues = result.issues
                self.fileCount = result.fileCount
                self.hasCompleted = true
                self.progress = .init(phase: "检查完成 · \(result.fileCount) 个文件 · \(result.groups.count) 组重复", completed: result.fileCount, total: result.fileCount)
                self.reconcileRecord()
            } catch is CancellationError {
                self.progress = .init(phase: "已取消检查，可重新检查继续", completed: 0, total: 0)
            } catch {
                self.issues = [.init(path: self.root.path, message: error.localizedDescription)]
                self.progress = .init(phase: "检查失败，请查看问题后重试", completed: 0, total: 0)
                if !self.loaded { self.saveState = .failed(error.localizedDescription) }
            }
        }
    }

    private func reconcileRecord() {
        let previous = record
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        record.decisions = record.decisions.filter { id, decision in
            guard let group = byID[id] else { return false }
            let paths = Set(group.files.map(\.path))
            return decision.removals.isSubset(of: paths) && decision.removals.count < paths.count
        }
        if !visibleGroups.contains(where: { $0.id == record.groupID }) { record.groupID = visibleGroups.first?.id }
        if selectedFile == nil { record.path = selectedGroup?.files.first?.path }
        if record != previous { changed() }
    }

    func selectGroup(_ id: String) {
        guard !isDeparting, !isCleaning, let group = groups.first(where: { $0.id == id }), record.groupID != id else { return }
        record.groupID = id
        record.path = group.files.first?.path
        changed()
    }

    func selectFile(_ path: String) {
        guard !isDeparting, !isCleaning, selectedGroup?.files.contains(where: { $0.path == path }) == true,
              record.path != path else { return }
        record.path = path
        changed()
    }

    func setFilter(_ filter: DuplicateFilter) {
        guard !isBusy, filter != record.filter else { return }
        record.filter = filter
        record.groupID = visibleGroups.first?.id
        record.path = selectedGroup?.files.first?.path
        changed()
    }

    @discardableResult
    func setRemoval(_ path: String, selected: Bool) -> Bool {
        guard canReview, let group = selectedGroup, group.files.contains(where: { $0.path == path }) else { return false }
        var decision = record.decisions[group.id] ?? DuplicateDecision()
        guard !decision.ignored else { return false }
        if selected {
            guard decision.removals.contains(path) || decision.removals.count + 1 < group.files.count else { return false }
            decision.removals.insert(path)
        } else { decision.removals.remove(path) }
        record.decisions[group.id] = decision
        changed()
        return true
    }

    func keepOnly(_ path: String) {
        guard canReview, let group = selectedGroup, group.files.contains(where: { $0.path == path }),
              record.decisions[group.id]?.ignored != true else { return }
        record.decisions[group.id] = DuplicateDecision(removals: Set(group.files.map(\.path)).subtracting([path]))
        changed()
    }

    func toggleIgnored() {
        guard canReview, let group = selectedGroup else { return }
        record.decisions[group.id] = DuplicateDecision(ignored: record.decisions[group.id]?.ignored != true)
        record.groupID = visibleGroups.first?.id
        record.path = selectedGroup?.files.first?.path
        changed()
    }

    func clean() {
        guard canClean else { return }
        let removals = Set(pendingFiles.map(\.path)), groups = groups, root = root, trash = trash
        isCleaning = true
        lastCleanup = nil
        progress = .init(phase: "正在移到废纸篓", completed: 0, total: removals.count)
        onChange?()
        cleanupTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                await DuplicateCleaner.clean(groups: groups, removals: removals, root: root, trash: trash) { [weak self] done, total in
                    await self?.report(.init(phase: "正在移到废纸篓", completed: done, total: total))
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            self.lastCleanup = result
            self.isCleaning = false
            self.cleanupTask = nil
            self.hasCompleted = false
            self.groups = self.groups.compactMap { group in
                let remaining = group.files.filter { !result.removed.contains($0.path) }
                return remaining.count > 1 ? DuplicateGroup(files: remaining, match: group.match) : nil
            }
            self.reconcileRecord()
            if !result.removed.isEmpty { self.onFilesRemoved?(Set(result.removed.map { root.appendingPathComponent($0) })) }
            self.progress = .init(phase: "\(result.cancelled ? "已取消清理" : "清理完成") · 已移到废纸篓 \(result.removed.count) 项", completed: 0, total: 0)
            self.onChange?()
            if !self.isDeparting && !Task.isCancelled { self.startScan() }
        }
    }

    func cancelActivity() { scanTask?.cancel(); cleanupTask?.cancel() }

    private func report(_ value: DuplicateProgress) { progress = value; onChange?() }

    private func changed() {
        revision += 1
        startSave()
        onChange?()
    }

    func retrySave() {
        if !loaded { startScan(); return }
        startSave()
        onChange?()
    }

    private func startSave() {
        guard loaded, saveTask == nil, revision != savedRevision else { return }
        saveState = .saving
        // 串行合并快照，慢磁盘也不会让较早的勾选覆盖较新的决定。
        saveTask = Task {
            while savedRevision != revision {
                let writing = revision, snapshot = record
                do { try await store.saveReview(snapshot); savedRevision = writing }
                catch { saveState = .failed(error.localizedDescription); saveTask = nil; onChange?(); return }
            }
            saveState = .saved
            saveTask = nil
            onChange?()
        }
    }

    func flush() async throws {
        guard loaded else { return }
        startSave()
        await saveTask?.value
        if case .failed(let message) = saveState {
            throw NSError(domain: "MediaView.Duplicates", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func prepareForDeparture() async -> Bool {
        guard !isDeparting else { return false }
        isDeparting = true
        onChange?()
        defer { isDeparting = false; onChange?() }
        cancelActivity()
        await scanTask?.value
        await cleanupTask?.value
        do { try await flush(); return true }
        catch { return false }
    }
}
