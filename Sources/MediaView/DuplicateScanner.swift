import Foundation
import CryptoKit

/// 独立于浏览解码器的后台流水线。每阶段至多两项在途，取消会传入视频采样和分块哈希。
struct DuplicateScanner: Sendable {
    typealias Analyzer = @Sendable (URL, DuplicateKind) async throws -> DuplicateVisual
    private let analyzer: Analyzer
    private let hasher: @Sendable (URL) throws -> String

    init(analyzer: @escaping Analyzer = { try await DuplicateVisual.read($0, kind: $1) },
         hasher: @escaping @Sendable (URL) throws -> String = { try Self.digest($0) })
    {
        self.analyzer = analyzer
        self.hasher = hasher
    }

    func scan(root: URL, store: DuplicateStore,
              progress: @escaping @Sendable (DuplicateProgress) async -> Void = { _ in }) async throws -> DuplicateScanResult
    {
        let root = root.standardizedFileURL
        await progress(.init(phase: "正在整理文件…", completed: 0, total: 0))
        var snapshot: LibrarySnapshot?
        for try await value in ImageLibrary.scan(opening: [root], options: LibraryOptions(includesSubdirectories: true)) {
            try Task.checkCancellation()
            snapshot = value
            await progress(.init(phase: "正在整理文件…", completed: value.images.count, total: 0))
        }
        guard let snapshot else { throw LibraryError.unreadableDirectory(root) }
        let cache = await store.loadCache(root: root)
        var files: [DuplicateFile] = []
        var issues: [DuplicateIssue] = []
        if snapshot.skippedPaths > 0 {
            issues.append(.init(path: root.path, message: "有 \(snapshot.skippedPaths) 条路径无法读取，未纳入检查。"))
        }
        for url in snapshot.images {
            try Task.checkCancellation()
            guard let path = DuplicateFile.relativePath(url, root: root), let media = MediaFileTypes.kind(for: url) else { continue }
            do {
                let stamp = try DuplicateFileStamp.read(url)
                let kind: DuplicateKind = media == .video ? .video : .photo
                if let saved = cache[path], saved.stamp == stamp, saved.kind == kind { files.append(saved) }
                else { files.append(DuplicateFile(path: path, kind: kind, stamp: stamp)) }
            } catch { issues.append(.init(path: path, message: error.localizedDescription)) }
        }

        // 文件大小不同一定不是逐字节副本，先排除，避免无意义地读完整个独有大视频。
        let buckets = Dictionary(grouping: files.indices, by: { "\(files[$0].kind):\(files[$0].stamp.size)" })
        let hashIndices = buckets.values.filter { $0.count > 1 }.flatMap { $0 }.filter { files[$0].digest == nil }.sorted()
        let hashInputs = hashIndices.map { files[$0] }
        let hasher = hasher
        var checked = 0
        var lastUpdate = Date.distantPast
        await progress(.init(phase: "核对完整文件", completed: 0, total: hashInputs.count))
        try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var next = 0
            func enqueue(_ offset: Int) {
                let file = hashInputs[offset]
                group.addTask {
                    try Task.checkCancellation()
                    let result = Result { () throws -> String in
                        let url = file.url(in: root)
                        guard try DuplicateFileStamp.read(url) == file.stamp else { throw DuplicateError.changedFile }
                        let digest = try hasher(url)
                        guard try DuplicateFileStamp.read(url) == file.stamp else { throw DuplicateError.changedFile }
                        return digest
                    }
                    try Task.checkCancellation()
                    return (offset, result)
                }
            }
            while next < min(2, hashInputs.count) { enqueue(next); next += 1 }
            while let (offset, result) = try await group.next() {
                let index = hashIndices[offset]
                switch result {
                case .success(let digest): files[index].digest = digest
                case .failure(let error): issues.append(.init(path: files[index].path, message: error.localizedDescription))
                }
                checked += 1
                if Date().timeIntervalSince(lastUpdate) >= 0.1 || checked == hashInputs.count {
                    await progress(.init(phase: "核对完整文件", completed: checked, total: hashInputs.count)); lastUpdate = Date()
                }
                if next < hashInputs.count { enqueue(next); next += 1 }
            }
        }

        // 完全相同的多个副本只分析一次画面；它们作为一个内容集合参与疑似分组。
        let units = Dictionary(grouping: files.indices, by: { index -> String in
            let file = files[index]
            return file.digest.map { "\(file.kind):\(file.stamp.size):\($0)" } ?? "path:\(file.path)"
        }).values.map { $0.sorted() }.sorted { files[$0[0]].path < files[$1[0]].path }
        let visualInputs = units.map { indices in indices.compactMap { files[$0].visual }.first }
        let pending = units.indices.filter { visualInputs[$0] == nil }
        let representatives = units.map { files[$0[0]] }
        let analyzer = analyzer
        checked = 0
        lastUpdate = .distantPast
        await progress(.init(phase: "比较照片和视频画面", completed: 0, total: pending.count))
        try await withThrowingTaskGroup(of: (Int, Result<DuplicateVisual, Error>).self) { group in
            var next = 0
            func enqueue(_ offset: Int) {
                let unit = pending[offset], file = representatives[unit]
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let url = file.url(in: root)
                        guard try DuplicateFileStamp.read(url) == file.stamp else { throw DuplicateError.changedFile }
                        let visual = try await analyzer(url, file.kind)
                        try Task.checkCancellation()
                        guard try DuplicateFileStamp.read(url) == file.stamp else { throw DuplicateError.changedFile }
                        return (unit, .success(visual))
                    } catch is CancellationError { throw CancellationError() }
                    catch { return (unit, .failure(error)) }
                }
            }
            while next < min(2, pending.count) { enqueue(next); next += 1 }
            while let (unit, result) = try await group.next() {
                switch result {
                case .success(let visual): for index in units[unit] { files[index].visual = visual }
                case .failure(let error): issues.append(.init(path: representatives[unit].path, message: error.localizedDescription))
                }
                checked += 1
                if Date().timeIntervalSince(lastUpdate) >= 0.1 || checked == pending.count {
                    await progress(.init(phase: "比较照片和视频画面", completed: checked, total: pending.count)); lastUpdate = Date()
                }
                if next < pending.count { enqueue(next); next += 1 }
            }
        }
        for unit in units.indices {
            if let visual = visualInputs[unit] { for index in units[unit] { files[index].visual = visual } }
        }
        try Task.checkCancellation()
        await progress(.init(phase: "整理重复组…", completed: 0, total: units.count))
        let groups = try Self.makeGroups(files: files, units: units)
        // 仅缓存本轮仍在库中的文件；缓存写入失败不改变复核结果，也不阻止原件预览。
        do { try await store.saveCache(Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }), root: root) }
        catch { issues.append(.init(path: "指纹缓存", message: "本次结果可用，下次需要重新分析：\(error.localizedDescription)")) }
        try Task.checkCancellation()
        return DuplicateScanResult(groups: groups, issues: issues, fileCount: files.count)
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 每组保持两两相符。不能用连通分量把一连串相近的连拍合成一个大组。
    static func makeGroups(files: [DuplicateFile], units: [[Int]]) throws -> [DuplicateGroup] {
        var collections: [[Int]] = []
        var trees: [DuplicateKind: DuplicateHashIndex] = [:]
        for unit in units.indices {
            try Task.checkCancellation()
            let file = files[units[unit][0]]
            var joined = false
            if let visual = file.visual, let hash = visual.indexHash {
                let candidates = trees[file.kind]?.matches(hash, radius: file.kind == .photo ? 6 : 8) ?? []
                for candidate in candidates.sorted() {
                    try Task.checkCancellation()
                    if collections[candidate].allSatisfy({ other in
                        files[units[other][0]].visual.map { visual.matches($0) } ?? false
                    }) {
                        collections[candidate].append(unit)
                        joined = true
                        break
                    }
                }
                if !joined {
                    var tree = trees[file.kind] ?? DuplicateHashIndex()
                    tree.insert(hash, value: collections.count)
                    trees[file.kind] = tree
                }
            }
            if !joined { collections.append([unit]) }
        }
        return collections.compactMap { collection in
            let members = collection.flatMap { units[$0].map { files[$0] } }
            guard members.count > 1 else { return nil }
            return DuplicateGroup(files: members, match: collection.count == 1 ? .exact : .similar)
        }.sorted {
            if $0.match != $1.match { return $0.match == .exact }
            return $0.files.map(\.path).min()! < $1.files.map(\.path).min()!
        }
    }
}

/// Hamming 距离满足三角不等式，BK 树可排除远距离候选，无需让所有缩略图两两比较。
struct DuplicateHashIndex {
    private struct Node {
        let hash: UInt64
        var values: [Int]
        var children: [Int: Int] = [:]
    }
    private var nodes: [Node] = []

    mutating func insert(_ hash: UInt64, value: Int) {
        guard !nodes.isEmpty else { nodes.append(Node(hash: hash, values: [value])); return }
        var index = 0
        while true {
            let distance = (nodes[index].hash ^ hash).nonzeroBitCount
            if distance == 0 { nodes[index].values.append(value); return }
            if let next = nodes[index].children[distance] { index = next }
            else {
                nodes[index].children[distance] = nodes.count
                nodes.append(Node(hash: hash, values: [value]))
                return
            }
        }
    }

    func matches(_ hash: UInt64, radius: Int) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var stack = [0], result: [Int] = []
        while let index = stack.popLast() {
            let node = nodes[index], distance = (node.hash ^ hash).nonzeroBitCount
            if distance <= radius { result.append(contentsOf: node.values) }
            for (edge, child) in node.children where abs(edge - distance) <= radius { stack.append(child) }
        }
        return result
    }
}
