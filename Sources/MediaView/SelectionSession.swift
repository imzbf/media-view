import AppKit
import CryptoKit

enum PhotoSelectionStatus: String, Codable, CaseIterable, Sendable {
    case pending, picked, skipped

    var title: String {
        switch self {
        case .pending: return "待选"
        case .picked: return "入选"
        case .skipped: return "跳过"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle.dotted"
        case .picked: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
}

enum SelectionFilter: String, Codable, CaseIterable, Sendable {
    case all, pending, picked, skipped

    var title: String { self == .all ? "全部" : status!.title }
    var status: PhotoSelectionStatus? { PhotoSelectionStatus(rawValue: rawValue) }
}

/// 记录仅包含相对于根目录的路径，不写回照片、EXIF 或源目录。
struct SelectionRecord: Codable, Equatable, Sendable {
    var version = 1
    var rootPath: String
    var marks: [String: PhotoSelectionStatus] = [:]
    var lastPath: String?
    var filter: SelectionFilter = .pending
    var showsGrid = false
    var autoAdvance = true

    func relativePath(for url: URL) -> String? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard url.isFileURL, path.count > root.count, path.starts(with: root) else { return nil }
        return path.dropFirst(root.count).joined(separator: "/")
    }

    static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

enum SelectionRecordError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "选片记录无法读取，原有记录已保留。请检查文件或重试。" }
}

/// actor 把 JSON 编解码及磁盘写入移出主线程；原子替换保证写入失败仍有上一份有效记录。
actor SelectionStore {
    private let directory: URL
    private let writer: @Sendable (Data, URL) throws -> Void

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MediaView/Selections", isDirectory: true),
         writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) })
    {
        self.directory = directory
        self.writer = writer
    }

    func recordURL(for root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    func load(root: URL) throws -> SelectionRecord {
        let path = recordURL(for: root)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return SelectionRecord(rootPath: root.standardizedFileURL.path)
        }
        let record = try JSONDecoder().decode(SelectionRecord.self, from: Data(contentsOf: path))
        guard record.version == 1, record.rootPath == root.standardizedFileURL.path,
              record.marks.keys.allSatisfy(SelectionRecord.isValidPath),
              record.lastPath.map(SelectionRecord.isValidPath) ?? true else { throw SelectionRecordError.invalidRecord }
        return record
    }

    func save(_ record: SelectionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writer(JSONEncoder().encode(record), recordURL(for: URL(fileURLWithPath: record.rootPath)))
    }
}

/// 选片身份按路径保存；当前筛选和焦点只是这份记录的视图，不会裁掉隐藏照片的标记。
@MainActor
final class SelectionSession {
    enum SaveState: Equatable { case saved, saving, failed(String) }
    struct Counts: Equatable {
        var all = 0
        var pending = 0
        var picked = 0
        var skipped = 0
        var reviewed: Int { picked + skipped }
        subscript(_ filter: SelectionFilter) -> Int {
            switch filter {
            case .all: return all
            case .pending: return pending
            case .picked: return picked
            case .skipped: return skipped
            }
        }
    }

    private struct Location {
        let filter: SelectionFilter
        let grid: Bool
        let url: URL?
    }
    private struct Edit {
        let url: URL
        let before: PhotoSelectionStatus
        let after: PhotoSelectionStatus
        let from: Location
        let to: Location
    }

    let root: URL
    let undoManager = UndoManager()
    var onChange: (() -> Void)?
    private(set) var record: SelectionRecord
    private(set) var photos: [URL] = []
    private(set) var missingURLs: Set<URL> = []
    private(set) var visibleURLs: [URL] = []
    private(set) var pickedURLs: [URL] = []
    private(set) var counts = Counts()
    private(set) var missingPickedCount = 0
    private(set) var currentURL: URL?
    private(set) var saveState: SaveState = .saved
    private let store: SelectionStore
    private var availablePhotos: [URL] = []
    private var availablePaths: Set<String> = []
    private var pathsByURL: [URL: String] = [:]
    private var completedScan = false
    private var revision = 0
    private var savedRevision = 0
    private var saveTask: Task<Void, Never>?
    private var restoredPosition = false

    var filter: SelectionFilter { record.filter }
    var showsGrid: Bool { record.showsGrid }
    var autoAdvance: Bool { record.autoAdvance }

    init(root: URL, record: SelectionRecord, store: SelectionStore) {
        self.root = root.standardizedFileURL
        self.record = record
        self.store = store
        // 每次标记是独立的一步；快速连续按键也不能被同一 RunLoop 合并成一次撤销。
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 200
    }

    func status(of url: URL) -> PhotoSelectionStatus {
        let path = pathsByURL[url] ?? record.relativePath(for: url)
        return path.flatMap { record.marks[$0] } ?? .pending
    }

    func updatePhotos(_ urls: [URL], complete: Bool) {
        availablePhotos = []
        pathsByURL = [:]
        // 路径只在目录快照改变时规范化；缩放、翻图和保存提示不应重复解析数千个 URL。
        for url in urls where MediaFileTypes.kind(for: url) == .image {
            guard let path = record.relativePath(for: url) else { continue }
            availablePhotos.append(url)
            pathsByURL[url] = path
        }
        availablePaths = Set(pathsByURL.values)
        completedScan = complete
        rebuildPhotos()
        let visible = visibleURLs
        if !restoredPosition, let path = record.lastPath, let match = visible.first(where: { record.relativePath(for: $0) == path }) {
            currentURL = match
            restoredPosition = true
        } else if currentURL == nil || !visible.contains(currentURL!) {
            currentURL = visible.first
        }
        if complete { restoredPosition = true }
        onChange?()
    }

    private func rebuildPhotos() {
        // 扫描完整后才能认定文件缺失；撤销也要重建占位，不能把恢复的入选记录藏在列表外。
        missingURLs = []
        if completedScan {
            for path in record.marks.keys where !availablePaths.contains(path) {
                let url = root.appendingPathComponent(path)
                pathsByURL[url] = path
                missingURLs.insert(url)
            }
        }
        photos = availablePhotos + missingURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        rebuildProjection()
    }

    /// 计数和筛选共用一次遍历，仅在照片、标记或筛选变化时重建；界面可反复读取这份快照。
    private func rebuildProjection() {
        counts = Counts(all: photos.count)
        visibleURLs = []
        pickedURLs = []
        missingPickedCount = 0
        let wantedStatus = filter.status
        for url in photos {
            let status = status(of: url)
            switch status {
            case .pending: counts.pending += 1
            case .picked:
                counts.picked += 1
                pickedURLs.append(url)
                if missingURLs.contains(url) { missingPickedCount += 1 }
            case .skipped: counts.skipped += 1
            }
            if wantedStatus == nil || status == wantedStatus { visibleURLs.append(url) }
        }
    }

    func setFilter(_ filter: SelectionFilter) {
        guard filter != record.filter || (filter == .picked && !showsGrid) else { return }
        record.filter = filter
        record.showsGrid = filter == .picked
        rebuildProjection()
        if currentURL == nil || !visibleURLs.contains(currentURL!) { currentURL = visibleURLs.first }
        rememberLocation()
        changed()
    }

    func openPhoto(_ url: URL) {
        guard visibleURLs.contains(url) else { return }
        record.showsGrid = false
        currentURL = url
        rememberLocation()
        changed()
    }

    func showGrid() {
        guard filter == .picked else { return }
        record.showsGrid = true
        changed()
    }

    func setAutoAdvance(_ enabled: Bool) {
        guard enabled != autoAdvance else { return }
        record.autoAdvance = enabled
        changed()
    }

    /// 在变更前的顺序中寻找后继和前驱，避免筛选列表缩短后按旧索引跳过尚未看过的照片。
    func mark(_ status: PhotoSelectionStatus, url: URL? = nil) {
        guard let url = url ?? currentURL, photos.contains(url), status != self.status(of: url) else { return }
        let before = self.status(of: url)
        let from = location
        let previous = visibleURLs
        setStatus(status, for: url)
        let visible = visibleURLs
        if currentURL == url, let index = previous.firstIndex(of: url) {
            if !visible.contains(url) || (!showsGrid && autoAdvance && status != .pending) {
                let available = Set(visible)
                currentURL = previous.dropFirst(index + 1).first(where: available.contains)
                    ?? (available.contains(url) ? url : previous.prefix(index).last(where: available.contains))
            }
        }
        let edit = Edit(url: url, before: before, after: status, from: from, to: location)
        register(edit, undo: true)
        rememberLocation()
        changed()
    }

    private var location: Location { Location(filter: filter, grid: showsGrid, url: currentURL) }

    private func setStatus(_ status: PhotoSelectionStatus, for url: URL) {
        guard let path = pathsByURL[url] ?? record.relativePath(for: url) else { return }
        record.marks[path] = status == .pending ? nil : status
        rebuildPhotos()
    }

    private func register(_ edit: Edit, undo: Bool) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            let position = undo ? edit.from : edit.to
            target.record.filter = position.filter
            target.record.showsGrid = position.grid
            // 先恢复筛选再重建投影，跨筛选撤销时列表、计数和焦点必须属于同一状态。
            target.setStatus(undo ? edit.before : edit.after, for: edit.url)
            let visible = target.visibleURLs
            target.currentURL = position.url.flatMap { visible.contains($0) ? $0 : nil } ?? visible.first
            target.register(edit, undo: !undo)
            target.rememberLocation()
            target.changed()
        }
        undoManager.setActionName("标记\(edit.after.title)")
        undoManager.endUndoGrouping()
    }

    private func rememberLocation() {
        if let currentURL { record.lastPath = record.relativePath(for: currentURL) }
    }

    private func changed() {
        revision += 1
        startSave()
        onChange?()
    }

    func retrySave() {
        startSave()
        onChange?()
    }

    private func startSave() {
        guard saveTask == nil, revision != savedRevision else { return }
        saveState = .saving
        // 同一会话只有一个写入循环；磁盘较慢时合并中间状态，旧快照永远不会覆盖新快照。
        saveTask = Task {
            while savedRevision != revision {
                let writingRevision = revision
                let snapshot = record
                do {
                    try await store.save(snapshot)
                    savedRevision = writingRevision
                } catch {
                    saveState = .failed(error.localizedDescription)
                    saveTask = nil
                    onChange?()
                    return
                }
            }
            saveState = .saved
            saveTask = nil
            onChange?()
        }
    }

    /// 关闭和切目录必须等待最后一次写入；失败留在原会话，让用户重试而不是丢掉进度。
    func flush() async throws {
        retrySave()
        await saveTask?.value
        if case .failed(let message) = saveState { throw NSError(domain: "MediaView.Selection", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
