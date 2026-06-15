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
            RDPSessionCommands()
        }

        WindowGroup("Stats for Nerds", id: RDPWindowID.sessionDiagnostics, for: UUID.self) { sessionID in
            RemoteSessionDiagnosticsWindow(sessionID: sessionID.wrappedValue)
                .environmentObject(launchStore)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 840, height: 720)
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

private struct RDPSessionCommands: Commands {
    @FocusedValue(\.rdpOpenDiagnostics) private var openDiagnostics
    @FocusedValue(\.rdpToggleSessionControls) private var toggleSessionControls
    @FocusedValue(\.rdpSessionControlsVisible) private var sessionControlsVisible
    @FocusedValue(\.rdpStartSession) private var startSession
    @FocusedValue(\.rdpStartSessionTitle) private var startSessionTitle
    @FocusedValue(\.rdpCanStartSession) private var canStartSession
    @FocusedValue(\.rdpCancelSession) private var cancelSession
    @FocusedValue(\.rdpCanCancelSession) private var canCancelSession
    @FocusedValue(\.rdpSyncClipboard) private var syncClipboard
    @FocusedValue(\.rdpCanSyncClipboard) private var canSyncClipboard
    @FocusedValue(\.rdpStartTemporaryClipboardSharing) private var startTemporaryClipboardSharing
    @FocusedValue(\.rdpCanStartTemporaryClipboardSharing) private var canStartTemporaryClipboardSharing

    var body: some Commands {
        CommandMenu("Session") {
            Button(effectiveStartSessionTitle) {
                if let startSession {
                    startSession()
                } else {
                    appKitSessionController?.rdpStartSession()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!effectiveCanStartSession)

            Button("Cancel") {
                if let cancelSession {
                    cancelSession()
                } else {
                    appKitSessionController?.rdpCancelSession()
                }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!effectiveCanCancelSession)

            Divider()

            Button(effectiveSessionControlsVisible ? "Hide Controls" : "Show Controls") {
                if let toggleSessionControls {
                    toggleSessionControls()
                } else {
                    appKitSessionController?.rdpToggleSessionControls()
                }
            }
            .disabled(!hasSessionCommandTarget)

            Divider()

            Button("Sync Clipboard Now") {
                if let syncClipboard {
                    syncClipboard()
                } else {
                    appKitSessionController?.rdpSyncClipboard()
                }
            }
            .disabled(!effectiveCanSyncClipboard)

            Button("Share Clipboard for 30 Seconds") {
                if let startTemporaryClipboardSharing {
                    startTemporaryClipboardSharing()
                } else {
                    appKitSessionController?.rdpStartTemporaryClipboardSharing()
                }
            }
            .disabled(!effectiveCanStartTemporaryClipboardSharing)

            Divider()

            Button("Open Stats for Nerds") {
                if let openDiagnostics {
                    openDiagnostics()
                } else {
                    appKitSessionController?.rdpOpenDiagnostics()
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!hasSessionCommandTarget)
        }
    }

    private var appKitSessionController: RDPSessionCommandHandling? {
        NSApp.keyWindow?.contentViewController as? RDPSessionCommandHandling
    }

    private var hasSessionCommandTarget: Bool {
        openDiagnostics != nil || appKitSessionController != nil
    }

    private var effectiveStartSessionTitle: String {
        startSessionTitle ?? appKitSessionController?.rdpStartSessionTitle ?? "Connect"
    }

    private var effectiveCanStartSession: Bool {
        if startSession != nil {
            return canStartSession == true
        }
        return appKitSessionController?.rdpCanStartSession == true
    }

    private var effectiveCanCancelSession: Bool {
        if cancelSession != nil {
            return canCancelSession == true
        }
        return appKitSessionController?.rdpCanCancelSession == true
    }

    private var effectiveSessionControlsVisible: Bool {
        sessionControlsVisible ?? appKitSessionController?.rdpSessionControlsVisible ?? false
    }

    private var effectiveCanSyncClipboard: Bool {
        if syncClipboard != nil {
            return canSyncClipboard == true
        }
        return appKitSessionController?.rdpCanSyncClipboard == true
    }

    private var effectiveCanStartTemporaryClipboardSharing: Bool {
        if startTemporaryClipboardSharing != nil {
            return canStartTemporaryClipboardSharing == true
        }
        return appKitSessionController?.rdpCanStartTemporaryClipboardSharing == true
    }
}

private struct RDPOpenDiagnosticsFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPToggleSessionControlsFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPSessionControlsVisibleFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

private struct RDPStartSessionFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPStartSessionTitleFocusedValueKey: FocusedValueKey {
    typealias Value = String
}

private struct RDPCanStartSessionFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

private struct RDPCancelSessionFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPCanCancelSessionFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

private struct RDPSyncClipboardFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPCanSyncClipboardFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

private struct RDPStartTemporaryClipboardSharingFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RDPCanStartTemporaryClipboardSharingFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var rdpOpenDiagnostics: (() -> Void)? {
        get { self[RDPOpenDiagnosticsFocusedValueKey.self] }
        set { self[RDPOpenDiagnosticsFocusedValueKey.self] = newValue }
    }

    var rdpToggleSessionControls: (() -> Void)? {
        get { self[RDPToggleSessionControlsFocusedValueKey.self] }
        set { self[RDPToggleSessionControlsFocusedValueKey.self] = newValue }
    }

    var rdpSessionControlsVisible: Bool? {
        get { self[RDPSessionControlsVisibleFocusedValueKey.self] }
        set { self[RDPSessionControlsVisibleFocusedValueKey.self] = newValue }
    }

    var rdpStartSession: (() -> Void)? {
        get { self[RDPStartSessionFocusedValueKey.self] }
        set { self[RDPStartSessionFocusedValueKey.self] = newValue }
    }

    var rdpStartSessionTitle: String? {
        get { self[RDPStartSessionTitleFocusedValueKey.self] }
        set { self[RDPStartSessionTitleFocusedValueKey.self] = newValue }
    }

    var rdpCanStartSession: Bool? {
        get { self[RDPCanStartSessionFocusedValueKey.self] }
        set { self[RDPCanStartSessionFocusedValueKey.self] = newValue }
    }

    var rdpCancelSession: (() -> Void)? {
        get { self[RDPCancelSessionFocusedValueKey.self] }
        set { self[RDPCancelSessionFocusedValueKey.self] = newValue }
    }

    var rdpCanCancelSession: Bool? {
        get { self[RDPCanCancelSessionFocusedValueKey.self] }
        set { self[RDPCanCancelSessionFocusedValueKey.self] = newValue }
    }

    var rdpSyncClipboard: (() -> Void)? {
        get { self[RDPSyncClipboardFocusedValueKey.self] }
        set { self[RDPSyncClipboardFocusedValueKey.self] = newValue }
    }

    var rdpCanSyncClipboard: Bool? {
        get { self[RDPCanSyncClipboardFocusedValueKey.self] }
        set { self[RDPCanSyncClipboardFocusedValueKey.self] = newValue }
    }

    var rdpStartTemporaryClipboardSharing: (() -> Void)? {
        get { self[RDPStartTemporaryClipboardSharingFocusedValueKey.self] }
        set { self[RDPStartTemporaryClipboardSharingFocusedValueKey.self] = newValue }
    }

    var rdpCanStartTemporaryClipboardSharing: Bool? {
        get { self[RDPCanStartTemporaryClipboardSharingFocusedValueKey.self] }
        set { self[RDPCanStartTemporaryClipboardSharingFocusedValueKey.self] = newValue }
    }
}
