import Foundation
import ImageIO
import Testing
@testable import MediaView

@Suite(.serialized)
final class GIFAnimationTests: FixtureTestCase {
    @Test
    func testUnclampedTimingAndInvalidDelayFallback() throws {
        #expect(GIFAnimation.frameDuration(properties: [kCGImagePropertyGIFUnclampedDelayTime: 0.01,
                                                        kCGImagePropertyGIFDelayTime: 0.1]) == 0.01)
        #expect(GIFAnimation.frameDuration(properties: [kCGImagePropertyGIFDelayTime: 0.2]) == 0.2)
        for invalid in [0, -1, Double.nan, Double.infinity] {
            #expect(GIFAnimation.frameDuration(properties: [kCGImagePropertyGIFUnclampedDelayTime: invalid,
                                                            kCGImagePropertyGIFDelayTime: 0.5]) == 0.1)
        }
        #expect(GIFAnimation.frameDuration(properties: [:]) == 0.1)
    }

    @Test(arguments: [nil, 0, 1, 3] as [Int?])
    func testGIFMetadataAndLoopSemantics(loopCount: Int?) async throws {
        let url = try writeGIF(loopCount: loopCount)
        let decoded = try await ImageDecoder().load(url, quality: .original)
        let animation = try #require(decoded.animation)
        #expect(animation.frameCount == 3)
        #expect(animation.totalPlays == (loopCount == 0 ? nil : (loopCount ?? 0) + 1))
        for (actual, expected) in zip(animation.frameDurations, [0.02, 0.07, 0.15]) {
            #expect(abs(actual - expected) < 0.0001)
        }
    }

    @Test
    func testSingleFrameGIFIsStaticAndThumbnailOnlyUsesFirstFrame() async throws {
        let single = try writeGIF("single.gif", delays: [0.1])
        let multiple = try writeGIF()
        let decoder = ImageDecoder()
        let staticImage = try await decoder.load(single, quality: .original)
        #expect(staticImage.animation == nil)
        let thumbnail = try await decoder.thumbnail(multiple, maxPixelDimension: 40)
        #expect(thumbnail.animation == nil)
        #expect(thumbnail.image.width == 40)
        let pixels = try testPixels(thumbnail.image)
        #expect(pixels[0] > 240 && pixels[2] < 20)
    }

    @Test
    func testImageIOCompositesTransparencyLocalRectanglesAndDisposal() async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try gifFixture(), quality: .original)
        let animation = try #require(first.animation)
        #expect(animation.frameCount == 4)
        #expect(animation.frameDurations[3] == 0.1, "A zero unclamped delay uses 100 ms")
        let red: [UInt8] = [255, 0, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let clear: [UInt8] = [0, 0, 0, 0]
        let expected = [
            [red, clear, clear, clear, red, clear, clear, clear, red, clear, clear, clear],
            [red, blue, blue, clear, red, blue, blue, clear, red, clear, clear, clear],
            [green, clear, clear, clear, green, clear, clear, clear, green, clear, clear, clear],
            [red, clear, clear, clear, red, clear, clear, clear, red, clear, clear, blue],
        ]
        // 乱序访问、跳回首帧和重复循环也必须正确，不能依赖调用者自己叠加上一张图。
        for index in [0, 1, 2, 3, 0, 3, 1, 2] {
            let frame = try await decoder.frame(of: animation, at: index, quality: .original)
            #expect(frame.pixelSize == CGSize(width: 4, height: 3))
            #expect(frame.image.width == 4 && frame.image.height == 3)
            #expect(try testPixels(frame.image) == expected[index].flatMap { $0 }, "Frame \(index)")
        }
        let smaller = try await decoder.frame(of: animation, at: 3, quality: .screen(maxPixelDimension: 2))
        #expect(smaller.pixelSize == CGSize(width: 4, height: 3))
        #expect(smaller.image.width == 2)
        #expect(!smaller.isFullResolution)
    }

    @Test(arguments: ["damaged-frame", "damaged-second"])
    func testTruncatedLastFrameDoesNotPreventOpeningValidFrames(name: String) async throws {
        let decoder = ImageDecoder()
        let first = try await decoder.load(try gifFixture(name), quality: .original)
        let animation = try #require(first.animation)
        let count = name == "damaged-second" ? 2 : 4
        #expect(animation.frameCount == count, "Do not silently ignore a truncated final image descriptor")
        let valid = try await decoder.frame(of: animation, at: count - 2, quality: .original)
        #expect(valid.image.width == 4)
        await #expect(throws: ImageDecodeError.invalidImage) {
            try await decoder.frame(of: animation, at: count - 1, quality: .original)
        }
    }

    @Test
    func testRawNetscapeLoopExtensionAndAbsentExtension() async throws {
        // 手写容器夹具独立于 ImageIO 编码器，固定“重复一次 = 总共两轮”的真实文件语义。
        let decoder = ImageDecoder()
        let finite = try await decoder.load(try gifFixture("finite-loop"), quality: .original)
        let once = try await decoder.load(try gifFixture("once"), quality: .original)
        #expect(finite.animation?.totalPlays == 2)
        #expect(once.animation?.totalPlays == 1)
    }
}
