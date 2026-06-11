import CoreGraphics
import Foundation

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

    public var displayLinkFramesPerSecond: Double? {
        guard let displayLinkDuration,
              displayLinkDuration > 0
        else {
            return nil
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
