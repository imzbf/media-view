import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MediaView

class FixtureTestCase {
    let fixtureDirectory: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        fixtureDirectory = project.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    @discardableResult
    func makeFile(_ relativePath: String, data: Data = Data()) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.standardizedFileURL
    }

    @discardableResult
    func writeImage(_ name: String, type: UTType = .png, width: Int = 80, height: Int = 40,
                    orientation: Int = 1, red: CGFloat = 1, blue: CGFloat = 0) throws -> URL
    {
        let url = fixtureDirectory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try testBitmap(width: width, height: height, red: red, blue: blue),
                                  [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func finalSnapshot(opening inputs: [URL]) async throws -> LibrarySnapshot {
        var last: LibrarySnapshot?
        for try await snapshot in ImageLibrary.scan(opening: inputs) { last = snapshot }
        return try #require(last)
    }

    @discardableResult
    func writeGIF(_ name: String = "animated.gif", delays: [TimeInterval] = [0.02, 0.07, 0.15],
                  loopCount: Int? = 0, width: Int = 80, height: Int = 40) throws -> URL
    {
        let url = fixtureDirectory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, delays.count, nil
        ))
        if let loopCount {
            // helper 的 loopCount 使用 GIF 文件中的重复次数；ImageIO 编码器接收总轮数。
            let totalPlays = loopCount == 0 ? 0 : loopCount + 1
            CGImageDestinationSetProperties(destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: totalPlays]] as CFDictionary)
        }
        let red = try testBitmap(width: width, height: height, red: 1, blue: 0)
        let blue = try testBitmap(width: width, height: height, red: 0, blue: 1)
        for (index, delay) in delays.enumerated() {
            CGImageDestinationAddImage(destination, index.isMultiple(of: 2) ? red : blue,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

func gifFixture(_ name: String = "disposal") throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "gif", subdirectory: "Fixtures"))
}

/// 转为固定 RGBA 顺序检查颜色和透明度，避免依赖 ImageIO 返回的像素排布。
func testPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}

func testBitmap(width: Int = 80, height: Int = 40, red: CGFloat = 1, blue: CGFloat = 0) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0.2, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws
{
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        try #require(Date() < deadline, "Timed out waiting for asynchronous state")
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    func signal() {
        lock.lock()
        signaled = true
        lock.unlock()
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

func waitFor(_ signals: [TestSignal], timeout: TimeInterval) async throws {
    try await waitUntil(timeout: timeout) { signals.allSatisfy(\.isSet) }
}

/// 只用于记录跨解码队列的调用，避免测试本身产生数据竞争。
final class DecodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    func record(_ url: URL) {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }
}
