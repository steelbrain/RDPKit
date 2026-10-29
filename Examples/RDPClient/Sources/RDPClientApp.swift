import AppKit
import SwiftUI

@main
struct RDPClientApp: App {
    @NSApplicationDelegateAdaptor(RDPClientAppDelegate.self) private var appDelegate
    @StateObject private var launchStore = RDPConnectionLaunchStore()

    var body: some Scene {
        WindowGroup("Connections") {
            ConnectionManagerView()
                .environmentObject(launchStore)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .commands {
            RDPSessionCommands(center: launchStore.sessionCommands)
        }
    }
}

@MainActor
private final class RDPClientAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        activateViewerWindow()
    }

    private func activateViewerWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if makeVisibleWindowKey() {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            _ = self.makeVisibleWindowKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeVisibleWindowKey() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

struct RDPSessionCommandState: Equatable {
    var startTitle: String
    var canStart: Bool
    var canCancel: Bool
    var controlsVisible: Bool
    var canSyncClipboard: Bool
    var canStartTemporaryClipboardSharing: Bool
}

/// Publishes the key session window's command state so the Session menu stays current.
@MainActor
final class RDPSessionCommandCenter: ObservableObject {
    @Published private(set) var state: RDPSessionCommandState?
    private(set) weak var controller: RDPRemoteSessionViewController?

    func publish(_ state: RDPSessionCommandState, from controller: RDPRemoteSessionViewController) {
        self.controller = controller
        if self.state != state {
            self.state = state
        }
    }

    func withdraw(_ controller: RDPRemoteSessionViewController) {
        guard self.controller === controller else {
            return
        }
        self.controller = nil
        state = nil
    }
}

private struct RDPSessionCommands: Commands {
    @ObservedObject var center: RDPSessionCommandCenter

    var body: some Commands {
        CommandMenu("Session") {
            Button(center.state?.startTitle ?? "Connect") {
                center.controller?.startSession()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(center.state?.canStart != true)

            // No shortcut: Cmd-. would end a session at one keystroke and keep Win-. from the server.
            Button("Cancel") {
                center.controller?.cancelConnection()
            }
            .disabled(center.state?.canCancel != true)

            Divider()

            Button(center.state?.controlsVisible == true ? "Hide Controls" : "Show Controls") {
                center.controller?.toggleSessionControls()
            }
            .disabled(center.state == nil)

            Divider()

            Button("Sync Clipboard Now") {
                center.controller?.syncClipboardNow()
            }
            .disabled(center.state?.canSyncClipboard != true)

            Button("Share Clipboard for 30 Seconds") {
                center.controller?.startTemporaryClipboardSharing()
            }
            .disabled(center.state?.canStartTemporaryClipboardSharing != true)

            Divider()

            Button("Open Stats for Nerds") {
                center.controller?.openDiagnosticsWindow()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(center.state == nil)
        }
    }
}
