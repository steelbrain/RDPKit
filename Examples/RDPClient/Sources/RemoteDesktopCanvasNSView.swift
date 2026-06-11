import AppKit
import RDPKit

final class RemoteDesktopCanvasNSView: NSView {
    let displayView = RemoteDesktopSampleBufferNSView()
    private let inputView = RemoteInputCaptureNSView()
    private let progressIndicator = NSProgressIndicator()
    private let emptyStack = NSStackView()
    private let emptyImageView = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var lastReportedSize = CGSize.zero

    var onSurfaceSizeChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        displayView.frame = bounds
        inputView.frame = bounds

        let progressSize = NSSize(width: 32, height: 32)
        progressIndicator.frame = NSRect(
            x: bounds.midX - progressSize.width / 2,
            y: bounds.midY - progressSize.height / 2,
            width: progressSize.width,
            height: progressSize.height
        )

        let emptySize = emptyStack.fittingSize
        emptyStack.frame = NSRect(
            x: bounds.midX - emptySize.width / 2,
            y: bounds.midY - emptySize.height / 2,
            width: emptySize.width,
            height: emptySize.height
        )
        reportSurfaceSizeIfNeeded()
    }

    func update(
        frame: RDPFrameMetadata?,
        hasPresentedFrame: Bool,
        emptyMessage: String,
        inputSession: RDPInputSession?,
        isConnecting: Bool
    ) {
        let shouldShowDesktop = frame != nil && hasPresentedFrame
        displayView.isHidden = !shouldShowDesktop
        inputView.isHidden = !shouldShowDesktop
        inputView.rdpFrame = frame
        inputView.inputSession = shouldShowDesktop ? inputSession : nil

        let shouldShowProgress = !shouldShowDesktop && isConnecting
        progressIndicator.isHidden = !shouldShowProgress
        if shouldShowProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }

        emptyLabel.stringValue = emptyMessage
        emptyStack.isHidden = shouldShowDesktop || isConnecting
        needsLayout = true
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        displayView.autoresizingMask = [.width, .height]
        inputView.autoresizingMask = [.width, .height]
        addSubview(displayView)
        addSubview(inputView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .large
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true
        addSubview(progressIndicator)

        emptyImageView.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        emptyImageView.contentTintColor = .secondaryLabelColor
        emptyImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        emptyImageView.imageScaling = .scaleProportionallyUpOrDown
        emptyImageView.setContentHuggingPriority(.required, for: .vertical)

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10
        emptyStack.addArrangedSubview(emptyImageView)
        emptyStack.addArrangedSubview(emptyLabel)
        addSubview(emptyStack)
    }

    private func reportSurfaceSizeIfNeeded() {
        let nextSize = bounds.size
        guard nextSize.width > 0,
              nextSize.height > 0,
              nextSize != lastReportedSize
        else {
            return
        }

        lastReportedSize = nextSize
        DispatchQueue.main.async { [weak self] in
            guard self?.lastReportedSize == nextSize else {
                return
            }
            self?.onSurfaceSizeChange?(nextSize)
        }
    }
}
