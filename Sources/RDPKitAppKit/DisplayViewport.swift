#if os(macOS)
import AppKit
import RDPKit

/// Maps a point of a view, in its coordinates, onto the remote desktop: what
/// `RDPRemoteInputView.pointMapping` takes, for a view that shows part of the desktop.
public protocol RDPRemotePointMapping {
    /// The remote pixel under `localPoint`, or nil where the view shows no desktop, such as the
    /// letterbox or a monitor left out.
    func remotePoint(at localPoint: CGPoint) -> RDPRemotePoint?
    /// The shown remote pixel nearest `localPoint`, where a drag that leaves the shown area
    /// stops; nil when nothing is shown.
    func nearestRemotePoint(to localPoint: CGPoint) -> RDPRemotePoint?
}

extension RDPRemoteDisplayViewport: RDPRemotePointMapping {
    public func remotePoint(at localPoint: CGPoint) -> RDPRemotePoint? {
        remotePoint(from: localPoint)
    }

    public func nearestRemotePoint(to localPoint: CGPoint) -> RDPRemotePoint? {
        nearestRemotePoint(from: localPoint)
    }
}

extension RDPRemoteDisplayViewport {
    /// Where `view`, which fills its window, shows `frame`: on whole screen pixels, as Display
    /// Control makes desktop widths even and a desktop sized to a view of odd width would
    /// otherwise sit half a pixel off and blur. A view that draws the desktop and the
    /// `RDPRemoteInputView` over it map with the same viewport, so the pointer lands where the
    /// desktop is drawn.
    @MainActor
    public init(frame: RDPFrameMetadata, view: NSView) {
        self.init(
            frame: frame,
            bounds: view.bounds,
            coordinateOrigin: .bottomLeft,
            backingScaleFactor: view.window?.backingScaleFactor
        )
    }
}
#endif
