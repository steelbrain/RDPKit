import CoreGraphics
import Foundation

public enum RDPLocalCoordinateOrigin: Equatable, Sendable {
    case topLeft
    case bottomLeft
}

public struct RDPRemoteDisplayViewport: Equatable, Sendable {
    public var remotePixelSize: CGSize
    public var bounds: CGRect
    public var coordinateOrigin: RDPLocalCoordinateOrigin

    public init(
        remotePixelSize: CGSize,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin
    ) {
        self.remotePixelSize = remotePixelSize
        self.bounds = bounds
        self.coordinateOrigin = coordinateOrigin
    }

    public init(
        frame: RDPFrameMetadata,
        bounds: CGRect,
        coordinateOrigin: RDPLocalCoordinateOrigin
    ) {
        self.init(
            remotePixelSize: CGSize(width: Int(frame.width), height: Int(frame.height)),
            bounds: bounds,
            coordinateOrigin: coordinateOrigin
        )
    }

    public var contentRect: CGRect {
        guard remotePixelSize.width.isFinite,
              remotePixelSize.height.isFinite,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              remotePixelSize.width > 0,
              remotePixelSize.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else {
            return .zero
        }

        let scale = min(bounds.width / remotePixelSize.width, bounds.height / remotePixelSize.height)
        let width = remotePixelSize.width * scale
        let height = remotePixelSize.height * scale
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
        guard localPoint.x.isFinite,
              localPoint.y.isFinite,
              [contentRect.minX, contentRect.minY, contentRect.width, contentRect.height].allSatisfy(\.isFinite),
              contentRect.width > 0,
              contentRect.height > 0,
              remotePixelSize.width.isFinite,
              remotePixelSize.height.isFinite,
              remotePixelSize.width > 0,
              remotePixelSize.height > 0,
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
            x: clampedRemoteCoordinate(xRatio * remotePixelSize.width, extent: remotePixelSize.width),
            y: clampedRemoteCoordinate(yRatio * remotePixelSize.height, extent: remotePixelSize.height)
        )
    }
}

// Keeps the coordinate on a remote pixel, should rounding take a point by the far edge to `extent` itself.
private func clampedRemoteCoordinate(_ value: CGFloat, extent: CGFloat) -> UInt16 {
    guard value.isFinite else {
        return 0
    }
    let lastPixel = min(CGFloat(UInt16.max), max(0, extent.rounded(.up) - 1))
    return UInt16(min(lastPixel, max(0, value.rounded(.down))))
}
