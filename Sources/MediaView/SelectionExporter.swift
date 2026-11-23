import Foundation
import Darwin

struct SelectionExportResult: Sendable {
    struct Failure: Sendable {
        let source: URL
        let message: String
    }
    let directory: URL
    var copied: [URL] = []
    var failures: [Failure] = []
    var cancelled = false
}

enum SelectionExporter {
    /// 运行于后台任务，直接复制原文件；预览中的旋转、降采样及 GIF 当前帧都不参与导出。
    static func export(_ sources: [URL], rootName: String, destination: URL,
                       copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                       progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> SelectionExportResult
    {
        try Task.checkCancellation()
        let manager = FileManager.default
        let name = "\(rootName)－入选照片"
        var directory = destination.appendingPathComponent(name, isDirectory: true)
        var suffix = 1
        while true {
            // Foundation 的 createDirectory 对既有目录也可能成功；mkdir 保证本次独占一个新目录。
            if mkdir(directory.path, 0o755) == 0 { break }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            suffix += 1
            directory = destination.appendingPathComponent("\(name)（\(suffix)）", isDirectory: true)
        }
        var result = SelectionExportResult(directory: directory)
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { result.cancelled = true; break }
            // 只有完整的副本才取得正式文件名；失败清理仅限本次新建目录中的临时文件。
            let temporary = directory.appendingPathComponent(".copy-\(UUID().uuidString)")
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw NSError(domain: "MediaView.Export", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "源文件已变更，无法作为原图复制。请刷新后重试。"])
                }
                try copy(source, temporary)
                let stem = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                var output = directory.appendingPathComponent(source.lastPathComponent)
                var number = 1
                while true {
                    do {
                        try manager.moveItem(at: temporary, to: output)
                        result.copied.append(output)
                        break
                    } catch CocoaError.fileWriteFileExists {
                        number += 1
                        output = directory.appendingPathComponent("\(stem)（\(number)）\(ext)")
                    }
                }
            } catch {
                try? manager.removeItem(at: temporary)
                result.failures.append(.init(source: source, message: error.localizedDescription))
            }
            await progress(index + 1, sources.count)
        }
        result.cancelled = result.cancelled || (Task.isCancelled && result.copied.count + result.failures.count < sources.count)
        return result
    }
}
