import CoreGraphics
import Foundation

public enum RDPLocalCoordinateOrigin: Equatable, Sendable {
    case topLeft
    case bottomLeft
}

public struct RDPRemoteDisplayViewport: Equatable, Sendable {
    public var remotePixelSize: CGSize
    /// The part of the remote desktop the view shows, in remote pixels from the desktop's
    /// top-left, such as one ``RDPRemoteMonitor``'s rect; nil shows all of ``remotePixelSize``.
    /// Only the part inside the desktop is shown, and a rect with none of it shows nothing.
    public var sourceRect: CGRect?
    public var bounds: CGRect
    public var coordinateOrigin: RDPLocalCoordinateOrigin
    /// The screen's pixels per point of ``bounds``, such as the window's `backingScaleFactor`.
    /// When set, ``contentRect`` moves by less than a pixel onto a whole one, so letterboxing
    /// does not blur a desktop shown one to one, and keeps its size, so the scale stays the same
    /// in both directions. Whole pixels are counted from ``bounds``' coordinate origin, which
    /// must sit on one, as it does in a view that fills its window. nil, or a factor that is not
    /// positive, leaves ``contentRect`` where aspect-fit puts it.
    public var backingScaleFactor: CGFloat?

    public init(
        remotePixelSize: CGSize,
        sourceRect: CGRect? = nil,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin,
        backingScaleFactor: CGFloat? = nil
    ) {
        self.remotePixelSize = remotePixelSize
        self.sourceRect = sourceRect
        self.bounds = bounds
        self.coordinateOrigin = coordinateOrigin
        self.backingScaleFactor = backingScaleFactor
    }

    /// Shows `frame`, or only `monitor` of it, one of the frame's
    /// ``RDPFrameMetadata/monitors``.
    public init(
        frame: RDPFrameMetadata,
        monitor: RDPRemoteMonitor? = nil,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin,
        backingScaleFactor: CGFloat? = nil
    ) {
        self.init(
            remotePixelSize: CGSize(width: Int(frame.width), height: Int(frame.height)),
            sourceRect: monitor.map {
                CGRect(x: Int($0.rect.left), y: Int($0.rect.top), width: Int($0.rect.width), height: Int($0.rect.height))
            },
            bounds: bounds,
            coordinateOrigin: coordinateOrigin,
            backingScaleFactor: backingScaleFactor
        )
    }

    /// Where the view draws the shown part of the remote desktop: aspect-fit and centred in
    /// ``bounds``, on a whole screen pixel when ``backingScaleFactor`` is set.
    public var contentRect: CGRect {
        guard let shownRect = shownRemoteRect,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0
        else {
            return .zero
        }

        let scale = min(bounds.width / shownRect.width, bounds.height / shownRect.height)
        let width = shownRect.width * scale
        let height = shownRect.height * scale
        let fitted = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        guard let backingScaleFactor, backingScaleFactor.isFinite, backingScaleFactor > 0 else {
            return fitted
        }
        let onPixel = { (value: CGFloat) in (value * backingScaleFactor).rounded() / backingScaleFactor }
        return CGRect(x: onPixel(fitted.minX), y: onPixel(fitted.minY), width: width, height: height)
    }

    public func remotePoint(from localPoint: CGPoint) -> RDPRemotePoint? {
        remotePoint(from: localPoint, contentRect: contentRect)
    }

    /// Maps `localPoint` with the desktop drawn in `contentRect` rather than in ``contentRect``,
    /// for a view that places the desktop itself; ``backingScaleFactor`` aligns it to the
    /// screen's pixels without one.
    ///
    /// The edge the remote desktop starts at is inside and the opposite one outside. With
    /// ``RDPLocalCoordinateOrigin/bottomLeft`` that puts the top edge inside and the bottom
    /// one outside, as `NSMouseInRect` counts an unflipped view's edges: AppKit reports the
    /// mouse in a view's top pixel row at the view's maxY.
    public func remotePoint(from localPoint: CGPoint, contentRect: CGRect) -> RDPRemotePoint? {
        guard let shownRect = shownRemoteRect,
              localPoint.x.isFinite,
              localPoint.y.isFinite,
              [contentRect.minX, contentRect.minY, contentRect.width, contentRect.height].allSatisfy(\.isFinite),
              contentRect.width > 0,
              contentRect.height > 0,
              contentRect.minX <= localPoint.x,
              localPoint.x < contentRect.maxX
        else {
            return nil
        }
        let isInsideVertically = switch coordinateOrigin {
        case .topLeft:
            contentRect.minY <= localPoint.y && localPoint.y < contentRect.maxY
        case .bottomLeft:
            contentRect.minY < localPoint.y && localPoint.y <= contentRect.maxY
        }
        guard isInsideVertically else {
            return nil
        }

        let xRatio = (localPoint.x - contentRect.minX) / contentRect.width
        let yRatio = switch coordinateOrigin {
        case .topLeft:
            (localPoint.y - contentRect.minY) / contentRect.height
        case .bottomLeft:
            (contentRect.maxY - localPoint.y) / contentRect.height
        }
        return RDPRemotePoint(
            x: clampedRemoteCoordinate(shownRect.minX + xRatio * shownRect.width, from: shownRect.minX, to: shownRect.maxX),
            y: clampedRemoteCoordinate(shownRect.minY + yRatio * shownRect.height, from: shownRect.minY, to: shownRect.maxY)
        )
    }

    /// The remote pixel nearest `localPoint`, for a drag, or a button released, past the
    /// desktop: a point outside ``contentRect`` first stops on its edge, by the convention
    /// ``remotePoint(from:contentRect:)`` counts edges by, so a drag below a
    /// ``RDPLocalCoordinateOrigin/bottomLeft`` view reaches the bottom row. nil only when nothing
    /// is shown or `localPoint` is not finite.
    public func nearestRemotePoint(from localPoint: CGPoint) -> RDPRemotePoint? {
        nearestRemotePoint(from: localPoint, contentRect: contentRect)
    }

    /// ``nearestRemotePoint(from:)`` with the desktop drawn in `contentRect`.
    public func nearestRemotePoint(from localPoint: CGPoint, contentRect: CGRect) -> RDPRemotePoint? {
        guard localPoint.x.isFinite,
              localPoint.y.isFinite,
              [contentRect.minX, contentRect.minY, contentRect.width, contentRect.height].allSatisfy(\.isFinite),
              contentRect.width > 0,
              contentRect.height > 0
        else {
            return nil
        }
        let x = min(max(localPoint.x, contentRect.minX), contentRect.maxX.nextDown)
        let y = switch coordinateOrigin {
        case .topLeft:
            min(max(localPoint.y, contentRect.minY), contentRect.maxY.nextDown)
        case .bottomLeft:
            min(max(localPoint.y, contentRect.minY.nextUp), contentRect.maxY)
        }
        return remotePoint(from: CGPoint(x: x, y: y), contentRect: contentRect)
    }

    /// ``sourceRect`` within the remote desktop, or the whole desktop; nil when nothing of it
    /// is shown.
    private var shownRemoteRect: CGRect? {
        guard remotePixelSize.width.isFinite,
              remotePixelSize.height.isFinite,
              remotePixelSize.width > 0,
              remotePixelSize.height > 0
        else {
            return nil
        }
        let desktop = CGRect(origin: .zero, size: remotePixelSize)
        guard let sourceRect else {
            return desktop
        }
        guard [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height].allSatisfy(\.isFinite) else {
            return nil
        }
        let shownRect = desktop.intersection(sourceRect)
        guard !shownRect.isNull, shownRect.width > 0, shownRect.height > 0 else {
            return nil
        }
        return shownRect
    }
}

// Keeps the coordinate on a remote pixel of the shown part, should rounding take a point by
// its far edge to `end` itself.
private func clampedRemoteCoordinate(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> UInt16 {
    let firstPixel = min(CGFloat(UInt16.max), max(0, start.rounded(.down)))
    let lastPixel = min(CGFloat(UInt16.max), max(firstPixel, end.rounded(.up) - 1))
    guard value.isFinite else {
        return UInt16(firstPixel)
    }
    return UInt16(min(lastPixel, max(firstPixel, value.rounded(.down))))
}
