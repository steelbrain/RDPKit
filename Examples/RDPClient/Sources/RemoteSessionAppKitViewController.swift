import AppKit
import QuartzCore
import RDPKit

@MainActor
final class RDPRemoteSessionViewController: NSViewController, NSTextFieldDelegate {
    private let credentialStore = KeychainCredentialStore()
    private let clientLicenseStore = ClientLicenseStore()
    private let trustedCertificateStore = TrustedCertificateStore()
    private let sessionID: UUID
    private let sessionDisplayName: String
    private weak var launchStore: RDPConnectionLaunchStore?

    private var host = ""
    private var port = "3389"
    private var desktopWidth = "1920"
    private var desktopHeight = "1080"
    private var username = ""
    private var domain = ""
    private var password = ""
    private var rememberPassword = false
    private var hasRememberedPassword = false
    private var keychainMessage: String?
    private var hideCertificateWarnings = false
    private var timeoutSeconds = 10.0
    private var isConnecting = false
    private var activeConnectionID: UUID?
    private var activeCancellation: RDPConnectionCancellation?
    private var sessionEndReason: RDPSessionEndReason?
    private var inputSession: RDPInputSession?
    /// The keyboard layout the current session announced.
    private var keyboardLayout = RDPKeyboardLayout.unitedStates
    private var displayControlSession: RDPDisplayControlSession?
    private var displayControlMessage: String?
    private var autoApplyViewerSize = true
    private var pendingDisplayResizeTask: Task<Void, Never>?
    private var displayResize = RDPDisplayResizeDebounce()
    private var viewerPointSize: CGSize = .zero
    private var viewerPixelSize: RDPViewerPixelSize?
    private let clipboard: RDPRemoteSessionClipboard
    private var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    private var audioPlaybackEnabled = false
    private var audioMessage: String?
    private var remoteAudioPlayer = RDPAudioPlayer()
    private var report: RDPConnectionReport?
    private var serverCertificateInfo: RDPServerCertificateInfo?
    private var previewFrame: RDPFrameMetadata?
    private var previewFrameCount = 0
    private var viewerMetricsSummary: String?
    private var previewDecodeError: String?
    private var hasPresentedFrame = false
    private var framePresentationBuffer = RDPFramePresentationBuffer()
    private var framePacing = RDPFramePacingState()
    private var remoteDesktopRenderer = RDPRemoteDesktopRenderer()
    private var renderMetricsStore = RDPRenderMetricsStore()
    private let diagnosticsModel = RemoteSessionDiagnosticsModel()
    private var certificateTrustedByApp = false
    private var certificateRefusal: CertificateRefusal?
    private var certificateTrustMessage: String?
    private var formError: String?
    private var controlsVisible = false
    private var shouldAutoConnect = true
    private var diagnosticsTask: Task<Void, Never>?
    private var clipboardPollingTask: Task<Void, Never>?
    private var didClose = false

    private let rootStack = NSStackView()
    private let sidebarScrollView = NSScrollView()
    private let sidebarContentView = NSView()
    private let sidebarStack = NSStackView()
    private let detailView = RDPRemoteSessionAppKitDetailView()
    private let frameClockView = RDPFramePresentationClockNSView()
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var detailMinimumWidthConstraint: NSLayoutConstraint?

    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let desktopWidthField = NSTextField()
    private let desktopHeightField = NSTextField()
    private let usernameField = NSTextField()
    private let domainField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let rememberPasswordButton = NSButton(checkboxWithTitle: "Remember password in Keychain", target: nil, action: nil)
    private let autoApplyViewerSizeButton = NSButton(checkboxWithTitle: "Follow View Size", target: nil, action: nil)
    private let graphicsProfilePopup = NSPopUpButton()
    private let clipboardSharingButton = NSButton(checkboxWithTitle: "Share Clipboard", target: nil, action: nil)
    private let audioPlaybackButton = NSButton(checkboxWithTitle: "Request Remote Audio", target: nil, action: nil)
    private let hideCertificateWarningsButton = NSButton(checkboxWithTitle: "Hide certificate warnings", target: nil, action: nil)
    private let timeoutStepper = NSStepper()
    private let timeoutLabel = NSTextField(labelWithString: "")
    private let keychainLabel = NSTextField(labelWithString: "")
    private let viewerSizeLabel = NSTextField(labelWithString: "")
    private let displayControlLabel = NSTextField(labelWithString: "")
    private let clipboardLabel = NSTextField(labelWithString: "")
    private let audioLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let applyDisplayButton = NSButton(title: "Apply", target: nil, action: nil)
    private let useViewerSizeButton = NSButton(title: "Use View", target: nil, action: nil)
    private let applyViewerSizeButton = NSButton(title: "Apply View", target: nil, action: nil)
    private let temporaryClipboardButton = NSButton(title: "Share for 30s", target: nil, action: nil)
    private let syncClipboardButton = NSButton(title: "Sync Now", target: nil, action: nil)

    init(
        sessionID: UUID,
        draft: RDPConnectionDraft,
        launchStore: RDPConnectionLaunchStore
    ) {
        self.sessionID = sessionID
        sessionDisplayName = draft.displayName
        self.launchStore = launchStore
        host = draft.host
        port = String(draft.port)
        desktopWidth = String(draft.desktopWidth)
        desktopHeight = String(draft.desktopHeight)
        username = draft.username
        domain = draft.domain
        password = draft.password
        rememberPassword = draft.rememberPassword
        hideCertificateWarnings = draft.hideCertificateWarnings
        timeoutSeconds = Double(draft.timeoutSeconds)
        graphicsCapabilityProfile = draft.graphicsCapabilityProfile
        clipboard = RDPRemoteSessionClipboard(isSharingEnabled: draft.clipboardSharingEnabled)
        audioPlaybackEnabled = draft.audioPlaybackEnabled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        configureLayout()
        configureControls()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        launchStore?.registerDiagnostics(diagnosticsModel, for: sessionID)
        startDiagnosticsLoop()
        startClipboardPollingLoop()
        loadRememberedPasswordIfAvailable(keepingEnteredPassword: true)
        render()
        if shouldAutoConnect {
            shouldAutoConnect = false
            beginConnection()
        }
    }

    func closeSession() {
        guard didClose == false else {
            return
        }
        didClose = true
        diagnosticsTask?.cancel()
        clipboardPollingTask?.cancel()
        launchStore?.unregisterDiagnostics(for: sessionID)
        cancelConnection(shouldRecordCancellation: false)
        withdrawSessionCommands()
    }

    func startSession() {
        syncStateFromFields()
        beginConnection()
    }

    /// Publishes the Session menu state while this session's window is key.
    func publishSessionCommands() {
        guard didClose == false, view.window?.isKeyWindow == true else {
            return
        }
        launchStore?.sessionCommands.publish(
            RDPSessionCommandState(
                startTitle: connectButtonTitle,
                canStart: canStartConnection,
                canCancel: isConnecting,
                controlsVisible: controlsVisible,
                canSyncClipboard: clipboard.canSync,
                canStartTemporaryClipboardSharing: clipboard.canStartTemporarySharing
            ),
            from: self
        )
    }

    func withdrawSessionCommands() {
        launchStore?.sessionCommands.withdraw(self)
    }

    deinit {
        MainActor.assumeIsolated {
            closeSession()
        }
    }

    func controlTextDidChange(_: Notification) {
        let previousCredentialLookupSignature = credentialLookupSignature
        syncStateFromFields()
        if previousCredentialLookupSignature != credentialLookupSignature {
            loadRememberedPasswordIfAvailable()
        }
        render()
    }

    private func configureLayout() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.distribution = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        sidebarScrollView.setContentHuggingPriority(.required, for: .horizontal)
        sidebarScrollView.setContentCompressionResistancePriority(.required, for: .horizontal)
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.drawsBackground = true
        sidebarScrollView.backgroundColor = .controlBackgroundColor
        sidebarScrollView.borderType = .noBorder
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.documentView = sidebarContentView

        sidebarContentView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContentView.addSubview(sidebarStack)
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 14
        sidebarStack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailView.onToggleControls = { [weak self] in self?.toggleSessionControls() }
        detailView.onConnect = { [weak self] in self?.startSession() }
        detailView.onCancel = { [weak self] in self?.cancelConnection() }
        detailView.onOpenDiagnostics = { [weak self] in self?.openDiagnosticsWindow() }
        detailView.onTrustCertificate = { [weak self] in self?.trustCurrentCertificate() }
        detailView.onForgetCertificate = { [weak self] in self?.forgetCurrentCertificate() }
        detailView.onSurfaceSizeChange = { [weak self] size in self?.updateViewerSurfaceSize(size) }
        remoteDesktopRenderer.attach(detailView.displayView)

        frameClockView.translatesAutoresizingMaskIntoConstraints = false
        frameClockView.isHidden = true

        rootStack.addArrangedSubview(sidebarScrollView)
        rootStack.addArrangedSubview(detailView)
        view.addSubview(frameClockView)

        let sidebarWidthConstraint = sidebarScrollView.widthAnchor.constraint(equalToConstant: 312)
        self.sidebarWidthConstraint = sidebarWidthConstraint
        let detailMinimumWidthConstraint = detailView.widthAnchor.constraint(greaterThanOrEqualTo: rootStack.widthAnchor)
        self.detailMinimumWidthConstraint = detailMinimumWidthConstraint

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            sidebarWidthConstraint,
            detailMinimumWidthConstraint,
            sidebarScrollView.heightAnchor.constraint(equalTo: rootStack.heightAnchor),
            detailView.heightAnchor.constraint(equalTo: rootStack.heightAnchor),
            sidebarContentView.widthAnchor.constraint(equalTo: sidebarScrollView.contentView.widthAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarContentView.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarContentView.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebarContentView.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarContentView.bottomAnchor),

            frameClockView.widthAnchor.constraint(equalToConstant: 1),
            frameClockView.heightAnchor.constraint(equalToConstant: 1),
            frameClockView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            frameClockView.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    private func configureControls() {
        for field in [hostField, portField, desktopWidthField, desktopHeightField, usernameField, domainField, passwordField] {
            field.delegate = self
            field.target = self
            field.action = #selector(textFieldAction(_:))
            field.lineBreakMode = .byTruncatingTail
        }
        portField.formatter = integerFormatter()
        desktopWidthField.formatter = integerFormatter()
        desktopHeightField.formatter = integerFormatter()

        configureCheckbox(autoApplyViewerSizeButton, action: #selector(toggleAutoApplyViewerSize(_:)))
        configureCheckbox(rememberPasswordButton, action: #selector(toggleRememberPassword(_:)))
        configureCheckbox(clipboardSharingButton, action: #selector(toggleClipboardSharing(_:)))
        configureCheckbox(audioPlaybackButton, action: #selector(toggleAudioPlayback(_:)))
        configureCheckbox(hideCertificateWarningsButton, action: #selector(toggleHideCertificateWarnings(_:)))

        graphicsProfilePopup.removeAllItems()
        for profile in RDPGraphicsCapabilityProfile.allCases {
            graphicsProfilePopup.addItem(withTitle: profile.displayName)
            graphicsProfilePopup.lastItem?.representedObject = profile.rawValue
        }
        graphicsProfilePopup.target = self
        graphicsProfilePopup.action = #selector(graphicsProfileChanged(_:))

        timeoutStepper.minValue = 3
        timeoutStepper.maxValue = 60
        timeoutStepper.increment = 1
        timeoutStepper.target = self
        timeoutStepper.action = #selector(timeoutChanged(_:))

        connectButton.target = self
        connectButton.action = #selector(connectPressed(_:))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        cancelButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")
        cancelButton.imagePosition = .imageOnly
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        applyDisplayButton.target = self
        applyDisplayButton.action = #selector(applyDisplayPressed(_:))
        useViewerSizeButton.target = self
        useViewerSizeButton.action = #selector(useViewerSizePressed(_:))
        applyViewerSizeButton.target = self
        applyViewerSizeButton.action = #selector(applyViewerSizePressed(_:))
        temporaryClipboardButton.target = self
        temporaryClipboardButton.action = #selector(temporaryClipboardPressed(_:))
        syncClipboardButton.target = self
        syncClipboardButton.action = #selector(syncClipboardPressed(_:))

        for label in [keychainLabel, viewerSizeLabel, displayControlLabel, clipboardLabel, audioLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }

        sidebarStack.addArrangedSubview(section("Connection", [
            labeledField("Host", hostField),
            labeledField("Port", portField, fieldWidth: 96),
        ]))
        sidebarStack.addArrangedSubview(section("Display", [
            autoApplyViewerSizeButton,
            sizeRow(),
            viewerSizeActionsRow(),
            viewerSizeLabel,
            labeledControl("Graphics Profile", graphicsProfilePopup),
            displayControlLabel,
        ]))
        sidebarStack.addArrangedSubview(section("Credentials", [
            labeledField("Username", usernameField),
            labeledField("Domain", domainField),
            labeledField("Password", passwordField),
            rememberPasswordButton,
            keychainLabel,
        ]))
        sidebarStack.addArrangedSubview(section("Clipboard", [
            clipboardSharingButton,
            temporaryClipboardButton,
            syncClipboardButton,
            clipboardLabel,
        ]))
        sidebarStack.addArrangedSubview(section("Audio", [
            audioPlaybackButton,
            audioLabel,
        ]))
        sidebarStack.addArrangedSubview(section("Security", [
            hideCertificateWarningsButton,
            timeoutRow(),
        ]))
        sidebarStack.addArrangedSubview(actionRow())
    }

    private func render() {
        syncFieldsFromState()
        renderSidebar()
        renderDetail()
        updateFrameClock()
        syncDiagnosticsSnapshot()
        publishSessionCommands()
    }

    fileprivate func acceptsConnectionEvent(id: UUID) -> Bool {
        activeConnectionID == id
    }

    private func renderSidebar() {
        sidebarScrollView.isHidden = !controlsVisible
        sidebarWidthConstraint?.constant = controlsVisible ? 312 : 0
        detailMinimumWidthConstraint?.constant = controlsVisible ? -312 : 0
        autoApplyViewerSizeButton.state = autoApplyViewerSize ? .on : .off
        rememberPasswordButton.state = rememberPassword ? .on : .off
        rememberPasswordButton.isEnabled = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        clipboardSharingButton.state = clipboard.isSharingEnabled ? .on : .off
        audioPlaybackButton.state = audioPlaybackEnabled ? .on : .off
        hideCertificateWarningsButton.state = hideCertificateWarnings ? .on : .off
        graphicsProfilePopup.selectItem(withTitle: graphicsCapabilityProfile.displayName)
        graphicsProfilePopup.isEnabled = !isConnecting

        timeoutStepper.doubleValue = timeoutSeconds
        timeoutLabel.stringValue = "Timeout: \(Int(timeoutSeconds))s"
        keychainLabel.stringValue = keychainMessage ?? ""
        keychainLabel.isHidden = keychainMessage == nil
        viewerSizeLabel.stringValue = viewerPixelSize?.label ?? ""
        viewerSizeLabel.isHidden = viewerPixelSize == nil
        displayControlLabel.stringValue = displayControlMessage ?? displayControlStatusText
        clipboardLabel.stringValue = clipboard.statusMessage
        audioLabel.stringValue = audioStatusMessage

        applyDisplayButton.isEnabled = isConnecting && displayControlSession != nil
        useViewerSizeButton.isEnabled = viewerPixelSize != nil
        applyViewerSizeButton.isEnabled = isConnecting && displayControlSession != nil && viewerPixelSize != nil
        temporaryClipboardButton.title = clipboard.temporarySharingButtonTitle
        temporaryClipboardButton.isEnabled = clipboard.canStartTemporarySharing
        syncClipboardButton.isEnabled = clipboard.canSync
        connectButton.title = connectButtonTitle
        connectButton.isEnabled = canStartConnection
        cancelButton.isHidden = !isConnecting
        cancelButton.isEnabled = isConnecting
    }

    private func renderDetail() {
        let frame = previewFrame ?? report?.rdpGraphicsFirstFrame.map(RDPFrameMetadata.init)
        let status = RDPRemoteSessionAppKitStatus(
            reportStatus: report?.status,
            sessionEndReason: sessionEndReason,
            hasPresentedFrame: hasPresentedFrame,
            isConnecting: isConnecting
        )
        let certificateNotice = certificateNoticeState()
        detailView.render(
            frame: frame,
            frameCount: previewFrameCount,
            hasPresentedFrame: hasPresentedFrame,
            status: status,
            decodeError: previewDecodeError,
            metricsSummary: viewerMetricsSummary,
            graphicsPathSummary: report.map { RDPGraphicsPathDescription.describe(report: $0) },
            inputSession: inputSession,
            keyboardLayout: keyboardLayout,
            isConnecting: isConnecting,
            formError: formError,
            sessionEndReason: sessionEndReason,
            certificateNotice: certificateNotice,
            controlsVisible: controlsVisible,
            connectTitle: connectButtonTitle,
            canConnect: canStartConnection,
            canCancel: isConnecting
        )
        remoteDesktopRenderer.attach(detailView.displayView)
    }

    private func certificateNoticeState() -> RDPAppKitNoticeState? {
        if certificateTrustedByApp {
            return RDPAppKitNoticeState(
                title: "Certificate",
                message: certificateTrustMessage ?? "Certificate trusted for this host.",
                systemImage: "checkmark.shield.fill",
                actionTitle: "Forget Certificate",
                action: .forgetCertificate
            )
        }
        switch certificateRefusal {
        case .changed:
            return RDPAppKitNoticeState(
                title: "Certificate Changed",
                message: "Trust the new certificate only if you know why the server's certificate changed.",
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                actionTitle: "Trust and Connect",
                action: .trustCertificate
            )
        case .untrusted:
            let fingerprint = serverCertificateInfo?.sha256.map { " SHA-256: \($0)" } ?? ""
            return RDPAppKitNoticeState(
                title: "Untrusted Certificate",
                message: "This Mac does not trust the server's certificate. Trust it only if you expect it, "
                    + "such as a server's self-signed certificate.\(fingerprint)",
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                actionTitle: "Trust and Connect",
                action: .trustCertificate
            )
        case nil:
            break
        }
        // Only a refused certificate is offered for trust. The session's other warnings are not
        // about the certificate; Stats for Nerds lists them.
        if let certificateTrustMessage {
            return RDPAppKitNoticeState(
                title: "Certificate",
                message: certificateTrustMessage,
                systemImage: "lock.fill",
                actionTitle: nil,
                action: nil
            )
        }
        return nil
    }

    private func updateFrameClock() {
        frameClockView.configure(
            isEnabled: framePresentationClockEnabled,
            onFrame: { [weak self] displayLink in
                self?.displayLinkFrameArrived(displayLink)
            },
            onTimingChange: { [weak self] nextState in
                self?.updateFramePacing(nextState)
            }
        )
    }

    private func startDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                self?.syncDiagnosticsSnapshot()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startClipboardPollingLoop() {
        clipboardPollingTask?.cancel()
        clipboardPollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard Task.isCancelled == false, let self else {
                    return
                }
                clipboard.poll()
                render()
            }
        }
    }

    func openDiagnosticsWindow() {
        syncDiagnosticsSnapshot()
        launchStore?.openDiagnostics(for: sessionID)
    }

    private func syncDiagnosticsSnapshot() {
        let nextSnapshot = RemoteSessionDiagnosticsSnapshot(
            title: sessionDisplayName,
            report: report,
            previewFrame: previewFrame,
            previewFrameCount: previewFrameCount,
            previewDecodeError: previewDecodeError,
            renderMetrics: renderMetricsStore.metrics,
            framePacing: framePacing,
            sessionEndReason: sessionEndReason,
            serverCertificateInfo: serverCertificateInfo,
            viewerPixelSize: viewerPixelSize,
            requestedDesktopSize: requestedDesktopSizeLabel,
            inputReady: inputSession != nil,
            displayControlReady: displayControlSession != nil,
            clipboardReady: clipboard.session != nil,
            clipboardSharingEnabled: clipboard.isSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            certificateTrustedByApp: certificateTrustedByApp,
            certificateTrustMessage: certificateTrustMessage,
            formError: formError,
            isConnecting: isConnecting
        )
        diagnosticsModel.updateSnapshot(nextSnapshot)
    }

    private func beginConnection() {
        activeCancellation?.cancel()
        detachSessionChannels()
        activeConnectionID = nil
        activeCancellation = nil
        sessionEndReason = nil
        isConnecting = false

        formError = nil
        report = nil
        serverCertificateInfo = nil
        previewFrame = nil
        previewFrameCount = 0
        viewerMetricsSummary = nil
        previewDecodeError = nil
        resetFramePresentationState()
        renderMetricsStore.reset()
        certificateTrustedByApp = false
        certificateRefusal = nil
        certificateTrustMessage = nil

        let target: RDPConnectionTarget
        let requestedDesktopSize: RDPDesktopSize
        do {
            target = try RDPConnectionTarget(host: host, portText: port)
            requestedDesktopSize = try RDPDesktopSize(widthText: desktopWidth, heightText: desktopHeight)
        } catch {
            formError = String(describing: error)
            render()
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = RDPConnectionIdentity(
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain
        )
        let credentialKey = KeychainCredentialKey(identity: identity)
        let clientLicenseKey = ClientLicenseStoreKey(identity: identity)
        let storedClientLicense: RDPStoredClientLicense?
        do {
            storedClientLicense = try clientLicenseStore.license(for: clientLicenseKey)
        } catch {
            storedClientLicense = nil
            keychainMessage = String(describing: error)
        }
        let credentials: RDPCredentials?
        do {
            credentials = try RDPCredentials.validated(
                username: trimmedUsername,
                domain: trimmedDomain,
                password: password
            )
        } catch {
            formError = String(describing: error)
            render()
            return
        }
        let credentialPersistenceRequest = credentialPersistenceRequest(
            key: credentialKey,
            password: password,
            hasCredentials: credentials != nil
        )

        keyboardLayout = MacRDPKeyboardLayout.current()
        let configuration = RDPConnectionConfiguration(
            target: target,
            credentials: credentials,
            timeoutSeconds: Int(timeoutSeconds),
            hideCertificateWarnings: hideCertificateWarnings,
            graphicsFrameCaptureLimit: nil,
            desktopSize: requestedDesktopSize,
            // Joined even when sharing is off, so sharing can start mid-session; the
            // clipboard bridge decides what crosses.
            clipboardEnabled: true,
            audioPlaybackEnabled: audioPlaybackEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            storedClientLicense: storedClientLicense,
            keyboardLayout: keyboardLayout
        )

        let connectionID = UUID()
        let cancellation = RDPConnectionCancellation()
        let connectionStartedAt = Date()
        activeConnectionID = connectionID
        activeCancellation = cancellation
        renderMetricsStore.reset(connectionStartedAt: connectionStartedAt)
        updateViewerMetricsSummary(renderMetricsStore.metrics)
        isConnecting = true
        render()

        let sink = RDPRemoteSessionMainActorSink(controller: self, connectionID: connectionID)
        let credentialStore = credentialStore
        let clientLicenseStore = clientLicenseStore
        let trustedCertificateStore = trustedCertificateStore
        let acceptsUntrustedCertificates = hideCertificateWarnings
        // RDPSessionClient.run blocks for the whole session, so it gets its own thread
        // rather than holding a Swift concurrency worker.
        let sessionThread = Thread {
            var keyframeRequests = RDPKeyframeRequestThrottle()
            let decodeQueue = RDPFrameDecodeQueue(
                shouldCancel: {
                    cancellation.isCancelled
                },
                onDecoded: { presentation, receivedAt, decodedAt, timing in
                    sink.apply { controller in
                        controller.previewDecodeError = nil
                        let shouldForceMetricsSnapshot = !controller.hasPresentedFrame
                        controller.renderMetricsStore.recordDecodedFrame(
                            presentation.frame,
                            receivedAt: receivedAt,
                            decodedAt: decodedAt,
                            timing: timing
                        )
                        let metricsChanged = controller.publishRenderMetricsSnapshotIfNeeded(
                            force: shouldForceMetricsSnapshot,
                            at: decodedAt
                        )
                        let presentationChanged = controller.presentDecodedFrame(presentation)
                        if metricsChanged || presentationChanged {
                            controller.render()
                        }
                    }
                },
                onDecodeFailed: { receivedAt, errorDescription in
                    sink.apply { controller in
                        controller.previewDecodeError = errorDescription
                        controller.renderMetricsStore.recordDecodeFailure(
                            receivedAt: receivedAt,
                            errorDescription: errorDescription
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(at: receivedAt)
                        controller.render()
                    }
                }
            )
            let wireReceiveCoalescer = RDPWireReceiveMetricsCoalescer(
                shouldCancel: {
                    cancellation.isCancelled
                },
                onFlush: { sample in
                    sink.apply { controller in
                        controller.renderMetricsStore.recordWireReceive(sample)
                        if controller.publishRenderMetricsSnapshotIfNeeded(at: sample.receivedAt) {
                            controller.render()
                        }
                    }
                }
            )
            defer {
                wireReceiveCoalescer.flush()
                wireReceiveCoalescer.cancel()
                decodeQueue.cancel()
            }
            let nextReport = RDPSessionClient().run(
                configuration: configuration,
                onGraphicsFrame: { frame in
                    let completion = decodeQueue.submitAndWait(
                        frame,
                        receivedAt: Date(),
                        shouldContinue: {
                            cancellation.isCancelled == false
                        }
                    )
                    if frame.contentKind == .video, completion == .decoded {
                        keyframeRequests.recordDecodedVideo()
                    }
                    // An update that fails to decode leaves stale pixels, not a broken session.
                    // Failed video waits for a keyframe, which the server is asked for.
                    if case .failed = completion {
                        if frame.contentKind == .video, keyframeRequests.shouldRequest(at: Date()) {
                            sink.apply { controller in
                                controller.requestKeyframe(desktopSize: requestedDesktopSize)
                            }
                        }
                        return
                    }
                    try completion.requireDecoded()
                },
                onInputReady: { session in
                    let persistenceResult = persistCredentialsIfNeeded(
                        credentialPersistenceRequest,
                        store: credentialStore
                    )
                    if let persistenceResult {
                        sink.apply { controller in
                            controller.applyCredentialPersistenceResult(persistenceResult)
                            controller.render()
                        }
                    }
                    sink.apply { controller in
                        controller.inputSession = session
                        controller.render()
                    }
                },
                onDisplayControlReady: { session in
                    sink.apply { controller in
                        controller.displayControlSession = session
                        controller.displayControlMessage = "Display Control ready."
                        // A server redirection's target has not been sent the layout the first server got.
                        controller.cancelPendingDisplayResize(resetLastRequestedSize: true)
                        controller.scheduleAutoDisplaySizeUpdate()
                        controller.render()
                    }
                },
                onClipboardReady: { session in
                    // The server's first copy can arrive before the bridge attaches on the main
                    // thread, so nothing is fetched until the bridge applies the sharing choice.
                    session.fetchesRemoteCopies = false
                    sink.apply { controller in
                        controller.clipboard.attach(session)
                        controller.render()
                    }
                },
                onClipboardText: { text in
                    sink.apply { controller in
                        controller.clipboard.receiveText(text)
                        controller.render()
                    }
                },
                onClipboardFileGroupDescriptor: { descriptorList in
                    sink.apply { controller in
                        controller.clipboard.receiveFileList(descriptorList)
                        controller.render()
                    }
                },
                onClipboardFileContents: { response in
                    sink.apply { controller in
                        controller.clipboard.receiveFileContents(response)
                        controller.render()
                    }
                },
                onAudioSample: { sample in
                    sink.apply { controller in
                        guard controller.audioPlaybackEnabled else {
                            return
                        }
                        let nextMessage: String
                        do {
                            nextMessage = try controller.remoteAudioPlayer.enqueue(sample)
                                ? controller.remoteAudioPlayer.statusMessage
                                : "Dropping delayed audio."
                        } catch {
                            nextMessage = String(describing: error)
                        }
                        if controller.audioMessage != nextMessage {
                            controller.audioMessage = nextMessage
                            controller.render()
                        }
                    }
                },
                onCertificate: { certificateInfo in
                    // Cancelling here closes the connection before any credential is sent.
                    let refusal = trustedCertificateStore.refusal(
                        of: certificateInfo,
                        port: target.port,
                        acceptsUntrusted: acceptsUntrustedCertificates
                    )
                    if refusal != nil {
                        cancellation.cancel()
                    }
                    sink.apply { controller in
                        controller.serverCertificateInfo = certificateInfo
                        // After a server redirection, the certificate belongs to the redirection target.
                        controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                            host: certificateInfo.host,
                            port: target.port,
                            sha256: certificateInfo.sha256
                        )
                        if let refusal {
                            controller.refuseCertificate(refusal)
                        }
                        controller.render()
                    }
                },
                onWireReceive: { sample in
                    wireReceiveCoalescer.record(sample)
                },
                cancellation: cancellation
            )
            // A license the server issued stays valid even when the user ends the session.
            let clientLicensePersistenceResult = persistClientLicenseIfNeeded(
                nextReport.rdpIssuedClientLicense,
                key: clientLicenseKey,
                store: clientLicenseStore
            )
            guard cancellation.isCancelled == false else {
                return
            }
            let finalWireReceiveSample = wireReceiveCoalescer.takePendingSample()
            let firstFrameDecodeResult = nextReport.rdpGraphicsFirstFrame.map(decodeReportFirstFrame)
            sink.apply { controller in
                if let finalWireReceiveSample {
                    controller.renderMetricsStore.recordWireReceive(finalWireReceiveSample)
                }
                controller.flushPendingFramePresentation()
                controller.publishRenderMetricsSnapshotIfNeeded(force: true)
                controller.report = nextReport
                if let clientLicensePersistenceResult {
                    controller.applyClientLicensePersistenceResult(clientLicensePersistenceResult)
                }
                let certificateHost = controller.serverCertificateInfo?.host ?? target.host
                if let certificateTrusted = nextReport.certificateTrusted {
                    controller.serverCertificateInfo = RDPServerCertificateInfo(
                        trusted: certificateTrusted,
                        sha256: nextReport.certificateSHA256,
                        warnings: nextReport.warnings,
                        host: certificateHost
                    )
                }
                controller.sessionEndReason = RDPSessionEndReason(report: nextReport)
                controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                    host: certificateHost,
                    port: target.port,
                    sha256: nextReport.certificateSHA256
                )
                if controller.previewFrame == nil {
                    controller.previewFrame = nextReport.rdpGraphicsFirstFrame.map(RDPFrameMetadata.init)
                }
                if controller.hasPresentedFrame == false,
                   let firstFrameDecodeResult
                {
                    switch firstFrameDecodeResult {
                    case let .decoded(presentation, receivedAt, decodedAt, timing):
                        controller.renderMetricsStore.recordDecodedFrame(
                            presentation.frame,
                            receivedAt: receivedAt,
                            decodedAt: decodedAt,
                            timing: timing
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(force: true, at: decodedAt)
                        controller.applyFramePresentation(presentation)
                    case let .failed(receivedAt, errorDescription):
                        controller.previewDecodeError = errorDescription
                        controller.renderMetricsStore.recordDecodeFailure(
                            receivedAt: receivedAt,
                            errorDescription: errorDescription
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(force: true, at: receivedAt)
                    }
                }
                controller.detachSessionChannels()
                controller.isConnecting = false
                controller.activeConnectionID = nil
                controller.activeCancellation = nil
                controller.render()
            }
        }
        sessionThread.name = "RDPClient session"
        sessionThread.qualityOfService = .userInitiated
        sessionThread.start()
    }

    @discardableResult
    private func presentDecodedFrame(_ presentation: RDPDecodedFramePresentation) -> Bool {
        guard hasPresentedFrame else {
            return applyFramePresentation(presentation)
        }

        guard framePacing.hasDisplayLink else {
            return applyFramePresentation(presentation)
        }

        if framePresentationBuffer.replacePendingPresentation(presentation) {
            let skippedAt = Date()
            renderMetricsStore.recordSkippedPresentationFrame(at: skippedAt)
            return publishRenderMetricsSnapshotIfNeeded(at: skippedAt)
        }
        return false
    }

    private var framePresentationClockEnabled: Bool {
        isConnecting && hasPresentedFrame
    }

    private func displayLinkFrameArrived(_ displayLink: CADisplayLink) {
        let nextFramePacing = framePacing.updatingDisplayLinkDuration(displayLink.duration)
        let pacingChanged = updateFramePacing(nextFramePacing, shouldRender: false)
        let presentationChanged = flushPendingFramePresentation()
        if pacingChanged || presentationChanged {
            render()
        }
    }

    @discardableResult
    private func updateFramePacing(
        _ nextState: RDPFramePacingState,
        shouldRender: Bool = true
    ) -> Bool {
        let currentBackingScaleFactor = framePacing.backingScaleFactor
        guard framePacing != nextState else {
            return false
        }

        framePacing = nextState
        updateViewerMetricsSummary(renderMetricsStore.metrics)
        if currentBackingScaleFactor != nextState.backingScaleFactor {
            refreshViewerPixelSize()
        }
        if shouldRender {
            render()
        }
        return true
    }

    @discardableResult
    private func flushPendingFramePresentation() -> Bool {
        guard let pendingFramePresentation = framePresentationBuffer.takePendingPresentation() else {
            return false
        }
        return applyFramePresentation(pendingFramePresentation)
    }

    @discardableResult
    private func applyFramePresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let wasFirstPresentedFrame = hasPresentedFrame == false
        let shouldUpdateFrameMetadata = shouldPublishFrameMetadata(presentation.frame)
        remoteDesktopRenderer.present(presentation, id: renderMetricsStore.metrics.decodedFrameCount)
        if shouldUpdateFrameMetadata {
            previewFrame = RDPFrameMetadata(presentation.frame)
        }
        if wasFirstPresentedFrame {
            hasPresentedFrame = true
        }
        return wasFirstPresentedFrame || shouldUpdateFrameMetadata
    }

    private func shouldPublishFrameMetadata(_ frame: RDPGraphicsFrameSnapshot) -> Bool {
        guard let currentFrame = previewFrame else {
            return true
        }
        return currentFrame.width != frame.width
            || currentFrame.height != frame.height
            || currentFrame.codecName != frame.codecName
            || currentFrame.videoCodec != frame.videoCodec
    }

    @discardableResult
    private func publishRenderMetricsSnapshotIfNeeded(
        force: Bool = false,
        at timestamp: Date = Date()
    ) -> Bool {
        guard let snapshot = renderMetricsStore.snapshotIfNeeded(force: force, at: timestamp) else {
            return false
        }
        var didChange = false
        if previewFrameCount != snapshot.decodedFrameCount {
            previewFrameCount = snapshot.decodedFrameCount
            didChange = true
        }
        didChange = updateViewerMetricsSummary(snapshot) || didChange
        return didChange
    }

    @discardableResult
    private func updateViewerMetricsSummary(_ metrics: RDPRenderMetrics) -> Bool {
        let nextSummary = compactViewerMetricsSummary(metrics: metrics, framePacing: framePacing)
        if viewerMetricsSummary != nextSummary {
            viewerMetricsSummary = nextSummary
            return true
        }
        return false
    }

    private func resetFramePresentationState() {
        framePresentationBuffer.clear()
        hasPresentedFrame = false
        remoteDesktopRenderer.clear()
    }

    private func refuseCertificate(_ refusal: CertificateRefusal) {
        certificateRefusal = refusal
        let reason = switch refusal {
        case .changed: "The server's certificate is not the one trusted for this host."
        case .untrusted: "Neither this Mac nor RDPClient trusts the server's certificate."
        }
        sessionEndReason = RDPSessionEndReason(
            kind: .failed,
            message: reason + " The connection was closed before any credential was sent."
        )
        cancelConnection(shouldRecordCancellation: false)
    }

    func cancelConnection(shouldRecordCancellation: Bool = true) {
        let shouldRecordCancellation = shouldRecordCancellation && (isConnecting || activeConnectionID != nil)
        activeCancellation?.cancel()
        detachSessionChannels()
        resetFramePresentationState()
        activeCancellation = nil
        activeConnectionID = nil
        if shouldRecordCancellation {
            sessionEndReason = .cancelled
        }
        isConnecting = false
        render()
    }

    /// Drops what a session handed out, so nothing more is sent to it once it has ended.
    private func detachSessionChannels() {
        cancelPendingDisplayResize(resetLastRequestedSize: true)
        inputSession = nil
        displayControlSession = nil
        displayControlMessage = nil
        clipboard.detach()
        remoteAudioPlayer.reset()
        audioMessage = nil
    }

    private func applyDisplaySizeToActiveSession() {
        syncStateFromFields()
        let requestedDesktopSize: RDPDesktopSize
        do {
            requestedDesktopSize = try RDPDesktopSize(widthText: desktopWidth, heightText: desktopHeight)
        } catch {
            formError = String(describing: error)
            render()
            return
        }
        applyDisplaySizeToActiveSession(
            width: UInt32(requestedDesktopSize.width),
            height: UInt32(requestedDesktopSize.height)
        )
    }

    private func useViewerSizeForDisplayFields() {
        guard let viewerPixelSize else {
            displayControlMessage = "Viewer size is not available yet."
            render()
            return
        }
        syncDisplayFieldsWithViewerSize(viewerPixelSize)
        displayControlMessage = "View size selected: \(viewerPixelSize.displayRequest.label)."
        render()
    }

    private func applyViewerSizeToActiveSession() {
        guard let viewerPixelSize else {
            displayControlMessage = "Viewer size is not available yet."
            render()
            return
        }
        syncDisplayFieldsWithViewerSize(viewerPixelSize)
        applyDisplayRequestToActiveSession(viewerPixelSize.displayRequest)
    }

    private func applyDisplaySizeToActiveSession(width: UInt32, height: UInt32) {
        let request = makeDisplayRequest(width: width, height: height)
        applyDisplayRequestToActiveSession(request)
    }

    private func applyDisplayRequestToActiveSession(_ request: RDPDisplayRequest) {
        guard let displayControlSession else {
            displayControlMessage = "Display Control is not available for this session."
            render()
            return
        }

        displayControlSession.send(request)
        displayResize.recordSent(request)
        displayControlMessage = "Resize requested: \(request.label)."
        formError = nil
        render()
    }

    /// Windows and gnome-remote-desktop send no keyframe by themselves, but answer the monitor
    /// layout sent again with one.
    private func requestKeyframe(desktopSize: RDPDesktopSize) {
        guard let displayControlSession else {
            return
        }
        let request = displayResize.lastSent
            ?? makeDisplayRequest(width: UInt32(desktopSize.width), height: UInt32(desktopSize.height))
        displayControlSession.send(request)
        displayControlMessage = "Video failed to decode; asked the server for a fresh picture."
        render()
    }

    private func updateViewerSurfaceSize(_ pointSize: CGSize) {
        guard pointSize.width > 0, pointSize.height > 0 else {
            return
        }
        viewerPointSize = pointSize
        refreshViewerPixelSize()
        render()
    }

    private func refreshViewerPixelSize() {
        guard viewerPointSize.width > 0, viewerPointSize.height > 0 else {
            return
        }
        let scale = framePacing.backingScaleFactor ?? view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let nextSize = RDPViewerPixelSize(pointSize: viewerPointSize, backingScaleFactor: scale)
        if viewerPixelSize != nextSize {
            viewerPixelSize = nextSize
            if autoApplyViewerSize {
                syncDisplayFieldsWithViewerSize(nextSize)
            }
            scheduleAutoDisplaySizeUpdate()
        }
    }

    private func scheduleAutoDisplaySizeUpdate() {
        guard autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil,
              let viewerPixelSize
        else {
            return
        }

        let displayRequest = viewerPixelSize.displayRequest
        pendingDisplayResizeTask?.cancel()
        pendingDisplayResizeTask = nil
        guard displayResize.viewChanged(to: displayRequest) else {
            return
        }

        pendingDisplayResizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: RDPDisplayResizeDebounce.delayNanoseconds)
            guard Task.isCancelled == false else {
                return
            }
            self?.applyAutoDisplayRequest(displayRequest)
        }
    }

    private func applyAutoDisplayRequest(_ displayRequest: RDPDisplayRequest) {
        pendingDisplayResizeTask = nil
        let isSettled = displayResize.settle(displayRequest)
        guard isSettled,
              autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil
        else {
            return
        }

        desktopWidth = String(displayRequest.width)
        desktopHeight = String(displayRequest.height)
        applyDisplayRequestToActiveSession(displayRequest)
    }

    private func cancelPendingDisplayResize(resetLastRequestedSize: Bool = false) {
        pendingDisplayResizeTask?.cancel()
        pendingDisplayResizeTask = nil
        displayResize.cancel(forgettingLastSent: resetLastRequestedSize)
    }

    private func syncDisplayFieldsWithViewerSize(_ viewerPixelSize: RDPViewerPixelSize) {
        desktopWidth = viewerPixelSize.desktopWidthText
        desktopHeight = viewerPixelSize.desktopHeightText
    }

    private func makeDisplayRequest(width: UInt32, height: UInt32) -> RDPDisplayRequest {
        if let viewerPixelSize {
            return RDPDisplayRequest(
                width: width,
                height: height,
                scaleFactors: RDPDisplayScaleFactors(
                    backingScaleFactor: viewerPixelSize.backingScaleFactor
                )
            )
        }
        let backingScaleFactor = framePacing.backingScaleFactor ?? view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return RDPDisplayRequest(
            width: width,
            height: height,
            scaleFactors: RDPDisplayScaleFactors(backingScaleFactor: backingScaleFactor)
        )
    }

    func syncClipboardNow() {
        clipboard.syncNow()
        render()
    }

    func startTemporaryClipboardSharing() {
        clipboard.startTemporarySharing()
        render()
    }

    private func trustCurrentCertificate() {
        guard let key = currentCertificateTrustKey() else {
            certificateTrustMessage = "No server certificate fingerprint is available."
            render()
            return
        }
        trustedCertificateStore.trust(key)
        // A connection refused for this certificate connects again now that it is trusted.
        guard certificateRefusal == nil else {
            beginConnection()
            return
        }
        certificateTrustedByApp = true
        certificateTrustMessage = "Certificate trusted for this host."
        render()
    }

    private func forgetCurrentCertificate() {
        guard let key = currentCertificateTrustKey() else {
            certificateTrustMessage = "No server certificate fingerprint is available."
            render()
            return
        }
        trustedCertificateStore.removeTrust(key)
        certificateTrustedByApp = false
        certificateTrustMessage = "Certificate trust removed for this host."
        render()
    }

    private func currentCertificateTrustKey() -> RDPServerCertificateTrustKey? {
        guard let certificateSHA256 = report?.certificateSHA256 ?? serverCertificateInfo?.sha256,
              let target = try? RDPConnectionTarget(host: host, portText: port)
        else {
            return nil
        }
        return RDPServerCertificateTrustKey(
            host: serverCertificateInfo?.host ?? target.host,
            port: target.port,
            sha256: certificateSHA256
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

    private var requestedDesktopSizeLabel: String {
        [
            desktopWidth.trimmingCharacters(in: .whitespacesAndNewlines),
            desktopHeight.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "x")
    }

    /// `keepingEnteredPassword` keeps a password the user already entered for this account, and
    /// its Remember choice, over the saved one: the draft's password may be newer than Keychain's.
    private func loadRememberedPasswordIfAvailable(keepingEnteredPassword: Bool = false) {
        guard !isConnecting,
              let key = KeychainCredentialKey(host: host, portText: port, username: username, domain: domain)
        else {
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
            guard keepingEnteredPassword == false || password.isEmpty else {
                return
            }
            rememberPassword = true
            password = savedPassword
            keychainMessage = "Password loaded from Keychain."
        } catch {
            hasRememberedPassword = false
            keychainMessage = String(describing: error)
        }
    }

    private func credentialPersistenceRequest(
        key: KeychainCredentialKey?,
        password: String,
        hasCredentials: Bool
    ) -> CredentialPersistenceRequest? {
        guard hasCredentials,
              let key
        else {
            return nil
        }

        if rememberPassword {
            return .save(key: key, password: password)
        }
        if hasRememberedPassword {
            return .delete(key: key)
        }
        return nil
    }

    private func applyCredentialPersistenceResult(_ result: Result<CredentialPersistenceResult, Error>) {
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
        }
    }

    private func applyClientLicensePersistenceResult(_ result: Result<ClientLicensePersistenceResult, Error>) {
        switch result {
        case .success(.saved):
            keychainMessage = "Client license saved to Keychain."
        case let .failure(error):
            keychainMessage = String(describing: error)
        }
    }

    private func syncStateFromFields() {
        host = hostField.stringValue
        port = portField.stringValue
        desktopWidth = desktopWidthField.stringValue
        desktopHeight = desktopHeightField.stringValue
        username = usernameField.stringValue
        domain = domainField.stringValue
        password = passwordField.stringValue
        graphicsCapabilityProfile = selectedGraphicsProfile()
    }

    private func syncFieldsFromState() {
        syncTextField(hostField, value: host)
        syncTextField(portField, value: port)
        syncTextField(desktopWidthField, value: desktopWidth)
        syncTextField(desktopHeightField, value: desktopHeight)
        syncTextField(usernameField, value: username)
        syncTextField(domainField, value: domain)
        syncTextField(passwordField, value: password)
    }

    private func syncTextField(_ field: NSTextField, value: String) {
        guard field.stringValue != value else {
            return
        }
        if let editor = field.currentEditor(), view.window?.firstResponder === editor {
            return
        }
        field.stringValue = value
    }

    private var connectButtonTitle: String {
        if isConnecting {
            return previewFrame == nil ? "Connecting" : "Connected"
        }
        return report == nil ? "Connect" : "Reconnect"
    }

    private var canStartConnection: Bool {
        !isConnecting && host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var displayControlStatusText: String {
        guard displayControlSession != nil else {
            return "Size applies on next connection."
        }
        return autoApplyViewerSize ? "Following view size." : "Display Control ready."
    }

    private var audioStatusMessage: String {
        guard audioPlaybackEnabled else {
            return "Off."
        }
        return audioMessage ?? "Requested on connect."
    }

    func toggleSessionControls() {
        controlsVisible.toggle()
        render()
    }

    @objc private func textFieldAction(_: NSTextField) {
        syncStateFromFields()
        render()
    }

    @objc private func toggleAutoApplyViewerSize(_ sender: NSButton) {
        autoApplyViewerSize = sender.state == .on
        if autoApplyViewerSize {
            if let viewerPixelSize {
                syncDisplayFieldsWithViewerSize(viewerPixelSize)
            }
            scheduleAutoDisplaySizeUpdate()
        } else {
            cancelPendingDisplayResize()
        }
        render()
    }

    @objc private func toggleRememberPassword(_ sender: NSButton) {
        rememberPassword = sender.state == .on
        render()
    }

    @objc private func toggleClipboardSharing(_ sender: NSButton) {
        clipboard.setSharingEnabled(sender.state == .on)
        render()
    }

    @objc private func toggleAudioPlayback(_ sender: NSButton) {
        audioPlaybackEnabled = sender.state == .on
        if !audioPlaybackEnabled {
            remoteAudioPlayer.reset()
            audioMessage = "Off."
        } else {
            audioMessage = nil
        }
        render()
    }

    @objc private func toggleHideCertificateWarnings(_ sender: NSButton) {
        hideCertificateWarnings = sender.state == .on
        render()
    }

    @objc private func graphicsProfileChanged(_: NSPopUpButton) {
        graphicsCapabilityProfile = selectedGraphicsProfile()
        render()
    }

    @objc private func timeoutChanged(_ sender: NSStepper) {
        timeoutSeconds = sender.doubleValue
        render()
    }

    @objc private func connectPressed(_: NSButton) {
        startSession()
    }

    @objc private func cancelPressed(_: NSButton) {
        cancelConnection()
    }

    @objc private func applyDisplayPressed(_: NSButton) {
        applyDisplaySizeToActiveSession()
    }

    @objc private func useViewerSizePressed(_: NSButton) {
        useViewerSizeForDisplayFields()
    }

    @objc private func applyViewerSizePressed(_: NSButton) {
        applyViewerSizeToActiveSession()
    }

    @objc private func temporaryClipboardPressed(_: NSButton) {
        startTemporaryClipboardSharing()
    }

    @objc private func syncClipboardPressed(_: NSButton) {
        syncClipboardNow()
    }

    private func configureCheckbox(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.setButtonType(.switch)
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 8192
        formatter.usesGroupingSeparator = false
        return formatter
    }

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        stack.addArrangedSubview(label)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true
        }
        return stack
    }

    private func labeledField(_ title: String, _ field: NSTextField, fieldWidth: CGFloat? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: fieldWidth ?? 260).isActive = true
        return stack
    }

    private func labeledControl(_ title: String, _ control: NSControl, width: CGFloat = 260) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    private func selectedGraphicsProfile() -> RDPGraphicsCapabilityProfile {
        guard let rawValue = graphicsProfilePopup.selectedItem?.representedObject as? String,
              let profile = RDPGraphicsCapabilityProfile(rawValue: rawValue)
        else {
            return .automatic
        }
        return profile
    }

    private func sizeRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        desktopWidthField.widthAnchor.constraint(equalToConstant: 82).isActive = true
        desktopHeightField.widthAnchor.constraint(equalToConstant: 82).isActive = true
        stack.addArrangedSubview(desktopWidthField)
        stack.addArrangedSubview(NSTextField(labelWithString: "x"))
        stack.addArrangedSubview(desktopHeightField)
        stack.addArrangedSubview(applyDisplayButton)
        return stack
    }

    private func viewerSizeActionsRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.addArrangedSubview(useViewerSizeButton)
        stack.addArrangedSubview(applyViewerSizeButton)
        return stack
    }

    private func timeoutRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.addArrangedSubview(timeoutLabel)
        stack.addArrangedSubview(timeoutStepper)
        return stack
    }

    private func actionRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        connectButton.widthAnchor.constraint(equalToConstant: 210).isActive = true
        cancelButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(connectButton)
        stack.addArrangedSubview(cancelButton)
        return stack
    }
}

private final class RDPRemoteSessionMainActorSink: @unchecked Sendable {
    weak var controller: RDPRemoteSessionViewController?
    let connectionID: UUID

    init(controller: RDPRemoteSessionViewController, connectionID: UUID) {
        self.controller = controller
        self.connectionID = connectionID
    }

    /// Runs `operation` on the main queue in submission order, so frames and audio stay ordered.
    /// The block keeps the sink alive: the session thread releases it right after submitting
    /// the final update. The sink holds the controller weakly, so this forms no cycle.
    func apply(_ operation: @escaping @MainActor (RDPRemoteSessionViewController) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = self.controller,
                      controller.acceptsConnectionEvent(id: self.connectionID)
                else {
                    return
                }
                operation(controller)
            }
        }
    }
}
