import AppKit
import Foundation
import RDPKit

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
    var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile
    var clipboardSharingEnabled: Bool
    var audioPlaybackEnabled: Bool
    var rememberPassword: Bool
    /// Keychain's answer for the account, when the form that made the draft had it: the session
    /// window then takes it rather than asking Keychain again.
    var passwordAnswer: RememberedPasswordAnswer?

    var displayName: String {
        RDPConnectionIdentity(host: host, port: port, username: username, domain: domain).displayName
    }
}

extension RDPConnectionDraft {
    /// A draft to connect with `profile`, carrying `choice`: the password and Remember choice of
    /// a form that shows `profile`'s account, or no password and the profile's own choice. The
    /// session window keeps the two, so the Remember choice must be the one made with that
    /// password: one the form ticked as Keychain filled the password in, not the profile's.
    init(profile: ConnectionProfile, choice: RememberedPasswordChoice, answer: RememberedPasswordAnswer?) throws {
        // Without Keychain's answer, the session window looks up a remembered password the form
        // does not have, and checks the credentials once it has it.
        let windowLooksUpPassword = answer == nil && choice.password.isEmpty && choice.rememberPassword
            && KeychainCredentialKey(identity: profile.identity) != nil
        if !windowLooksUpPassword {
            _ = try RDPCredentials.validated(
                username: profile.username,
                domain: profile.domain,
                password: choice.password
            )
        }

        self.init(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            domain: profile.domain,
            password: choice.password,
            desktopWidth: profile.desktopWidth,
            desktopHeight: profile.desktopHeight,
            hideCertificateWarnings: profile.hideCertificateWarnings,
            timeoutSeconds: profile.timeoutSeconds,
            graphicsCapabilityProfile: profile.graphicsCapabilityProfile,
            clipboardSharingEnabled: profile.clipboardSharingEnabled,
            audioPlaybackEnabled: profile.audioPlaybackEnabled,
            rememberPassword: choice.rememberPassword,
            passwordAnswer: answer
        )
    }
}

extension RememberedPasswordChoice {
    /// The choice to connect with saved `profile` from a form that has this one and shows
    /// `formKey`'s account. While that is another account, the form's password is not the
    /// profile's: there is none, with the profile's own Remember choice.
    func connecting(_ profile: ConnectionProfile, fromFormShowing formKey: KeychainCredentialKey?) -> Self {
        guard formKey != KeychainCredentialKey(identity: profile.identity) else {
            return self
        }
        return RememberedPasswordChoice(password: "", rememberPassword: profile.rememberPassword)
    }
}

@MainActor
final class RDPConnectionLaunchStore: ObservableObject {
    let sessionCommands = RDPSessionCommandCenter()
    private var sessionWindowControllers: [UUID: RDPRemoteSessionWindowController] = [:]
    private var diagnosticsWindowControllers: [UUID: RDPRemoteSessionDiagnosticsWindowController] = [:]
    private var diagnosticsModels: [UUID: RemoteSessionDiagnosticsModel] = [:]

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
