import Foundation

enum DuplicateFilter: String, Codable, CaseIterable, Sendable {
    case all, exact, similar, ignored
    var title: String {
        switch self {
        case .all: return "全部"
        case .exact: return "完全重复"
        case .similar: return "疑似重复"
        case .ignored: return "已忽略"
        }
    }
}

struct DuplicateDecision: Codable, Equatable, Sendable {
    var ignored = false
    var removals: Set<String> = []
}

struct DuplicateReviewRecord: Codable, Equatable, Sendable {
    var version = 1
    let rootPath: String
    var decisions: [String: DuplicateDecision] = [:]
    var groupID: String?
    var path: String?
    var filter: DuplicateFilter = .all
}

/// 缓存可重建，复核决定不可静默丢弃；分开写入，勾选时无需重写整份媒体指纹。
actor DuplicateStore {
    private struct Cache: Codable {
        var version = 1
        let rootPath: String
        let files: [String: DuplicateFile]
    }
    private let directory: URL
    private let writer: @Sendable (Data, URL) throws -> Void

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MediaView/DuplicateChecks", isDirectory: true),
         writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) })
    {
        self.directory = directory
        self.writer = writer
    }

    func recordURL(root: URL, cache: Bool = false) -> URL {
        let name = DuplicateGroup.hash(root.standardizedFileURL.path)
        return directory.appendingPathComponent(name + (cache ? "-cache.json" : "-review.json"))
    }

    func loadReview(root: URL) throws -> DuplicateReviewRecord {
        let url = recordURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DuplicateReviewRecord(rootPath: root.standardizedFileURL.path)
        }
        let record = try JSONDecoder().decode(DuplicateReviewRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, record.rootPath == root.standardizedFileURL.path,
              record.path.map(DuplicateFile.isValidPath) ?? true,
              record.decisions.values.allSatisfy({ $0.removals.allSatisfy(DuplicateFile.isValidPath) })
        else { throw DuplicateError.invalidRecord }
        return record
    }

    func saveReview(_ record: DuplicateReviewRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writer(JSONEncoder().encode(record), recordURL(root: URL(fileURLWithPath: record.rootPath)))
    }

    func loadCache(root: URL) -> [String: DuplicateFile] {
        guard let data = try? Data(contentsOf: recordURL(root: root, cache: true)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1, cache.rootPath == root.standardizedFileURL.path else { return [:] }
        return cache.files.filter { path, file in
            path == file.path && DuplicateFile.isValidPath(path)
                && (file.visual?.frames.allSatisfy { $0.luminance.count == 1024 && $0.colors.count == 192 } ?? true)
        }
    }

    func saveCache(_ files: [String: DuplicateFile], root: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = Cache(rootPath: root.standardizedFileURL.path, files: files)
        try writer(JSONEncoder().encode(cache), recordURL(root: root, cache: true))
    }
}
