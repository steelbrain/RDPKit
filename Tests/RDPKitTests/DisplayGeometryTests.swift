import CoreGraphics
@testable import RDPKit
import Testing

@Test func remoteDisplayViewportAspectFitsRemotePixelsIntoBounds() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == CGRect(x: 0, y: 50, width: 200, height: 100))
}

@Test func remoteDisplayViewportMapsBottomLeftCoordinatesToRemotePoint() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 149.9)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 100)) == RDPRemotePoint(x: 50, y: 25))
    #expect(viewport.remotePoint(from: CGPoint(x: 199, y: 51)) == RDPRemotePoint(x: 99, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 49)) == nil)
}

@Test func remoteDisplayViewportMapsTopLeftCoordinatesToRemotePoint() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .topLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 50)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 100)) == RDPRemotePoint(x: 50, y: 25))
    #expect(viewport.remotePoint(from: CGPoint(x: 199, y: 149)) == RDPRemotePoint(x: 99, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 49)) == nil)
}

@Test func remoteDisplayViewportRejectsInvalidGeometry() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: .zero,
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == .zero)
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0)) == nil)
}

@Test func remoteDisplayViewportRejectsNonFiniteGeometry() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: CGFloat.infinity, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )
    let validViewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == .zero)
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0)) == nil)
    #expect(validViewport.remotePoint(from: CGPoint(x: CGFloat.nan, y: 0)) == nil)
}
