import RDPKit
import SwiftUI

struct ConnectionManagerView: View {
    private let profileStore = ConnectionProfileStore()
    private let credentialStore = KeychainCredentialStore()

    @EnvironmentObject private var launchStore: RDPConnectionLaunchStore

    @State private var profiles: [ConnectionProfile] = []
    @State private var selectedProfileID: UUID?
    @State private var profileMessage: String?
    @State private var host = ""
    @State private var port = "3389"
    @State private var desktopWidth = "1920"
    @State private var desktopHeight = "1080"
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var hasRememberedPassword = false
    @State private var keychainMessage: String?
    @State private var hideCertificateWarnings = false
    @State private var timeoutSeconds = 10.0
    @State private var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    @State private var clipboardSharingEnabled = true
    @State private var audioPlaybackEnabled = false
    @State private var formError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProfileID) {
                Button(action: newConnection) {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Section("Saved") {
                    ForEach(profiles) { profile in
                        Label(profile.displayName, systemImage: "display")
                            .tag(Optional(profile.id))
                            .contextMenu {
                                Button(action: { connect(profile) }) {
                                    Label("Connect", systemImage: "play.fill")
                                }

                                Button(role: .destructive, action: { deleteProfile(profile) }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .onTapGesture(count: 2) {
                                connect(profile)
                            }
                    }
                }
            }
            .navigationTitle("Connections")
            .frame(minWidth: 240)
        } detail: {
            Form {
                Section("Connection") {
                    TextField("Host", text: $host)
                        .textContentType(.URL)

                    TextField("Port", text: $port)
                        .frame(maxWidth: 120)
                }

                Section("Display") {
                    HStack {
                        TextField("Width", text: $desktopWidth)
                            .frame(maxWidth: 90)
                        Text("x")
                            .foregroundStyle(.secondary)
                        TextField("Height", text: $desktopHeight)
                            .frame(maxWidth: 90)
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                    TextField("Domain", text: $domain)
                    SecureField("Password", text: $password)
                    Toggle("Remember password in Keychain", isOn: $rememberPassword)
                        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let keychainMessage {
                        Text(verbatim: keychainMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Options") {
                    Picker("Graphics Profile", selection: $graphicsCapabilityProfile) {
                        ForEach(RDPGraphicsCapabilityProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Share Clipboard", isOn: $clipboardSharingEnabled)
                    Toggle("Request Remote Audio", isOn: $audioPlaybackEnabled)
                    Toggle("Hide certificate warnings", isOn: $hideCertificateWarnings)
                    Stepper(
                        "Timeout: \(Int(timeoutSeconds))s",
                        value: $timeoutSeconds,
                        in: 3 ... 60,
                        step: 1
                    )
                }

                if let formError {
                    InlineNotice(
                        title: "Input",
                        message: formError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if let profileMessage {
                    InlineNotice(
                        title: "Profile",
                        message: profileMessage,
                        systemImage: "checkmark.circle.fill"
                    )
                }

                HStack {
                    Button(action: connect) {
                        Label("Connect", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: saveCurrentProfile) {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive, action: deleteSelectedProfile) {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("Delete selected connection")
                    .disabled(selectedProfileID == nil)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(detailTitle)
            .frame(maxWidth: 620)
        }
        .onAppear {
            profiles = profileStore.profiles()
            loadRememberedPasswordIfAvailable()
        }
        .onChange(of: selectedProfileID) { _, newValue in
            applySelectedProfile(id: newValue)
        }
        .onChange(of: credentialLookupSignature) { _, _ in
            loadRememberedPasswordIfAvailable()
        }
    }

    private var detailTitle: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Connection" : host
    }

    private func newConnection() {
        selectedProfileID = nil
        profileMessage = nil
        formError = nil
        host = ""
        port = "3389"
        desktopWidth = "1920"
        desktopHeight = "1080"
        username = ""
        domain = ""
        password = ""
        rememberPassword = false
        hasRememberedPassword = false
        keychainMessage = nil
        hideCertificateWarnings = false
        timeoutSeconds = 10
        graphicsCapabilityProfile = .automatic
        clipboardSharingEnabled = true
        audioPlaybackEnabled = false
    }

    private func connect() {
        do {
            let draft = try makeConnectionDraft()
            openSession(draft)
        } catch {
            formError = String(describing: error)
        }
    }

    private func connect(_ profile: ConnectionProfile) {
        do {
            let wasSelected = selectedProfileID == profile.id
            if !wasSelected {
                selectedProfileID = profile.id
                applySelectedProfile(id: profile.id)
            }
            let connectionPassword = wasSelected ? password : try profilePassword(for: profile)
            let draft = try makeConnectionDraft(from: profile, password: connectionPassword)
            openSession(draft)
        } catch {
            formError = String(describing: error)
        }
    }

    private func openSession(_ draft: RDPConnectionDraft) {
        launchStore.openRemoteSession(draft)
        profileMessage = "Opening \(draft.displayName)."
        formError = nil
    }

    private func saveCurrentProfile() {
        do {
            let profile = try makeConnectionProfile()
            let persistenceResult = try persistCredentialChangeIfNeeded(
                credentialPersistenceRequest(for: profile)
            )
            profiles = try profileStore.save(profile)
            selectedProfileID = profile.id
            applyCredentialPersistenceResult(persistenceResult)
            profileMessage = "Profile saved."
            formError = nil
        } catch {
            formError = String(describing: error)
        }
    }

    private func deleteSelectedProfile() {
        guard let selectedProfileID,
              let selectedProfile = profiles.first(where: { $0.id == selectedProfileID })
        else {
            return
        }
        deleteProfile(selectedProfile)
    }

    private func deleteProfile(_ profile: ConnectionProfile) {
        do {
            let wasSelected = selectedProfileID == profile.id
            let deletedPassword = try deleteStoredCredentials(for: profile)
            profiles = try profileStore.delete(id: profile.id)
            if wasSelected {
                newConnection()
            }
            profileMessage = deletedPassword ? "Profile and saved password deleted." : "Profile deleted."
        } catch {
            formError = String(describing: error)
        }
    }

    private func applySelectedProfile(id: UUID?) {
        guard let id,
              let profile = profiles.first(where: { $0.id == id })
        else {
            return
        }

        host = profile.host
        port = String(profile.port)
        desktopWidth = String(profile.desktopWidth)
        desktopHeight = String(profile.desktopHeight)
        username = profile.username
        domain = profile.domain
        password = ""
        rememberPassword = profile.rememberPassword
        hideCertificateWarnings = profile.hideCertificateWarnings
        timeoutSeconds = Double(profile.timeoutSeconds)
        graphicsCapabilityProfile = profile.graphicsCapabilityProfile
        clipboardSharingEnabled = profile.clipboardSharingEnabled
        audioPlaybackEnabled = profile.audioPlaybackEnabled
        profileMessage = nil
        formError = nil
        loadRememberedPasswordIfAvailable()
    }

    private func makeConnectionDraft() throws -> RDPConnectionDraft {
        let profile = try makeConnectionProfile()
        let trimmedPassword = password
        return try makeConnectionDraft(from: profile, password: trimmedPassword)
    }

    private func makeConnectionDraft(
        from profile: ConnectionProfile,
        password: String
    ) throws -> RDPConnectionDraft {
        _ = try RDPCredentials.validated(
            username: profile.username,
            domain: profile.domain,
            password: password
        )

        return RDPConnectionDraft(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            domain: profile.domain,
            password: password,
            desktopWidth: profile.desktopWidth,
            desktopHeight: profile.desktopHeight,
            hideCertificateWarnings: profile.hideCertificateWarnings,
            timeoutSeconds: profile.timeoutSeconds,
            graphicsCapabilityProfile: profile.graphicsCapabilityProfile,
            clipboardSharingEnabled: profile.clipboardSharingEnabled,
            audioPlaybackEnabled: profile.audioPlaybackEnabled,
            rememberPassword: profile.rememberPassword
        )
    }

    private func makeConnectionProfile() throws -> ConnectionProfile {
        let target = try RDPConnectionTarget(host: host, portText: port)
        let desktopSize = try RDPDesktopSize(widthText: desktopWidth, heightText: desktopHeight)

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateIdentity = RDPConnectionIdentity(
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain
        )
        let nextID: UUID
        if let selectedProfileID {
            nextID = selectedProfileID
        } else if let matchingProfile = profiles.first(where: { existing in
            existing.identity.hasSameConnectionIdentity(as: candidateIdentity)
        }) {
            nextID = matchingProfile.id
        } else {
            nextID = UUID()
        }

        return ConnectionProfile(
            id: nextID,
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain,
            desktopWidth: desktopSize.width,
            desktopHeight: desktopSize.height,
            hideCertificateWarnings: hideCertificateWarnings,
            timeoutSeconds: Int(timeoutSeconds),
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            clipboardSharingEnabled: clipboardSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            rememberPassword: rememberPassword,
            updatedAt: Date()
        )
    }

    private var credentialLookupSignature: String {
        [
            host.trimmingCharacters(in: .whitespacesAndNewlines),
            port.trimmingCharacters(in: .whitespacesAndNewlines),
            username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "\u{1f}")
    }

    private func loadRememberedPasswordIfAvailable() {
        guard let key = currentCredentialKey() else {
            keychainMessage = nil
            hasRememberedPassword = false
            return
        }

        do {
            guard let savedPassword = try credentialStore.password(for: key) else {
                hasRememberedPassword = false
                if password.isEmpty {
                    rememberPassword = false
                }
                keychainMessage = nil
                return
            }

            hasRememberedPassword = true
            rememberPassword = true
            password = savedPassword
            keychainMessage = "Password loaded from Keychain."
        } catch {
            hasRememberedPassword = false
            keychainMessage = String(describing: error)
        }
    }

    private func profilePassword(for profile: ConnectionProfile) throws -> String {
        guard profile.rememberPassword,
              let key = makeCredentialKey(
                  host: profile.host,
                  port: profile.port,
                  username: profile.username,
                  domain: profile.domain
              )
        else {
            return ""
        }
        return try credentialStore.password(for: key) ?? ""
    }

    private func currentCredentialKey() -> KeychainCredentialKey? {
        guard let target = try? RDPConnectionTarget(host: host, portText: port) else {
            return nil
        }
        return makeCredentialKey(
            host: target.host,
            port: target.port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func makeCredentialKey(
        host: String,
        port: UInt16,
        username: String,
        domain: String
    ) -> KeychainCredentialKey? {
        KeychainCredentialKey(identity: RDPConnectionIdentity(
            host: host,
            port: port,
            username: username,
            domain: domain
        ))
    }

    private func credentialPersistenceRequest(
        for profile: ConnectionProfile
    ) throws -> CredentialPersistenceRequest? {
        guard let key = makeCredentialKey(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            domain: profile.domain
        ) else {
            return nil
        }

        if profile.rememberPassword {
            guard password.isEmpty == false else {
                throw ConnectionLaunchValidationError.missingRememberedPassword
            }
            return .save(key: key, password: password)
        }

        if hasRememberedPassword {
            return .delete(key: key)
        }
        return nil
    }

    private func persistCredentialChangeIfNeeded(
        _ request: CredentialPersistenceRequest?
    ) throws -> Result<CredentialPersistenceResult, Error>? {
        let result = persistCredentialsIfNeeded(request, store: credentialStore)
        if case let .failure(error) = result {
            throw error
        }
        return result
    }

    @discardableResult
    private func deleteStoredCredentials(for profile: ConnectionProfile) throws -> Bool {
        guard let key = makeCredentialKey(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            domain: profile.domain
        ) else {
            return false
        }
        let hadStoredPassword = try credentialStore.password(for: key) != nil
        guard hadStoredPassword else {
            return false
        }
        let result = try persistCredentialChangeIfNeeded(.delete(key: key))
        return result != nil
    }

    private func applyCredentialPersistenceResult(
        _ result: Result<CredentialPersistenceResult, Error>?
    ) {
        switch result {
        case .success(.saved):
            hasRememberedPassword = true
            rememberPassword = true
            keychainMessage = "Password saved to Keychain."
        case .success(.deleted):
            hasRememberedPassword = false
            keychainMessage = "Saved password removed from Keychain."
        case let .failure(error):
            keychainMessage = String(describing: error)
        case nil:
            break
        }
    }
}

private enum ConnectionLaunchValidationError: Error, CustomStringConvertible {
    case missingRememberedPassword

    var description: String {
        switch self {
        case .missingRememberedPassword:
            "Password is required when remembering credentials."
        }
    }
}
