import AppKit
import Foundation
import RDPKit
import SwiftUI

enum RDPWindowID {
    static let sessionDiagnostics = "session-diagnostics"
}

struct RDPConnectionDraft: Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String
    var domain: String
    var password: String
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var hideCertificateWarnings: Bool
    var timeoutSeconds: Int
    var clipboardSharingEnabled: Bool
    var audioPlaybackEnabled: Bool
    var rememberPassword: Bool

    var configuration: RDPConnectionConfiguration {
        RDPConnectionConfiguration(
            host: host,
            port: port,
            credentials: try? RDPCredentials.validated(
                username: username,
                domain: domain,
                password: password
            ),
            timeoutSeconds: timeoutSeconds,
            hideCertificateWarnings: hideCertificateWarnings,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            clipboardEnabled: clipboardSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled
        )
    }

    var identity: RDPConnectionIdentity {
        configuration.identity
    }

    var displayName: String {
        configuration.displayName
    }
}

@MainActor
final class RDPConnectionLaunchStore: ObservableObject {
    private var sessionWindowControllers: [UUID: RDPRemoteSessionWindowController] = [:]
    private var diagnosticsWindowControllers: [UUID: RDPRemoteSessionDiagnosticsWindowController] = [:]
    @Published private var diagnosticsModels: [UUID: RemoteSessionDiagnosticsModel] = [:]

    @discardableResult
    func openRemoteSession(_ draft: RDPConnectionDraft) -> UUID {
        let id = UUID()
        let preferredScreen = NSApp.keyWindow?.screen ?? NSScreen.main
        let controller = RDPRemoteSessionWindowController(
            sessionID: id,
            draft: draft,
            launchStore: self,
            preferredScreen: preferredScreen
        )
        controller.onClose = { [weak self] sessionID in
            self?.sessionWindowControllers.removeValue(forKey: sessionID)
        }
        sessionWindowControllers[id] = controller
        controller.showWindow(nil)
        return id
    }

    func registerDiagnostics(_ model: RemoteSessionDiagnosticsModel, for id: UUID) {
        diagnosticsModels[id] = model
    }

    func diagnosticsModel(for id: UUID) -> RemoteSessionDiagnosticsModel? {
        diagnosticsModels[id]
    }

    func openDiagnostics(for id: UUID) {
        if let controller = diagnosticsWindowControllers[id] {
            controller.showWindow(nil)
            return
        }

        guard let model = diagnosticsModels[id] else {
            return
        }

        let controller = RDPRemoteSessionDiagnosticsWindowController(
            sessionID: id,
            title: model.snapshot.title,
            model: model
        )
        controller.onClose = { [weak self] sessionID in
            self?.diagnosticsWindowControllers.removeValue(forKey: sessionID)
        }
        diagnosticsWindowControllers[id] = controller
        controller.showWindow(nil)
    }

    func unregisterDiagnostics(for id: UUID) {
        diagnosticsModels.removeValue(forKey: id)
        diagnosticsWindowControllers.removeValue(forKey: id)?.close()
    }
}
