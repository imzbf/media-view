import AppKit
import QuartzCore
import Testing
@testable import ImageView

@Suite(.serialized)
final class ImageCanvasViewTests {
    @MainActor
    @Test(arguments: [false, true])
    func testSwitchingSmallToLargeImageDoesNotAnimateOldContents(commitsLoadingState: Bool) throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        canvas.layout()
        let small = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                 isFullResolution: true)
        let large = DecodedImage(image: try testBitmap(red: 0, blue: 1),
                                 pixelSize: CGSize(width: 2000, height: 1200), isFullResolution: false)
        canvas.display(small, filename: "small.png", resetTransform: true)
        CATransaction.flush()
        let layer = try #require(canvas.layer?.sublayers?.first)
        let smallFrame = layer.frame
        // 无窗口的图层没有默认呈现动画；提供原生 contents action，稳定复现窗口中的旧图淡出。
        let transition = CABasicAnimation(keyPath: "contents")
        transition.fromValue = small.image
        transition.duration = 1
        layer.actions = ["contents": transition]

        // 覆盖缓存命中和异步解码：等待期间保留旧图，替换时不能把旧位图动画到新尺寸。
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        canvas.prepareForLoading()
        #expect((layer.contents as! CGImage?) === small.image)
        #expect(layer.frame == smallFrame && canvas.geometry.imageSize == small.pixelSize)
        #expect(layer.animationKeys()?.isEmpty ?? true, "Loading must keep the old image without a fade")
        CATransaction.commit()
        if commitsLoadingState { CATransaction.flush() }

        canvas.display(large, filename: "large.png", resetTransform: true)
        #expect(layer.frame.width > smallFrame.width && layer.frame.height > smallFrame.height)
        #expect(layer.frame == canvas.geometry.imageFrame)
        #expect((layer.contents as! CGImage?) === large.image)
        #expect(layer.animationKeys()?.isEmpty ?? true, "The new bounds must not retain an animation of the old image")
    }

    @MainActor
    @Test
    func testInitialLoadingAndFailureKeepStatusWithoutAnimatingOldImage() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let status = try #require(canvas.subviews.compactMap { $0 as? NSStackView }.first)
        let progress = try #require(canvas.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        canvas.prepareForLoading()
        #expect(!status.isHidden && progress.isHidden && !canvas.geometry.hasImage)
        let titles = status.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(titles.contains("正在载入…"))

        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 80, height: 40),
                                 isFullResolution: true)
        canvas.display(image, filename: "old.png", resetTransform: true)
        let layer = try #require(canvas.layer?.sublayers?.first)
        layer.actions = ["contents": CABasicAnimation(keyPath: "contents")]
        canvas.prepareForLoading()
        canvas.setLoadingIndicatorVisible(true)
        // 切到损坏图片时必须清掉暂留画面，不能把上一张误当成当前图片继续显示。
        canvas.showStatus(title: "无法解码图片", detail: "", symbol: "exclamationmark.triangle")
        #expect(layer.contents == nil && !canvas.geometry.hasImage)
        #expect(!status.isHidden && progress.isHidden)
        #expect(layer.animationKeys()?.isEmpty ?? true)
    }

    @MainActor
    @Test
    func testSpaceDragAndFocusLoss() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        canvas.layout()
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 2000, height: 1200),
                                 isFullResolution: false)
        canvas.display(image, filename: "test.png", resetTransform: true)
        canvas.actualSize()
        let down = try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        let dragged = try mouse(.leftMouseDragged, at: CGPoint(x: 220, y: 140))

        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: dragged)
        #expect(canvas.geometry.offset == .zero, "Dragging without space must not pan")

        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        canvas.keyDown(with: space)
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: dragged)
        #expect(canvas.geometry.offset == CGPoint(x: 120, y: 40))

        canvas.cancelInteraction()
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: dragged)
        #expect(canvas.geometry.offset == CGPoint(x: 120, y: 40), "Losing focus releases space-drag state")
    }

    @MainActor
    @Test
    func testAnimationFrameChangesOnlyLayerContents() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        canvas.layout()
        let first = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 2000, height: 1200),
                                 isFullResolution: false)
        let next = DecodedImage(image: try testBitmap(red: 0, blue: 1),
                                pixelSize: first.pixelSize, isFullResolution: false)
        canvas.display(first, filename: "animation.gif", resetTransform: true)
        canvas.actualSize()
        canvas.zoom(by: 2)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        canvas.keyDown(with: space)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 170)))
        let before = canvas.geometry
        let layer = try #require(canvas.layer?.sublayers?.first)
        var zoomChanges = 0
        canvas.onZoomChanged = { zoomChanges += 1 }
        canvas.displayFrame(next)
        #expect(canvas.geometry.imageSize == before.imageSize)
        #expect(canvas.geometry.scale == before.scale && canvas.geometry.offset == before.offset)
        #expect(canvas.geometry.mode == before.mode && layer.frame == before.imageFrame)
        #expect(zoomChanges == 0, "Frame changes must not trigger layout or zoom callbacks")
        #expect(layer.animationKeys()?.isEmpty ?? true)
        let actual = try #require(layer.contents as! CGImage?)
        #expect(try testPixels(actual) == testPixels(next.image))
    }

    @MainActor
    @Test
    func testTransformedFramesAndQualityUpgradeReuseGeometryAndImageContents() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        canvas.layout()
        let first = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 2000, height: 1200),
                                 isFullResolution: false)
        canvas.display(first, filename: "animation.gif", resetTransform: true)
        canvas.actualSize()
        canvas.rotate(clockwise: true)
        canvas.mirror(horizontal: true)
        let before = canvas.geometry
        let layer = try #require(canvas.layer?.sublayers?.first)
        #expect((layer.contents as! CGImage?) === first.image, "Direction changes must not allocate a new bitmap")
        let next = DecodedImage(image: try testBitmap(red: 0, blue: 1), pixelSize: first.pixelSize,
                                isFullResolution: true)
        canvas.displayFrame(next)
        canvas.display(next, filename: "animation.gif", resetTransform: false)
        #expect(canvas.geometry.orientation == before.orientation && canvas.geometry.scale == before.scale)
        #expect(canvas.geometry.offset == before.offset && layer.frame == before.imageFrame)
        #expect(layer.affineTransform() == before.orientation)
        #expect(layer.animationKeys()?.isEmpty ?? true)
    }

    @MainActor
    @Test
    func testContextMenuKeepsTransformAndReleasesSpaceDrag() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        canvas.layout()
        let image = DecodedImage(image: try testBitmap(), pixelSize: CGSize(width: 2000, height: 1200),
                                 isFullResolution: false)
        var menuRequests = 0
        let menu = NSMenu()
        canvas.onContextMenu = { menuRequests += 1; return menu }
        canvas.display(image, filename: "test.png", resetTransform: true)
        canvas.actualSize()
        canvas.rotate(clockwise: true)
        #expect(menuRequests == 0, "Displaying or transforming an image must not build a context menu")
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        canvas.keyDown(with: space)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 140, y: 130)))
        let before = canvas.geometry
        #expect(canvas.menu(for: try mouse(.rightMouseDown, at: CGPoint(x: 140, y: 130))) === menu)
        #expect(menuRequests == 1)
        // 菜单可能吞掉 keyUp；右键之后直接拖动必须保持原位置，而非卡在空格平移模式。
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 140, y: 130)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 250, y: 220)))
        #expect(canvas.geometry.offset == before.offset && canvas.geometry.scale == before.scale)
        #expect(canvas.geometry.orientation == before.orientation)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
