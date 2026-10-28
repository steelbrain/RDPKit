import AppKit

@MainActor
final class RDPRemoteSessionWindowController: NSWindowController, NSWindowDelegate {
    let sessionID: UUID
    var onClose: ((UUID) -> Void)?

    init(
        sessionID: UUID,
        draft: RDPConnectionDraft,
        launchStore: RDPConnectionLaunchStore,
        preferredScreen: NSScreen? = nil
    ) {
        self.sessionID = sessionID

        let sessionController = RDPRemoteSessionViewController(
            sessionID: sessionID,
            draft: draft,
            launchStore: launchStore
        )

        let window = NSWindow(contentViewController: sessionController)
        window.title = draft.displayName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 620)
        RDPRemoteSessionWindowPlacement.applyInitialFrame(
            to: window,
            preferredScreen: preferredScreen
        )

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowDidBecomeKey(_: Notification) {
        sessionController?.publishSessionCommands()
    }

    func windowDidResignKey(_: Notification) {
        sessionController?.withdrawSessionCommands()
    }

    func windowWillClose(_: Notification) {
        sessionController?.closeSession()
        onClose?(sessionID)
    }

    private var sessionController: RDPRemoteSessionViewController? {
        contentViewController as? RDPRemoteSessionViewController
    }
}

private enum RDPRemoteSessionWindowPlacement {
    @MainActor
    static func applyInitialFrame(to window: NSWindow, preferredScreen: NSScreen?) {
        if let visibleFrame = (preferredScreen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(visibleFrame, display: false)
        } else {
            window.setContentSize(NSSize(width: 1200, height: 800))
        }
    }
}
