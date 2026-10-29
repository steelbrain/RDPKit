import RDPKit
import SwiftUI

struct ConnectionManagerView: View {
    private let profileStore = ConnectionProfileStore()
    private let credentialStore = KeychainCredentialStore()

    @EnvironmentObject private var launchStore: RDPConnectionLaunchStore

    @State private var profiles: [ConnectionProfile] = []
    @State private var selectedProfileID: UUID?
    @State private var profileMessage: String?
    @State private var savedProfilesWarning: String?
    @State private var host = ""
    @State private var port = "3389"
    @State private var desktopWidth = "1920"
    @State private var desktopHeight = "1080"
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var rememberPassword = false
    /// Keychain's answer for the form's account, once its lookup has answered.
    @State private var passwordAnswer: RememberedPasswordAnswer?
    @State private var keychainMessage: String?
    @State private var passwordLookup = RememberedPasswordLookup()
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
                    Toggle(UntrustedCertificatesOption.title, isOn: $hideCertificateWarnings)
                        .help(UntrustedCertificatesOption.help)
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

                if let savedProfilesWarning {
                    InlineNotice(
                        title: "Saved Connections",
                        message: savedProfilesWarning,
                        systemImage: "exclamationmark.triangle.fill"
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
            loadProfiles()
            loadRememberedPasswordIfAvailable(after: .zero)
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
        passwordAnswer = nil
        passwordLookup.cancel()
        keychainMessage = nil
        hideCertificateWarnings = false
        timeoutSeconds = 10
        graphicsCapabilityProfile = .automatic
        clipboardSharingEnabled = true
        audioPlaybackEnabled = false
    }

    /// Connects with the form. A connection reads Keychain once: it waits for the form's lookup
    /// on its way, and the session window takes the form's answer rather than asking again.
    private func connect() {
        if let credentialKey, passwordLookup.join(credentialKey, answered: { _ in connect() }) {
            return
        }
        do {
            let profile = try makeConnectionProfile()
            let draft = try makeConnectionDraft(from: profile, password: password, answer: answer(for: profile))
            openSession(draft)
        } catch {
            formError = String(describing: error)
        }
    }

    /// Connects with a saved profile, shown in the form, as `connect()` does. While the form
    /// shows another account, its password is not the profile's, and the session window looks
    /// the profile's up itself.
    private func connect(_ profile: ConnectionProfile) {
        if selectedProfileID != profile.id {
            selectedProfileID = profile.id
            applySelectedProfile(id: profile.id)
        }
        let key = KeychainCredentialKey(identity: profile.identity)
        let formShowsAccount = key == credentialKey
        if formShowsAccount, let key, passwordLookup.join(key, answered: { _ in connect(profile) }) {
            return
        }
        do {
            let draft = try makeConnectionDraft(
                from: profile,
                password: formShowsAccount ? password : "",
                answer: answer(for: profile)
            )
            openSession(draft)
        } catch {
            formError = String(describing: error)
        }
    }

    /// The form's Keychain answer, when it is for `profile`'s account.
    private func answer(for profile: ConnectionProfile) -> RememberedPasswordAnswer? {
        guard let passwordAnswer, passwordAnswer.key == KeychainCredentialKey(identity: profile.identity) else {
            return nil
        }
        return passwordAnswer
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
            applyProfileList(try profileStore.save(profile))
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
            applyProfileList(try profileStore.delete(id: profile.id))
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
        loadRememberedPasswordIfAvailable(after: .zero)
    }

    private func loadProfiles() {
        do {
            applyProfileList(try profileStore.profiles())
        } catch {
            savedProfilesWarning = String(describing: error)
        }
    }

    private func applyProfileList(_ list: ConnectionProfileList) {
        profiles = list.profiles
        switch list.unreadableCount {
        case 0:
            savedProfilesWarning = nil
        case 1:
            savedProfilesWarning = "1 saved connection could not be read. It stays saved as it is."
        default:
            savedProfilesWarning = "\(list.unreadableCount) saved connections could not be read. They stay saved as they are."
        }
    }

    private func makeConnectionDraft(
        from profile: ConnectionProfile,
        password: String,
        answer: RememberedPasswordAnswer?
    ) throws -> RDPConnectionDraft {
        // Without Keychain's answer, the session window looks up a remembered password the form
        // does not have, and checks the credentials once it has it.
        let windowLooksUpPassword = answer == nil && password.isEmpty && profile.rememberPassword
            && KeychainCredentialKey(identity: profile.identity) != nil
        if !windowLooksUpPassword {
            _ = try RDPCredentials.validated(
                username: profile.username,
                domain: profile.domain,
                password: password
            )
        }

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
            rememberPassword: profile.rememberPassword,
            passwordAnswer: answer
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

    private var credentialKey: KeychainCredentialKey? {
        KeychainCredentialKey(host: host, portText: port, username: username, domain: domain)
    }

    /// Looks up the password saved for the form's account, `after` a pause in typing.
    private func loadRememberedPasswordIfAvailable(after delay: Duration = RememberedPasswordLookup.typingDelay) {
        keychainMessage = nil
        passwordAnswer = nil
        guard let key = credentialKey else {
            passwordLookup.cancel()
            return
        }
        passwordLookup.lookUp(key, after: delay) { result in
            applyRememberedPassword(result, for: key)
        }
    }

    private func applyRememberedPassword(_ result: Result<String?, Error>, for key: KeychainCredentialKey) {
        // Dropped when the fields changed since the lookup began, as a newer lookup follows.
        guard key == credentialKey else {
            return
        }
        passwordAnswer = RememberedPasswordAnswer(key: key, result: result)
        switch result {
        case let .success(savedPassword?):
            rememberPassword = true
            password = savedPassword
            keychainMessage = "Password loaded from Keychain."
        case .success(nil):
            if password.isEmpty {
                rememberPassword = false
            }
        case let .failure(error):
            keychainMessage = String(describing: error)
        }
    }

    private var hasRememberedPassword: Bool {
        passwordAnswer?.savedPassword != nil
    }

    private func credentialPersistenceRequest(
        for profile: ConnectionProfile
    ) throws -> CredentialPersistenceRequest? {
        guard let key = KeychainCredentialKey(identity: profile.identity) else {
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

    /// Deletes `profile`'s saved password, and returns whether it had one. Deleting tells, so
    /// Keychain is not read first.
    private func deleteStoredCredentials(for profile: ConnectionProfile) throws -> Bool {
        guard let key = KeychainCredentialKey(identity: profile.identity) else {
            return false
        }
        return try credentialStore.deletePassword(for: key)
    }

    private func applyCredentialPersistenceResult(
        _ result: Result<CredentialPersistenceResult, Error>?
    ) {
        switch result {
        case .success(.saved):
            passwordAnswer = credentialKey.map { RememberedPasswordAnswer(key: $0, result: .success(password)) }
            rememberPassword = true
            keychainMessage = "Password saved to Keychain."
        case .success(.deleted):
            passwordAnswer = credentialKey.map { RememberedPasswordAnswer(key: $0, result: .success(nil)) }
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
