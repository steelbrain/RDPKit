#if os(macOS)
import AppKit

/// The screen a session's window is on and the display clock pacing its frames, for
/// diagnostics: what `RDPFramePresentationClock` publishes.
public struct RDPFramePacingState: Equatable, Sendable {
    public var screenName: String
    public var backingScaleFactor: CGFloat?
    public var maximumFramesPerSecond: Int?
    public var minimumRefreshInterval: TimeInterval?
    public var maximumRefreshInterval: TimeInterval?
    public var displayUpdateGranularity: TimeInterval?
    public var displayLinkDuration: TimeInterval?
    public var hasDisplayLink: Bool
    public var isDisplayLinkPaused: Bool

    public init(
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

    /// The display link's rate once it has fired on this screen. Until then its duration is 0
    /// or the previous screen's, and the screen's maximum refresh rate stands in.
    public var displayLinkFramesPerSecond: Double? {
        guard let displayLinkDuration,
              displayLinkDuration > 0
        else {
            return hasDisplayLink ? maximumRefreshRate : nil
        }
        return 1 / displayLinkDuration
    }

    public var maximumRefreshRate: Double? {
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

    public var clockState: String {
        guard hasDisplayLink else {
            return "not attached"
        }
        return isDisplayLinkPaused ? "paused" : "window display link"
    }

    public func updatingDisplayLinkDuration(_ duration: TimeInterval) -> RDPFramePacingState {
        var copy = self
        copy.displayLinkDuration = Self.normalizedDisplayLinkDuration(duration)
        copy.hasDisplayLink = true
        copy.isDisplayLinkPaused = false
        return copy
    }

    /// The same screen with the clock's state now, without reading the screen again.
    /// `displayLinkDuration` is nil until the display link has fired on this screen.
    public func updatingClock(displayLinkDuration: TimeInterval?, hasDisplayLink: Bool, isPaused: Bool) -> RDPFramePacingState {
        var copy = self
        copy.displayLinkDuration = Self.normalizedDisplayLinkDuration(displayLinkDuration)
        copy.hasDisplayLink = hasDisplayLink
        copy.isDisplayLinkPaused = isPaused
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
    /// `displayLinkDuration` is nil until the display link has fired on the window's screen.
    @MainActor
    public static func current(
        window: NSWindow?,
        displayLinkDuration: TimeInterval?,
        hasDisplayLink: Bool,
        isPaused: Bool
    ) -> RDPFramePacingState {
        guard let window,
              let screen = window.screen
        else {
            return RDPFramePacingState(
                screenName: "No window",
                backingScaleFactor: window?.backingScaleFactor,
                displayLinkDuration: displayLinkDuration,
                hasDisplayLink: hasDisplayLink,
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
            displayLinkDuration: displayLinkDuration,
            hasDisplayLink: hasDisplayLink,
            isDisplayLinkPaused: isPaused
        )
    }
}
#endif
