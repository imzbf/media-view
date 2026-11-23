import Foundation
import Testing
@testable import MediaView

extension CanvasGeometry {
    func imagePoint(at point: CGPoint) -> CGPoint {
        let centered = CGPoint(x: (point.x - viewportSize.width / 2 - offset.x) / scale,
                               y: (point.y - viewportSize.height / 2 - offset.y) / scale)
            .applying(orientation.inverted())
        return CGPoint(x: centered.x + imageSize.width / 2, y: centered.y + imageSize.height / 2)
    }
}

@Suite(.serialized)
final class CanvasGeometryTests {
    private func geometry(image: CGSize = CGSize(width: 4000, height: 3000)) -> CanvasGeometry {
        var value = CanvasGeometry()
        value.resize(to: CGSize(width: 1000, height: 600), backingScale: 2)
        value.setImage(size: image)
        return value
    }

    @Test
    func testFitCentersImageAndRespectsAspectRatio() {
        let value = geometry()
        #expect(abs(value.scale - 0.2) <= 0.0001)
        #expect(value.imageFrame == CGRect(x: 100, y: 0, width: 800, height: 600))
    }

    @Test
    func testFitDoesNotEnlargeSmallImage() {
        let value = geometry(image: CGSize(width: 100, height: 80))
        #expect(value.scale == 0.5)
        #expect(value.imageFrame.midX == 500)
        #expect(value.imageFrame.midY == 300)
    }

    @Test
    func testActualSizeUsesPhysicalPixelsOnRetina() {
        var value = geometry()
        value.actualSize()
        #expect(value.scale == 0.5)
        #expect(value.imageFrame.width == 2000)
        value.resize(to: CGSize(width: 1000, height: 600), backingScale: 1)
        #expect(value.scale == 1)
    }

    @Test
    func testZoomKeepsImagePixelUnderCursor() {
        var value = geometry()
        value.actualSize()
        let anchor = CGPoint(x: 730, y: 410)
        let pixelBefore = CGPoint(x: (anchor.x - value.imageFrame.minX) / value.scale,
                                  y: (anchor.y - value.imageFrame.minY) / value.scale)
        value.zoom(by: 1.25, around: anchor)
        let pixelAfter = CGPoint(x: (anchor.x - value.imageFrame.minX) / value.scale,
                                 y: (anchor.y - value.imageFrame.minY) / value.scale)
        #expect(abs(pixelBefore.x - pixelAfter.x) <= 0.0001)
        #expect(abs(pixelBefore.y - pixelAfter.y) <= 0.0001)
    }

    @Test
    func testPanRetainsVisibleMarginInBothDirections() {
        var value = geometry()
        value.actualSize()
        value.pan(by: CGPoint(x: 100_000, y: 100_000))
        #expect(value.imageFrame.minX == 1000 - value.minimumVisibleMargin)
        #expect(value.imageFrame.minY == 600 - value.minimumVisibleMargin)
        value.pan(by: CGPoint(x: -200_000, y: -200_000))
        #expect(value.imageFrame.maxX == value.minimumVisibleMargin)
        #expect(value.imageFrame.maxY == value.minimumVisibleMargin)
    }

    @Test
    func testSmallAxesRemainCenteredAndFitTracksResize() {
        var value = geometry()
        value.pan(by: CGPoint(x: 5000, y: 5000))
        #expect(value.offset == .zero)
        value.resize(to: CGSize(width: 800, height: 300), backingScale: 2)
        #expect(abs(value.scale - 0.1) <= 0.0001)
        #expect(value.imageFrame.midX == 400)
        #expect(value.imageFrame.midY == 150)
    }

    @Test
    func testCustomZoomSurvivesResizeAndNewImageResetsIt() {
        var value = geometry()
        value.zoom(by: 4, around: CGPoint(x: 500, y: 300))
        let scale = value.scale
        value.resize(to: CGSize(width: 900, height: 500), backingScale: 2)
        #expect(value.scale == scale)
        value.pan(by: CGPoint(x: 40, y: 30))
        value.resize(to: value.viewportSize, backingScale: 1)
        #expect(value.scale == scale * 2 && value.offset == CGPoint(x: 80, y: 60))
        value.setImage(size: CGSize(width: 800, height: 600))
        #expect(value.mode == .fit)
        #expect(value.offset == .zero)
    }

    @Test
    func testExtremeZoomAndEmptyViewportStayFinite() {
        var value = geometry()
        value.zoom(by: .greatestFiniteMagnitude, around: .zero)
        #expect(value.scale <= 16)
        value.zoom(by: .leastNormalMagnitude, around: .zero)
        #expect(value.scale > 0)
        value.resize(to: .zero, backingScale: 2)
        #expect(value.imageFrame.origin.x.isFinite)
        #expect(value.imageFrame.origin.y.isFinite)
        var empty = CanvasGeometry()
        empty.zoom(by: 3, around: .zero)
        #expect(empty.offset == .zero)
    }

    @Test
    func testQuarterTurnsFitOrientedBoundsWithoutAccumulatedRounding() {
        var value = geometry()
        let originalFrame = value.imageFrame
        value.rotate(clockwise: true)
        #expect(value.orientedImageSize == CGSize(width: 3000, height: 4000))
        #expect(abs(value.scale - 0.15) < 0.0001)
        #expect(value.imageFrame == CGRect(x: 275, y: 0, width: 450, height: 600))
        for _ in 0..<3 { value.rotate(clockwise: true) }
        #expect(value.orientation == .identity)
        #expect(value.imageFrame == originalFrame)
        value.rotate(clockwise: false)
        value.rotate(clockwise: true)
        #expect(value.orientation == .identity)
    }

    @Test
    func testRotationsAndDisplayAxisMirrorsPreserveCenterPixelAndZoomAnchor() {
        var value = geometry()
        value.actualSize()
        value.pan(by: CGPoint(x: 120, y: 70))
        let center = CGPoint(x: 500, y: 300)
        let pixel = value.imagePoint(at: center)
        value.rotate(clockwise: true)
        value.mirror(horizontal: true)
        value.mirror(horizontal: false)
        #expect(value.imagePoint(at: center) == pixel)
        #expect(value.scale == 0.5 && value.mode == .actualSize)
        let anchor = CGPoint(x: 640, y: 420)
        let before = value.imagePoint(at: anchor)
        value.zoom(by: 1.25, around: anchor)
        let after = value.imagePoint(at: anchor)
        #expect(abs(before.x - after.x) < 0.0001 && abs(before.y - after.y) < 0.0001)

        // 镜像相对当前屏幕轴，而不是旋转前的源图片轴。
        value.fit()
        value.resetOrientation()
        value.rotate(clockwise: true)
        let point = CGPoint(x: center.x + 60, y: center.y)
        let reflected = value.imagePoint(at: CGPoint(x: center.x - 60, y: center.y))
        value.mirror(horizontal: true)
        #expect(value.imagePoint(at: point) == reflected)
    }

    @Test
    func testReloadPreservesOrientationAndRefitsOnlyWhenDimensionsChange() {
        var value = geometry()
        value.rotate(clockwise: true)
        value.actualSize()
        value.pan(by: CGPoint(x: 80, y: 100))
        let before = value
        value.setImage(size: value.imageSize, resetTransform: false)
        #expect(value.orientation == before.orientation && value.offset == before.offset)
        #expect(value.scale == before.scale && value.mode == .actualSize)
        value.resize(to: CGSize(width: 1000, height: 600), backingScale: 1)
        #expect(value.scale == 1)
        value.setImage(size: CGSize(width: 900, height: 600), resetTransform: false)
        #expect(value.orientation == before.orientation && value.mode == .fit && value.offset == .zero)
        value.setImage(size: CGSize(width: 900, height: 600))
        #expect(value.orientation == .identity)
    }
}
