import AppKit
import QuartzCore

struct RDPFramePacingState: Equatable, Sendable {
    var screenName: String
    var backingScaleFactor: CGFloat?
    var maximumFramesPerSecond: Int?
    var minimumRefreshInterval: TimeInterval?
    var maximumRefreshInterval: TimeInterval?
    var displayUpdateGranularity: TimeInterval?
    var displayLinkDuration: TimeInterval?
    var hasDisplayLink: Bool
    var isDisplayLinkPaused: Bool

    init(
        screenName: String = "No window",
        backingScaleFactor: CGFloat? = nil,
        maximumFramesPerSecond: Int? = nil,
        minimumRefreshInterval: TimeInterval? = nil,
        maximumRefreshInterval: TimeInterval? = nil,
        displayUpdateGranularity: TimeInterval? = nil,
        displayLinkDuration: TimeInterval? = nil,
        hasDisplayLink: Bool = false,
        isDisplayLinkPaused: Bool = true
    ) {
        self.screenName = screenName
        self.backingScaleFactor = backingScaleFactor
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshInterval = maximumRefreshInterval
        self.displayUpdateGranularity = displayUpdateGranularity
        self.displayLinkDuration = Self.normalizedDisplayLinkDuration(displayLinkDuration)
        self.hasDisplayLink = hasDisplayLink
        self.isDisplayLinkPaused = isDisplayLinkPaused
    }

    var displayLinkFramesPerSecond: Double? {
        guard let displayLinkDuration,
              displayLinkDuration > 0
        else {
            return nil
        }
        return 1 / displayLinkDuration
    }

    var maximumRefreshRate: Double? {
        if let maximumFramesPerSecond {
            return Double(maximumFramesPerSecond)
        }
        guard let minimumRefreshInterval,
              minimumRefreshInterval > 0
        else {
            return nil
        }
        return 1 / minimumRefreshInterval
    }

    var clockState: String {
        guard hasDisplayLink else {
            return "not attached"
        }
        return isDisplayLinkPaused ? "paused" : "window display link"
    }

    func updatingDisplayLinkDuration(_ duration: TimeInterval) -> RDPFramePacingState {
        var copy = self
        copy.displayLinkDuration = Self.normalizedDisplayLinkDuration(duration)
        copy.hasDisplayLink = true
        copy.isDisplayLinkPaused = false
        return copy
    }

    private static func normalizedDisplayLinkDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }

        let framesPerSecond = (1 / duration).rounded()
        guard framesPerSecond > 0 else {
            return nil
        }
        return 1 / framesPerSecond
    }
}

extension RDPFramePacingState {
    @MainActor
    static func current(window: NSWindow?, displayLink: CADisplayLink?, isPaused: Bool) -> RDPFramePacingState {
        guard let window,
              let screen = window.screen
        else {
            return RDPFramePacingState(
                screenName: "No window",
                backingScaleFactor: window?.backingScaleFactor,
                displayLinkDuration: displayLink?.duration,
                hasDisplayLink: displayLink != nil,
                isDisplayLinkPaused: isPaused
            )
        }

        return RDPFramePacingState(
            screenName: screen.localizedName,
            backingScaleFactor: window.backingScaleFactor,
            maximumFramesPerSecond: screen.maximumFramesPerSecond,
            minimumRefreshInterval: screen.minimumRefreshInterval,
            maximumRefreshInterval: screen.maximumRefreshInterval,
            displayUpdateGranularity: screen.displayUpdateGranularity,
            displayLinkDuration: displayLink?.duration,
            hasDisplayLink: displayLink != nil,
            isDisplayLinkPaused: isPaused
        )
    }
}
