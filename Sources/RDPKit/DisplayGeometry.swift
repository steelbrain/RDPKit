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
        guard localPoint.x.isFinite, localPoint.y.isFinite else {
            return nil
        }

        let contentRect = contentRect
        guard contentRect.contains(localPoint) else {
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
            x: clampedRemoteCoordinate(xRatio * remotePixelSize.width),
            y: clampedRemoteCoordinate(yRatio * remotePixelSize.height)
        )
    }
}

private func clampedRemoteCoordinate(_ value: CGFloat) -> UInt16 {
    guard value.isFinite else {
        return 0
    }
    return UInt16(min(CGFloat(UInt16.max), max(0, value.rounded(.down))))
}
