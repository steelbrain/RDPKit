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

    public init(
        remotePixelSize: CGSize,
        sourceRect: CGRect? = nil,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin
    ) {
        self.remotePixelSize = remotePixelSize
        self.sourceRect = sourceRect
        self.bounds = bounds
        self.coordinateOrigin = coordinateOrigin
    }

    /// Shows `frame`, or only `monitor` of it, one of the frame's
    /// ``RDPFrameMetadata/monitors``.
    public init(
        frame: RDPFrameMetadata,
        monitor: RDPRemoteMonitor? = nil,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin
    ) {
        self.init(
            remotePixelSize: CGSize(width: Int(frame.width), height: Int(frame.height)),
            sourceRect: monitor.map {
                CGRect(x: Int($0.rect.left), y: Int($0.rect.top), width: Int($0.rect.width), height: Int($0.rect.height))
            },
            bounds: bounds,
            coordinateOrigin: coordinateOrigin
        )
    }

    /// Where the view draws the shown part of the remote desktop: aspect-fit and centred in
    /// ``bounds``.
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
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    public func remotePoint(from localPoint: CGPoint) -> RDPRemotePoint? {
        remotePoint(from: localPoint, contentRect: contentRect)
    }

    /// Maps `localPoint` with the desktop drawn in `contentRect` rather than in ``contentRect``:
    /// a view that aligns ``contentRect`` to the screen's pixels passes the rect it draws in.
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
