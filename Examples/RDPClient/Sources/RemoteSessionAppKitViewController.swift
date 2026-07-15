import AppKit
import QuartzCore
import RDPKit

private let remoteSessionMaximumLocalClipboardFileBytes = 32 * 1024 * 1024

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
    private var connectionTask: Task<Void, Never>?
    private var activeConnectionID: UUID?
    private var activeCancellation: RDPConnectionCancellation?
    private var sessionEndReason: RDPSessionEndReason?
    private var inputSession: RDPInputSession?
    private var displayControlSession: RDPDisplayControlSession?
    private var displayControlMessage: String?
    private var autoApplyViewerSize = true
    private var pendingDisplayResizeTask: Task<Void, Never>?
    private var lastRequestedDisplayRequest: RDPDisplayRequest?
    private var viewerPointSize: CGSize = .zero
    private var viewerPixelSize: RDPViewerPixelSize?
    private var clipboardSession: RDPClipboardSession?
    private var clipboardSharingEnabled = true
    private var clipboardMessage: String?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var temporaryClipboardSharingExpiresAt: Date?
    private var clipboardTimerTick = Date()
    private var remoteClipboardFileTransfer: RDPRemoteSessionRemoteClipboardFileTransfer?
    private var remoteClipboardDownloadDirectory: URL?
    private var nextRemoteClipboardStreamID: UInt32 = 1
    private var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    private var audioPlaybackEnabled = false
    private var audioMessage: String?
    private var remoteAudioPlayer = RDPAudioPlayer()
    private var report: RDPPreflightReport?
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
        clipboardSharingEnabled = draft.clipboardSharingEnabled
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
        loadRememberedPasswordIfAvailable()
        render()
        if shouldAutoConnect {
            shouldAutoConnect = false
            startPreflight()
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
        detailView.onConnect = { [weak self] in self?.startPreflight() }
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
        clipboardSharingButton.state = clipboardSharingEnabled ? .on : .off
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
        clipboardLabel.stringValue = clipboardStatusMessage
        audioLabel.stringValue = audioStatusMessage

        applyDisplayButton.isEnabled = isConnecting && displayControlSession != nil
        useViewerSizeButton.isEnabled = viewerPixelSize != nil
        applyViewerSizeButton.isEnabled = isConnecting && displayControlSession != nil && viewerPixelSize != nil
        temporaryClipboardButton.title = temporaryClipboardSharingButtonTitle
        temporaryClipboardButton.isEnabled = clipboardSession != nil
        syncClipboardButton.isEnabled = clipboardSharingEnabled && clipboardSession != nil
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
        if let warning = report?.warnings.first ?? serverCertificateInfo?.warnings.first {
            return RDPAppKitNoticeState(
                title: warning.code,
                message: warning.message,
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                actionTitle: "Trust Certificate",
                action: .trustCertificate
            )
        }
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

                let now = Date()
                if temporaryClipboardSharingExpiresAt != nil {
                    clipboardTimerTick = now
                    expireTemporaryClipboardSharingIfNeeded(now: now)
                }
                if clipboardSharingEnabled, clipboardSession != nil {
                    publishPasteboardIfChanged()
                }
                render()
            }
        }
    }

    private func openDiagnosticsWindow() {
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
            clipboardReady: clipboardSession != nil,
            clipboardSharingEnabled: clipboardSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            certificateTrustedByApp: certificateTrustedByApp,
            certificateTrustMessage: certificateTrustMessage,
            formError: formError,
            isConnecting: isConnecting
        )
        diagnosticsModel.updateSnapshot(nextSnapshot)
    }

    private func startPreflight() {
        activeCancellation?.cancel()
        connectionTask?.cancel()
        cancelPendingDisplayResize(resetLastRequestedSize: true)
        connectionTask = nil
        activeConnectionID = nil
        activeCancellation = nil
        sessionEndReason = nil
        inputSession = nil
        displayControlSession = nil
        displayControlMessage = nil
        clipboardSession = nil
        clipboardMessage = nil
        discardRemoteClipboardFileTransfer()
        pasteboardChangeCount = NSPasteboard.general.changeCount
        remoteAudioPlayer.reset()
        audioMessage = nil
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
        let credentialKey = makeCredentialKey(
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain
        )
        let clientLicenseKey = makeClientLicenseKey(
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain
        )
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

        let configuration = RDPConnectionConfiguration(
            target: target,
            credentials: credentials,
            timeoutSeconds: Int(timeoutSeconds),
            hideCertificateWarnings: hideCertificateWarnings,
            graphicsFrameCaptureLimit: nil,
            desktopSize: requestedDesktopSize,
            clipboardEnabled: clipboardSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile,
            storedClientLicense: storedClientLicense
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
        connectionTask = Task.detached(priority: .userInitiated) {
            let decodeQueue = RDPLatestFrameDecodeQueue(
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
                },
                onSkippedFrames: { count, receivedAt in
                    sink.apply { controller in
                        controller.renderMetricsStore.recordSkippedDecodeFrames(
                            count,
                            receivedAt: receivedAt
                        )
                        if controller.publishRenderMetricsSnapshotIfNeeded(at: receivedAt) {
                            controller.render()
                        }
                    }
                }
            )
            let wireReceiveCoalescer = RDPWireReceiveMetricsCoalescer(
                shouldCancel: {
                    Task.isCancelled || cancellation.isCancelled
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
            let nextReport = RDPPreflightClient().run(
                configuration: configuration,
                onGraphicsFrame: { frame in
                    try decodeQueue.submitAndWait(
                        frame,
                        receivedAt: Date(),
                        shouldContinue: {
                            Task.isCancelled == false && cancellation.isCancelled == false
                        }
                    ).requireDecoded()
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
                        controller.scheduleAutoDisplaySizeUpdate(force: true)
                        controller.render()
                    }
                },
                onClipboardReady: { session in
                    sink.apply { controller in
                        guard controller.clipboardSharingEnabled else {
                            session.publishLocalUnicodeText(nil)
                            controller.clipboardSession = session
                            controller.clipboardMessage = "Disabled."
                            controller.render()
                            return
                        }
                        controller.clipboardSession = session
                        controller.clipboardMessage = "Ready."
                        controller.publishPasteboardIfChanged(force: true)
                        controller.render()
                    }
                },
                onClipboardText: { text in
                    sink.apply { controller in
                        guard controller.clipboardSharingEnabled else {
                            return
                        }
                        controller.applyRemoteClipboardText(text)
                        controller.render()
                    }
                },
                onClipboardFileGroupDescriptor: { descriptorList in
                    sink.apply { controller in
                        guard controller.clipboardSharingEnabled else {
                            return
                        }
                        controller.applyRemoteClipboardFileList(descriptorList)
                        controller.render()
                    }
                },
                onClipboardFileContents: { response in
                    sink.apply { controller in
                        guard controller.clipboardSharingEnabled else {
                            return
                        }
                        controller.applyRemoteClipboardFileContentsResponse(response)
                        controller.render()
                    }
                },
                onAudioSample: { sample in
                    guard Task.isCancelled == false else {
                        return
                    }
                    sink.apply { controller in
                        guard controller.audioPlaybackEnabled else {
                            return
                        }
                        do {
                            let queued = try controller.remoteAudioPlayer.enqueue(sample)
                            let nextMessage = queued
                                ? controller.remoteAudioPlayer.statusMessage
                                : "Dropping delayed audio."
                            if controller.audioMessage != nextMessage {
                                controller.audioMessage = nextMessage
                            }
                        } catch {
                            let nextMessage = String(describing: error)
                            if controller.audioMessage != nextMessage {
                                controller.audioMessage = nextMessage
                            }
                        }
                        controller.render()
                    }
                },
                onCertificate: { certificateInfo in
                    guard Task.isCancelled == false else {
                        return
                    }
                    sink.apply { controller in
                        controller.serverCertificateInfo = certificateInfo
                        controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                            host: target.host,
                            port: target.port,
                            sha256: certificateInfo.sha256
                        )
                        controller.render()
                    }
                },
                onWireReceive: { sample in
                    guard Task.isCancelled == false else {
                        return
                    }
                    wireReceiveCoalescer.record(sample)
                },
                cancellation: cancellation,
                shouldCancel: {
                    Task.isCancelled || cancellation.isCancelled
                }
            )
            let finalWireReceiveSample = wireReceiveCoalescer.takePendingSample()
            guard Task.isCancelled == false else {
                return
            }
            let firstFrameDecodeResult = nextReport.rdpGraphicsFirstFrame.map(decodeReportFirstFrame)
            let clientLicensePersistenceResult = persistClientLicenseIfNeeded(
                nextReport.rdpIssuedClientLicense,
                key: clientLicenseKey,
                store: clientLicenseStore
            )
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
                if let certificateTrusted = nextReport.certificateTrusted {
                    controller.serverCertificateInfo = RDPServerCertificateInfo(
                        trusted: certificateTrusted,
                        sha256: nextReport.certificateSHA256,
                        warnings: nextReport.warnings
                    )
                }
                controller.sessionEndReason = RDPSessionEndReason(report: nextReport)
                controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                    host: target.host,
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
                controller.isConnecting = false
                controller.activeConnectionID = nil
                controller.activeCancellation = nil
                controller.connectionTask = nil
                controller.remoteAudioPlayer.reset()
                controller.render()
            }
        }
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
        let nextSummary = appKitCompactViewerMetricsSummary(metrics: metrics, framePacing: framePacing)
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

    private func cancelConnection(shouldRecordCancellation: Bool = true) {
        let shouldRecordCancellation = shouldRecordCancellation
            && (isConnecting || activeConnectionID != nil || connectionTask != nil)
        activeCancellation?.cancel()
        connectionTask?.cancel()
        cancelPendingDisplayResize(resetLastRequestedSize: true)
        resetFramePresentationState()
        activeCancellation = nil
        connectionTask = nil
        activeConnectionID = nil
        inputSession = nil
        displayControlSession = nil
        displayControlMessage = nil
        clipboardSession = nil
        clipboardMessage = nil
        discardRemoteClipboardFileTransfer()
        pasteboardChangeCount = NSPasteboard.general.changeCount
        remoteAudioPlayer.reset()
        audioMessage = nil
        if shouldRecordCancellation {
            sessionEndReason = .cancelled
        }
        isConnecting = false
        render()
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
        lastRequestedDisplayRequest = request
        displayControlMessage = "Resize requested: \(request.label)."
        formError = nil
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

    private func scheduleAutoDisplaySizeUpdate(force: Bool = false) {
        guard autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil,
              let viewerPixelSize
        else {
            return
        }

        let displayRequest = viewerPixelSize.displayRequest
        guard force || lastRequestedDisplayRequest != displayRequest else {
            return
        }

        pendingDisplayResizeTask?.cancel()
        pendingDisplayResizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else {
                return
            }
            self?.applyAutoDisplayRequest(displayRequest)
        }
    }

    private func applyAutoDisplayRequest(_ displayRequest: RDPDisplayRequest) {
        pendingDisplayResizeTask = nil
        guard autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil,
              lastRequestedDisplayRequest != displayRequest
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
        if resetLastRequestedSize {
            lastRequestedDisplayRequest = nil
        }
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

    private func syncClipboardNow() {
        publishPasteboardIfChanged(force: true)
        render()
    }

    private func startTemporaryClipboardSharing() {
        guard clipboardSession != nil else {
            clipboardMessage = "Not ready."
            render()
            return
        }

        let now = Date()
        clipboardTimerTick = now
        temporaryClipboardSharingExpiresAt = now.addingTimeInterval(30)
        clipboardSharingEnabled = true
        updateClipboardSharing(enabled: true)
        clipboardMessage = "Temporary sharing enabled."
        render()
    }

    private func expireTemporaryClipboardSharingIfNeeded(now: Date = Date()) {
        guard let temporaryClipboardSharingExpiresAt,
              now >= temporaryClipboardSharingExpiresAt
        else {
            return
        }

        self.temporaryClipboardSharingExpiresAt = nil
        guard clipboardSharingEnabled else {
            return
        }

        clipboardSharingEnabled = false
        updateClipboardSharing(enabled: false)
        clipboardMessage = "Temporary sharing ended."
    }

    private func publishPasteboardIfChanged(force: Bool = false) {
        guard clipboardSharingEnabled else {
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }
        guard let clipboardSession else {
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }

        let pasteboard = NSPasteboard.general
        let nextChangeCount = pasteboard.changeCount
        guard force || nextChangeCount != pasteboardChangeCount else {
            return
        }

        pasteboardChangeCount = nextChangeCount
        switch localClipboardPayload(from: pasteboard) {
        case let .text(text):
            clipboardSession.publishLocalUnicodeText(text)
            clipboardMessage = "Local text synced."
        case let .files(files):
            clipboardSession.publishLocalFiles(files)
            clipboardMessage = files.count == 1 ? "Local file synced." : "\(files.count) local files synced."
        case .empty:
            clipboardSession.publishLocalUnicodeText(nil)
            clipboardMessage = "Local clipboard has no text."
        case let .unsupported(message):
            clipboardSession.publishLocalUnicodeText(nil)
            clipboardMessage = message
        case let .ignored(message):
            clipboardMessage = message
        }
    }

    private func localClipboardPayload(from pasteboard: NSPasteboard) -> RDPRemoteSessionLocalClipboardPayload {
        let fileURLs = pasteboardFileURLs(from: pasteboard)
        if fileURLs.isEmpty == false {
            return localClipboardFiles(from: fileURLs)
        }
        if let text = pasteboard.string(forType: .string) {
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .ignored("Local text is too large to sync.")
            }
            return .text(text)
        }
        return .empty
    }

    private func pasteboardFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let pasteboardItems = pasteboard.pasteboardItems {
            for item in pasteboardItems {
                appendPasteboardFileURL(item.string(forType: .fileURL), to: &urls)
            }
        }
        if urls.isEmpty, pasteboard.types?.contains(.fileURL) == true {
            appendPasteboardFileURL(pasteboard.string(forType: .fileURL), to: &urls)
        }
        return urls
    }

    private func appendPasteboardFileURL(_ value: String?, to urls: inout [URL]) {
        guard let value,
              let url = URL(string: value),
              url.isFileURL,
              urls.contains(url) == false
        else {
            return
        }
        urls.append(url)
    }

    private func localClipboardFiles(from urls: [URL]) -> RDPRemoteSessionLocalClipboardPayload {
        var files: [RDPClipboardLocalFile] = []
        var totalByteCount = 0

        for url in urls {
            let fileURL = url.standardizedFileURL
            let fileName = fileURL.lastPathComponent
            guard fileName.isEmpty == false else {
                return .unsupported("Local file clipboard was not shared.")
            }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resourceValues.isRegularFile == true else {
                    return .unsupported("Local clipboard has non-file items; remote clipboard cleared.")
                }

                guard let byteCount = resourceValues.fileSize,
                      byteCount >= 0
                else {
                    return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
                }
                guard byteCount <= remoteSessionMaximumLocalClipboardFileBytes,
                      totalByteCount <= remoteSessionMaximumLocalClipboardFileBytes - byteCount
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }

                let contents = try Data(contentsOf: fileURL)
                guard contents.count <= remoteSessionMaximumLocalClipboardFileBytes,
                      totalByteCount <= remoteSessionMaximumLocalClipboardFileBytes - contents.count
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }
                totalByteCount += contents.count
                files.append(RDPClipboardLocalFile(fileName: fileName, contents: contents))
            } catch {
                return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
            }
        }

        return files.isEmpty ? .empty : .files(files)
    }

    private func applyRemoteClipboardText(_ text: String) {
        guard clipboardSharingEnabled else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
        clipboardMessage = "Remote text copied."
    }

    private func applyRemoteClipboardFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW) {
        guard clipboardSharingEnabled else {
            return
        }
        discardRemoteClipboardFileTransfer()
        do {
            let files = try descriptorList.remoteFileTransferFiles(
                maximumTotalByteCount: UInt64(remoteSessionMaximumLocalClipboardFileBytes)
            )
            let downloadDirectory = try makeRemoteClipboardDownloadDirectory()
            requestRemoteClipboardFileSize(RDPRemoteSessionRemoteClipboardFileTransfer(
                files: files,
                currentFileOffset: 0,
                streamID: nextRemoteClipboardTransferStreamID(),
                expectedByteCount: nil,
                requestedRange: false,
                totalExpectedByteCount: 0,
                downloadedFileURLs: [],
                downloadDirectory: downloadDirectory
            ))
        } catch let error as RDPClipboardRemoteFileTransferPlanningError {
            clipboardMessage = remoteClipboardFileTransferPlanningMessage(for: error)
        } catch {
            clipboardMessage = "Remote files could not be prepared."
        }
    }

    private func applyRemoteClipboardFileContentsResponse(_ response: RDPClipboardFileContentsResponse) {
        guard var transfer = remoteClipboardFileTransfer,
              transfer.streamID == response.streamID
        else {
            return
        }
        guard response.ok else {
            failRemoteClipboardFileTransfer(transfer, message: "Remote file transfer failed.")
            return
        }

        if transfer.requestedRange {
            applyRemoteClipboardFileData(response.data, transfer: transfer)
            return
        }

        do {
            let byteCount = try response.decodedFileSize()
            guard byteCount <= UInt64(remoteSessionMaximumLocalClipboardFileBytes),
                  transfer.totalExpectedByteCount <= UInt64(remoteSessionMaximumLocalClipboardFileBytes) - byteCount,
                  let requestedByteCount = UInt32(exactly: byteCount)
            else {
                failRemoteClipboardFileTransfer(transfer, message: "Remote files exceed 32 MiB.")
                return
            }

            guard let clipboardSession else {
                failRemoteClipboardFileTransfer(transfer, message: "Clipboard is not ready.")
                return
            }

            transfer.expectedByteCount = byteCount
            transfer.totalExpectedByteCount += byteCount
            if byteCount == 0 {
                remoteClipboardFileTransfer = transfer
                applyRemoteClipboardFileData(Data(), transfer: transfer)
                return
            }

            transfer.requestedRange = true
            remoteClipboardFileTransfer = transfer
            guard let currentFile = transfer.currentFile else {
                failRemoteClipboardFileTransfer(transfer, message: "Remote file transfer failed.")
                return
            }
            try clipboardSession.requestRemoteFileRange(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex,
                position: 0,
                requestedByteCount: requestedByteCount
            )
        } catch {
            failRemoteClipboardFileTransfer(transfer, message: "Remote file size request failed.")
        }
    }

    private func applyRemoteClipboardFileData(_ data: Data, transfer: RDPRemoteSessionRemoteClipboardFileTransfer) {
        guard let currentFile = transfer.currentFile,
              transfer.expectedByteCount == UInt64(data.count),
              data.count <= remoteSessionMaximumLocalClipboardFileBytes
        else {
            failRemoteClipboardFileTransfer(transfer, message: "Remote file transfer was incomplete.")
            return
        }

        do {
            var nextTransfer = transfer
            let fileURL = try writeRemoteClipboardFile(
                named: currentFile.fileName,
                contents: data,
                in: transfer.downloadDirectory
            )
            nextTransfer.downloadedFileURLs.append(fileURL)

            guard nextTransfer.currentFileOffset + 1 < nextTransfer.files.count else {
                finishRemoteClipboardFileTransfer(nextTransfer)
                return
            }

            nextTransfer.currentFileOffset += 1
            nextTransfer.streamID = nextRemoteClipboardTransferStreamID()
            nextTransfer.expectedByteCount = nil
            nextTransfer.requestedRange = false
            requestRemoteClipboardFileSize(nextTransfer)
        } catch {
            failRemoteClipboardFileTransfer(transfer, message: "Remote file could not be saved.")
        }
    }

    private func requestRemoteClipboardFileSize(_ transfer: RDPRemoteSessionRemoteClipboardFileTransfer) {
        guard let clipboardSession,
              let currentFile = transfer.currentFile
        else {
            failRemoteClipboardFileTransfer(transfer, message: "Clipboard is not ready.")
            return
        }

        remoteClipboardFileTransfer = transfer
        do {
            try clipboardSession.requestRemoteFileSize(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex
            )
            clipboardMessage = transfer.files.count == 1
                ? "Downloading remote file: \(currentFile.fileName)."
                : "Downloading remote files: \(transfer.currentFileOffset + 1) of \(transfer.files.count)."
        } catch {
            failRemoteClipboardFileTransfer(transfer, message: "Remote file request failed.")
        }
    }

    private func finishRemoteClipboardFileTransfer(_ transfer: RDPRemoteSessionRemoteClipboardFileTransfer) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(transfer.downloadedFileURLs.map { $0 as NSURL }) else {
            failRemoteClipboardFileTransfer(transfer, message: "Remote files could not be copied.")
            return
        }

        pasteboardChangeCount = pasteboard.changeCount
        remoteClipboardFileTransfer = nil
        if transfer.downloadedFileURLs.count == 1,
           let fileName = transfer.files.first?.fileName
        {
            clipboardMessage = "Remote file copied: \(fileName)."
        } else {
            clipboardMessage = "\(transfer.downloadedFileURLs.count) remote files copied."
        }
    }

    private func failRemoteClipboardFileTransfer(
        _ transfer: RDPRemoteSessionRemoteClipboardFileTransfer?,
        message: String
    ) {
        if let downloadDirectory = transfer?.downloadDirectory {
            try? FileManager.default.removeItem(at: downloadDirectory)
            if remoteClipboardDownloadDirectory == downloadDirectory {
                remoteClipboardDownloadDirectory = nil
            }
        }
        remoteClipboardFileTransfer = nil
        clipboardMessage = message
    }

    private func remoteClipboardFileTransferPlanningMessage(
        for error: RDPClipboardRemoteFileTransferPlanningError
    ) -> String {
        switch error {
        case .emptyFileList:
            "Remote file clipboard is empty."
        case .containsOnlyDirectories:
            "Remote clipboard has folders; file copy is not ready."
        case .invalidFileIndex:
            "Remote file index is not valid."
        case .totalByteLimitExceeded:
            "Remote files exceed 32 MiB."
        }
    }

    private func discardRemoteClipboardFileTransfer() {
        guard let transfer = remoteClipboardFileTransfer else {
            return
        }
        try? FileManager.default.removeItem(at: transfer.downloadDirectory)
        if remoteClipboardDownloadDirectory == transfer.downloadDirectory {
            remoteClipboardDownloadDirectory = nil
        }
        remoteClipboardFileTransfer = nil
    }

    private func makeRemoteClipboardDownloadDirectory() throws -> URL {
        let fileManager = FileManager.default
        if let remoteClipboardDownloadDirectory {
            try? fileManager.removeItem(at: remoteClipboardDownloadDirectory)
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RDPClientRemoteClipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        remoteClipboardDownloadDirectory = directory
        return directory
    }

    private func writeRemoteClipboardFile(
        named fileName: String,
        contents: Data,
        in directory: URL
    ) throws -> URL {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try contents.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func nextRemoteClipboardTransferStreamID() -> UInt32 {
        let streamID = nextRemoteClipboardStreamID
        nextRemoteClipboardStreamID = streamID == UInt32.max ? 1 : streamID + 1
        return streamID
    }

    private func updateClipboardSharing(enabled: Bool) {
        guard enabled else {
            temporaryClipboardSharingExpiresAt = nil
            discardRemoteClipboardFileTransfer()
            clipboardSession?.publishLocalUnicodeText(nil)
            clipboardMessage = "Disabled."
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }
        clipboardMessage = clipboardSession == nil ? nil : "Ready."
        publishPasteboardIfChanged(force: true)
    }

    private func trustCurrentCertificate() {
        guard let key = currentCertificateTrustKey() else {
            certificateTrustMessage = "No server certificate fingerprint is available."
            render()
            return
        }
        trustedCertificateStore.trust(key)
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
        return RDPServerCertificateTrustKey(host: target.host, port: target.port, sha256: certificateSHA256)
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

    private func loadRememberedPasswordIfAvailable() {
        guard !isConnecting,
              let key = currentCredentialKey()
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
            rememberPassword = true
            password = savedPassword
            keychainMessage = "Password loaded from Keychain."
        } catch {
            hasRememberedPassword = false
            keychainMessage = String(describing: error)
        }
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

    private func makeClientLicenseKey(
        host: String,
        port: UInt16,
        username: String,
        domain: String
    ) -> ClientLicenseStoreKey {
        ClientLicenseStoreKey(identity: RDPConnectionIdentity(
            host: host,
            port: port,
            username: username,
            domain: domain
        ))
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

    private var clipboardStatusMessage: String {
        guard clipboardSharingEnabled else {
            return "Disabled."
        }
        return clipboardMessage ?? (clipboardSession == nil ? "Not ready." : "Ready.")
    }

    private var audioStatusMessage: String {
        guard audioPlaybackEnabled else {
            return "Off."
        }
        return audioMessage ?? "Requested on connect."
    }

    private var temporaryClipboardSharingButtonTitle: String {
        guard let remainingSeconds = temporaryClipboardSharingRemainingSeconds else {
            return "Share for 30s"
        }
        return "Sharing \(remainingSeconds)s"
    }

    private var temporaryClipboardSharingRemainingSeconds: Int? {
        guard let temporaryClipboardSharingExpiresAt else {
            return nil
        }
        let remainingSeconds = temporaryClipboardSharingExpiresAt.timeIntervalSince(clipboardTimerTick)
        return max(0, Int(ceil(remainingSeconds)))
    }

    private func toggleSessionControls() {
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
            scheduleAutoDisplaySizeUpdate(force: true)
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
        clipboardSharingEnabled = sender.state == .on
        updateClipboardSharing(enabled: clipboardSharingEnabled)
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
        syncStateFromFields()
        startPreflight()
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

@MainActor
protocol RDPSessionCommandHandling: AnyObject {
    var rdpSessionControlsVisible: Bool { get }
    var rdpStartSessionTitle: String { get }
    var rdpCanStartSession: Bool { get }
    var rdpCanCancelSession: Bool { get }
    var rdpCanSyncClipboard: Bool { get }
    var rdpCanStartTemporaryClipboardSharing: Bool { get }

    func rdpToggleSessionControls()
    func rdpStartSession()
    func rdpCancelSession()
    func rdpOpenDiagnostics()
    func rdpSyncClipboard()
    func rdpStartTemporaryClipboardSharing()
}

extension RDPRemoteSessionViewController: RDPSessionCommandHandling {
    var rdpSessionControlsVisible: Bool {
        controlsVisible
    }

    var rdpStartSessionTitle: String {
        connectButtonTitle
    }

    var rdpCanStartSession: Bool {
        canStartConnection
    }

    var rdpCanCancelSession: Bool {
        isConnecting
    }

    var rdpCanSyncClipboard: Bool {
        clipboardSharingEnabled && clipboardSession != nil
    }

    var rdpCanStartTemporaryClipboardSharing: Bool {
        clipboardSession != nil
    }

    func rdpToggleSessionControls() {
        toggleSessionControls()
    }

    func rdpStartSession() {
        syncStateFromFields()
        startPreflight()
    }

    func rdpCancelSession() {
        cancelConnection()
    }

    func rdpOpenDiagnostics() {
        openDiagnosticsWindow()
    }

    func rdpSyncClipboard() {
        syncClipboardNow()
    }

    func rdpStartTemporaryClipboardSharing() {
        startTemporaryClipboardSharing()
    }
}

private final class RDPRemoteSessionMainActorSink: @unchecked Sendable {
    weak var controller: RDPRemoteSessionViewController?
    let connectionID: UUID

    init(controller: RDPRemoteSessionViewController, connectionID: UUID) {
        self.controller = controller
        self.connectionID = connectionID
    }

    func apply(_ operation: @escaping @MainActor (RDPRemoteSessionViewController) -> Void) {
        Task { @MainActor [weak self] in
            guard let self,
                  let controller,
                  controller.acceptsConnectionEvent(id: connectionID)
            else {
                return
            }
            operation(controller)
        }
    }
}

private enum RDPRemoteSessionLocalClipboardPayload: Equatable {
    case text(String)
    case files([RDPClipboardLocalFile])
    case empty
    case unsupported(String)
    case ignored(String)
}

private struct RDPRemoteSessionRemoteClipboardFileTransfer: Equatable {
    var files: [RDPClipboardRemoteFileTransferFile]
    var currentFileOffset: Int
    var streamID: UInt32
    var expectedByteCount: UInt64?
    var requestedRange: Bool
    var totalExpectedByteCount: UInt64
    var downloadedFileURLs: [URL]
    var downloadDirectory: URL

    var currentFile: RDPClipboardRemoteFileTransferFile? {
        guard files.indices.contains(currentFileOffset) else {
            return nil
        }
        return files[currentFileOffset]
    }
}

private struct RDPRemoteSessionAppKitStatus {
    var text: String
    var systemImage: String
    var color: NSColor
    var emptyMessage: String

    init(
        reportStatus: String?,
        sessionEndReason: RDPSessionEndReason?,
        hasPresentedFrame: Bool,
        isConnecting: Bool
    ) {
        if hasPresentedFrame, isConnecting {
            text = "Receiving"
            systemImage = "play.circle"
            color = .systemGreen
            emptyMessage = "No Active Session"
        } else if isConnecting {
            text = "Connecting"
            systemImage = "bolt.horizontal"
            color = .controlAccentColor
            emptyMessage = "No Active Session"
        } else if let sessionEndReason {
            text = sessionEndReason.statusText
            systemImage = sessionEndReason.systemImage
            color = sessionEndReason.kind == .failed ? .systemRed : .secondaryLabelColor
            emptyMessage = sessionEndReason.title
        } else if reportStatus == "success" {
            text = "Connected"
            systemImage = "checkmark.circle"
            color = .systemGreen
            emptyMessage = "No Active Session"
        } else if reportStatus == "failure" {
            text = "Failed"
            systemImage = "exclamationmark.triangle"
            color = .systemRed
            emptyMessage = "Connection Failed"
        } else {
            text = "Not Connected"
            systemImage = "circle"
            color = .secondaryLabelColor
            emptyMessage = "No Active Session"
        }
    }
}

private enum RDPAppKitNoticeAction {
    case trustCertificate
    case forgetCertificate
}

private struct RDPAppKitNoticeState {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: RDPAppKitNoticeAction?
}

private final class RDPRemoteSessionAppKitDetailView: NSView {
    let displayView: RemoteDesktopSampleBufferNSView
    var onToggleControls: (() -> Void)?
    var onConnect: (() -> Void)?
    var onCancel: (() -> Void)?
    var onOpenDiagnostics: (() -> Void)?
    var onTrustCertificate: (() -> Void)?
    var onForgetCertificate: (() -> Void)?
    var onSurfaceSizeChange: ((CGSize) -> Void)? {
        didSet {
            canvasView.onSurfaceSizeChange = onSurfaceSizeChange
        }
    }

    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Remote Desktop")
    private let statusImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let toggleControlsButton = NSButton(title: "", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let diagnosticsButton = NSButton(title: "Stats for Nerds", target: nil, action: nil)
    private let canvasView = RemoteDesktopCanvasNSView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let noticesStack = NSStackView()
    private let formErrorNotice = RDPAppKitNoticeView()
    private let sessionNotice = RDPAppKitNoticeView()
    private let certificateNotice = RDPAppKitNoticeView()
    private let decodeNotice = RDPAppKitNoticeView()
    private var statusSystemImageName: String?

    override init(frame frameRect: NSRect) {
        displayView = canvasView.displayView
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        displayView = canvasView.displayView
        super.init(coder: coder)
        configure()
    }

    func render(
        frame: RDPFrameMetadata?,
        frameCount: Int,
        hasPresentedFrame: Bool,
        status: RDPRemoteSessionAppKitStatus,
        decodeError: String?,
        metricsSummary: String?,
        graphicsPathSummary: String?,
        inputSession: RDPInputSession?,
        isConnecting: Bool,
        formError: String?,
        sessionEndReason: RDPSessionEndReason?,
        certificateNotice certificateNoticeState: RDPAppKitNoticeState?,
        controlsVisible: Bool,
        connectTitle: String,
        canConnect: Bool,
        canCancel: Bool
    ) {
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.color
        if statusSystemImageName != status.systemImage {
            statusSystemImageName = status.systemImage
            statusImageView.image = NSImage(
                systemSymbolName: status.systemImage,
                accessibilityDescription: status.text
            )
        }
        statusImageView.contentTintColor = status.color
        toggleControlsButton.title = controlsVisible ? "Hide Controls" : "Show Controls"
        connectButton.title = connectTitle
        connectButton.isEnabled = canConnect
        cancelButton.isEnabled = canCancel

        canvasView.update(
            frame: frame,
            hasPresentedFrame: hasPresentedFrame,
            emptyMessage: status.emptyMessage,
            inputSession: inputSession,
            isConnecting: isConnecting
        )

        footerLabel.stringValue = footerText(
            frame: frame,
            frameCount: frameCount,
            metricsSummary: metricsSummary,
            graphicsPathSummary: graphicsPathSummary
        )
        footerLabel.isHidden = footerLabel.stringValue.isEmpty

        formErrorNotice.render(
            formError.map {
                RDPAppKitNoticeState(
                    title: "Input",
                    message: $0,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            },
            actionHandler: nil
        )
        sessionNotice.render(
            sessionEndReason.map {
                RDPAppKitNoticeState(
                    title: $0.title,
                    message: $0.message,
                    systemImage: $0.systemImage,
                    actionTitle: nil,
                    action: nil
                )
            },
            actionHandler: nil
        )
        certificateNotice.render(certificateNoticeState) { [weak self] action in
            switch action {
            case .trustCertificate:
                self?.onTrustCertificate?()
            case .forgetCertificate:
                self?.onForgetCertificate?()
            }
        }
        decodeNotice.render(
            decodeError.map {
                RDPAppKitNoticeState(
                    title: "VideoToolbox",
                    message: $0,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            },
            actionHandler: nil
        )
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.addArrangedSubview(titleLabel)
        topRow.addArrangedSubview(spacer())
        topRow.addArrangedSubview(statusImageView)
        topRow.addArrangedSubview(statusLabel)

        configureButton(toggleControlsButton, action: #selector(toggleControlsPressed(_:)))
        configureButton(connectButton, action: #selector(connectPressed(_:)))
        configureButton(cancelButton, action: #selector(cancelPressed(_:)))
        configureButton(diagnosticsButton, action: #selector(diagnosticsPressed(_:)))
        topRow.addArrangedSubview(toggleControlsButton)
        topRow.addArrangedSubview(connectButton)
        topRow.addArrangedSubview(cancelButton)
        topRow.addArrangedSubview(diagnosticsButton)

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvasView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        footerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 2

        noticesStack.orientation = .vertical
        noticesStack.alignment = .leading
        noticesStack.spacing = 8
        for notice in [formErrorNotice, sessionNotice, certificateNotice, decodeNotice] {
            notice.translatesAutoresizingMaskIntoConstraints = false
            noticesStack.addArrangedSubview(notice)
        }

        stack.addArrangedSubview(topRow)
        stack.addArrangedSubview(canvasView)
        stack.addArrangedSubview(footerLabel)
        stack.addArrangedSubview(noticesStack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvasView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            canvasView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            noticesStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func footerText(
        frame: RDPFrameMetadata?,
        frameCount: Int,
        metricsSummary: String?,
        graphicsPathSummary: String?
    ) -> String {
        var parts: [String] = []
        if let graphicsPathSummary {
            parts.append(graphicsPathSummary)
        }
        if let frame {
            parts.append(frameLabel(frame))
        }
        if frameCount > 0 {
            parts.append("\(frameCount) decoded")
        }
        if let metricsSummary {
            parts.append(metricsSummary)
        }
        return parts.joined(separator: "    ")
    }

    private func frameLabel(_ frame: RDPFrameMetadata) -> String {
        let codecDescription = frame.contentKind == .video
            ? "\(frame.codecName)/\(frame.videoCodec.displayName)"
            : frame.codecName
        var parts = [
            codecDescription,
            "\(frame.width)x\(frame.height)",
            "\(frame.payloadByteCount) bytes",
        ]
        if let frameID = frame.frameID {
            parts.append("frame \(frameID)")
        }
        return parts.joined(separator: " - ")
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func toggleControlsPressed(_: NSButton) {
        onToggleControls?()
    }

    @objc private func connectPressed(_: NSButton) {
        onConnect?()
    }

    @objc private func cancelPressed(_: NSButton) {
        onCancel?()
    }

    @objc private func diagnosticsPressed(_: NSButton) {
        onOpenDiagnostics?()
    }
}

private final class RDPAppKitNoticeView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var action: RDPAppKitNoticeAction?
    private var actionHandler: ((RDPAppKitNoticeAction) -> Void)?
    private var systemImageName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(
        _ state: RDPAppKitNoticeState?,
        actionHandler: ((RDPAppKitNoticeAction) -> Void)?
    ) {
        guard let state else {
            isHidden = true
            action = nil
            self.actionHandler = nil
            systemImageName = nil
            return
        }
        isHidden = false
        if systemImageName != state.systemImage {
            systemImageName = state.systemImage
            imageView.image = NSImage(
                systemSymbolName: state.systemImage,
                accessibilityDescription: state.title
            )
        }
        imageView.contentTintColor = .secondaryLabelColor
        titleLabel.stringValue = state.title
        messageLabel.stringValue = state.message
        actionButton.isHidden = state.actionTitle == nil || state.action == nil
        actionButton.title = state.actionTitle ?? ""
        action = state.action
        self.actionHandler = actionHandler
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        imageView.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(messageLabel)

        actionButton.target = self
        actionButton.action = #selector(actionPressed(_:))
        actionButton.bezelStyle = .rounded

        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(textStack)
        stack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    @objc private func actionPressed(_: NSButton) {
        guard let action else {
            return
        }
        actionHandler?(action)
    }
}

private final class RDPFramePresentationClockNSView: NSView {
    private var displayLink: CADisplayLink?
    private weak var observedWindow: NSWindow?
    private var isEnabled = false
    private var lastPublishedState = RDPFramePacingState()
    private var onFrame: ((CADisplayLink) -> Void)?
    private var onTimingChange: ((RDPFramePacingState) -> Void)?

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
            stopObservingWindow()
            onFrame = nil
            onTimingChange = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDisplayLink(for: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDisplayLink()
            stopObservingWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishTimingIfChanged(force: true)
    }

    func configure(
        isEnabled: Bool,
        onFrame: @escaping (CADisplayLink) -> Void,
        onTimingChange: @escaping (RDPFramePacingState) -> Void
    ) {
        self.isEnabled = isEnabled
        self.onFrame = onFrame
        self.onTimingChange = onTimingChange
        configureDisplayLink(for: window)
        displayLink?.isPaused = !isEnabled
        publishTimingIfChanged()
    }

    private func configureDisplayLink(for nextWindow: NSWindow?) {
        guard observedWindow !== nextWindow || (nextWindow != nil && displayLink == nil) else {
            return
        }

        stopDisplayLink()
        stopObservingWindow()
        observedWindow = nextWindow

        guard let nextWindow else {
            publishTimingIfChanged(force: true)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nextWindow
        )

        let nextDisplayLink = nextWindow.displayLink(
            target: self,
            selector: #selector(displayLinkFired(_:))
        )
        nextDisplayLink.isPaused = !isEnabled
        nextDisplayLink.add(to: .main, forMode: .common)
        displayLink = nextDisplayLink
        publishTimingIfChanged(force: true)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func stopObservingWindow() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: observedWindow
            )
        }
        observedWindow = nil
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        publishTimingIfChanged()
        onFrame?(displayLink)
    }

    @objc private func windowDidChangeScreen(_: Notification) {
        publishTimingIfChanged(force: true)
    }

    private func publishTimingIfChanged(force: Bool = false) {
        let nextState = RDPFramePacingState.current(
            window: observedWindow,
            displayLink: displayLink,
            isPaused: displayLink?.isPaused ?? true
        )
        guard force || nextState != lastPublishedState else {
            return
        }
        lastPublishedState = nextState
        DispatchQueue.main.async { [weak self] in
            self?.onTimingChange?(nextState)
        }
    }
}

private func appKitCompactViewerMetricsSummary(
    metrics: RDPRenderMetrics,
    framePacing: RDPFramePacingState
) -> String? {
    var parts: [String] = []
    let framesPerSecond = metrics.rollingFramesPerSecond ?? metrics.averageFramesPerSecond
    if let framesPerSecond {
        parts.append(appKitMetricFramesPerSecond(framesPerSecond))
    }
    if let lastDecodeMilliseconds = metrics.lastDecodeMilliseconds {
        parts.append("decode \(appKitMetricMilliseconds(lastDecodeMilliseconds))")
    }
    if let wireMegabitsPerSecond = metrics.rollingWireMegabitsPerSecond {
        parts.append("rx \(appKitMetricMegabitsPerSecond(wireMegabitsPerSecond))")
    }
    if let displayLinkFramesPerSecond = framePacing.displayLinkFramesPerSecond {
        parts.append(appKitMetricHertz(displayLinkFramesPerSecond))
    }
    guard parts.isEmpty == false else {
        return nil
    }
    return parts.joined(separator: " - ")
}

private func appKitMetricMilliseconds(_ value: Double?) -> String {
    guard let value else {
        return "none"
    }
    if value < 1 {
        return String(format: "%.2f ms", value)
    }
    return String(format: "%.1f ms", value)
}

private func appKitMetricFramesPerSecond(_ value: Double?) -> String {
    guard let value else {
        return "none"
    }
    return String(format: "%.1f fps", value)
}

private func appKitMetricHertz(_ value: Double?) -> String {
    guard let value else {
        return "none"
    }
    if value.rounded() == value {
        return String(format: "%.0f Hz", value)
    }
    return String(format: "%.1f Hz", value)
}

private func appKitMetricMegabitsPerSecond(_ value: Double?) -> String {
    guard let value else {
        return "none"
    }
    if value < 1 {
        return String(format: "%.2f Mbps", value)
    }
    return String(format: "%.1f Mbps", value)
}
