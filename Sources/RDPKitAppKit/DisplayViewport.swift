#if os(macOS)
import AppKit
import RDPKit

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
