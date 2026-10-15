import Foundation
import CoreGraphics

/// scale 的单位是“视图点 / 原图像素”，因此 Retina 上的原始尺寸为 1 / backingScale。
struct CanvasGeometry {
    enum Mode { case fit, actualSize, custom }

    private(set) var imageSize: CGSize = .zero
    private(set) var viewportSize: CGSize = .zero
    private(set) var backingScale: CGFloat = 1
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    private(set) var mode: Mode = .fit
    private(set) var orientation = CGAffineTransform.identity
    let minimumVisibleMargin: CGFloat = 32

    var hasImage: Bool { imageSize.width > 0 && imageSize.height > 0 }
    /// 方向矩阵只包含整数的四分之一圈与镜像；边界计算不受三角函数舍入误差影响。
    var orientedImageSize: CGSize {
        CGSize(width: abs(orientation.a) * imageSize.width + abs(orientation.c) * imageSize.height,
               height: abs(orientation.b) * imageSize.width + abs(orientation.d) * imageSize.height)
    }
    var fitScale: CGFloat {
        guard hasImage, viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        // 小图不默认放大；⌘1 始终代表一个图片像素对应一个物理屏幕像素。
        return min(viewportSize.width / orientedImageSize.width,
                   viewportSize.height / orientedImageSize.height, 1 / backingScale)
    }
    var imageFrame: CGRect {
        let size = CGSize(width: orientedImageSize.width * scale, height: orientedImageSize.height * scale)
        return CGRect(
            x: (viewportSize.width - size.width) / 2 + offset.x,
            y: (viewportSize.height - size.height) / 2 + offset.y,
            width: size.width, height: size.height
        )
    }

    mutating func setImage(size: CGSize, resetTransform: Bool = true) {
        let sizeChanged = imageSize != size
        imageSize = size
        if resetTransform { orientation = .identity }
        // 同路径重新载入保留方向；外部修改了像素尺寸时重新适配，不能沿用旧几何尺寸。
        if resetTransform || sizeChanged { fit() }
    }

    mutating func rotate(clockwise: Bool) {
        let turn = clockwise
            ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
            : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        setOrientation(orientation.concatenating(turn))
    }

    mutating func mirror(horizontal: Bool) {
        setOrientation(orientation.concatenating(
            CGAffineTransform(scaleX: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
        ))
    }

    mutating func resetOrientation() { setOrientation(.identity) }

    /// 先还原屏幕中心对应的源像素，再改变方向；自定义缩放下旋转不会跳到另一处细节。
    private mutating func setOrientation(_ value: CGAffineTransform) {
        guard hasImage else { return }
        let centeredPixel = CGPoint(x: -offset.x / scale, y: -offset.y / scale)
            .applying(orientation.inverted())
        orientation = value
        if mode == .fit {
            fit()
        } else {
            let transformed = centeredPixel.applying(orientation)
            offset = CGPoint(x: -transformed.x * scale, y: -transformed.y * scale)
            clampOffset()
        }
    }

    /// 统一提供视口到原图的逆映射，旋转和镜像后的缩放锚点仍可用原图像素验证。
    func imagePoint(at point: CGPoint) -> CGPoint {
        let centered = CGPoint(x: (point.x - viewportSize.width / 2 - offset.x) / scale,
                               y: (point.y - viewportSize.height / 2 - offset.y) / scale)
            .applying(orientation.inverted())
        return CGPoint(x: centered.x + imageSize.width / 2, y: centered.y + imageSize.height / 2)
    }

    mutating func resize(to size: CGSize, backingScale newBackingScale: CGFloat) {
        let previousBackingScale = backingScale
        viewportSize = size
        backingScale = max(1, newBackingScale)
        switch mode {
        case .fit: fit()
        case .actualSize:
            scale = 1 / backingScale
            offset.x *= previousBackingScale / backingScale
            offset.y *= previousBackingScale / backingScale
            clampOffset()
        case .custom:
            scale *= previousBackingScale / backingScale
            offset.x *= previousBackingScale / backingScale
            offset.y *= previousBackingScale / backingScale
            clampOffset()
        }
    }

    mutating func fit() {
        mode = .fit
        scale = fitScale
        offset = .zero
    }

    mutating func actualSize() {
        mode = .actualSize
        scale = 1 / backingScale
        offset = .zero
    }

    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard hasImage, factor.isFinite, factor > 0 else { return }
        let newScale = min(max(scale * factor, fitScale * 0.1), max(32 / backingScale, fitScale))
        let ratio = newScale / scale
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        // 保持光标下的原图坐标不变，不能只改变图层尺寸后再次居中。
        offset.x = anchor.x - center.x - (anchor.x - center.x - offset.x) * ratio
        offset.y = anchor.y - center.y - (anchor.y - center.y - offset.y) * ratio
        scale = newScale
        mode = .custom
        clampOffset()
    }

    mutating func pan(by delta: CGPoint) {
        guard hasImage else { return }
        offset.x += delta.x
        offset.y += delta.y
        clampOffset()
    }

    private mutating func clampOffset() {
        func clamp(_ value: CGFloat, image: CGFloat, viewport: CGFloat) -> CGFloat {
            guard image > viewport else { return 0 }
            let margin = min(minimumVisibleMargin, viewport / 2)
            let limit = (image + viewport) / 2 - margin
            return min(max(value, -limit), limit)
        }
        offset.x = clamp(offset.x, image: orientedImageSize.width * scale, viewport: viewportSize.width)
        offset.y = clamp(offset.y, image: orientedImageSize.height * scale, viewport: viewportSize.height)
    }
}
