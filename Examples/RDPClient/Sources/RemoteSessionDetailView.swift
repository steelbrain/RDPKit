import AppKit
import RDPKit

struct RDPRemoteSessionAppKitStatus {
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

enum RDPAppKitNoticeAction {
    case trustCertificate
    case forgetCertificate
}

struct RDPAppKitNoticeState {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: RDPAppKitNoticeAction?
}

final class RDPRemoteSessionAppKitDetailView: NSView {
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

final class RDPAppKitNoticeView: NSView {
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
