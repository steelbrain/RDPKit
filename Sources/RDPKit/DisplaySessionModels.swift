import CoreGraphics
import Foundation

public struct RDPDisplayScaleFactors: Equatable, Sendable {
    public var desktopScaleFactor: UInt32
    public var deviceScaleFactor: UInt32

    public init(desktopScaleFactor: UInt32, deviceScaleFactor: UInt32) {
        self.desktopScaleFactor = desktopScaleFactor
        self.deviceScaleFactor = deviceScaleFactor
    }

    public init(backingScaleFactor: CGFloat) {
        let finiteScale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        let desktopScaleFactor = UInt32(
            min(500, max(100, Int((finiteScale * 100).rounded())))
        )
        self.desktopScaleFactor = desktopScaleFactor
        deviceScaleFactor = Self.nearestDeviceScaleFactor(for: desktopScaleFactor)
    }

    private static func nearestDeviceScaleFactor(for desktopScaleFactor: UInt32) -> UInt32 {
        if desktopScaleFactor < 120 {
            return 100
        }
        if desktopScaleFactor < 160 {
            return 140
        }
        return 180
    }
}

public struct RDPDisplayRequest: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var scaleFactors: RDPDisplayScaleFactors

    public init(width: UInt32, height: UInt32, scaleFactors: RDPDisplayScaleFactors) {
        let layout = RDPDisplayControlMonitorLayout.singlePrimary(
            width: width,
            height: height,
            desktopScaleFactor: scaleFactors.desktopScaleFactor,
            deviceScaleFactor: scaleFactors.deviceScaleFactor
        )
        self.width = layout.width
        self.height = layout.height
        self.scaleFactors = RDPDisplayScaleFactors(
            desktopScaleFactor: layout.desktopScaleFactor,
            deviceScaleFactor: layout.deviceScaleFactor
        )
    }

    public init(pointSize: CGSize, backingScaleFactor: CGFloat) {
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        self.init(
            width: Self.clampedWidth(Self.scaledDimension(pointSize.width, backingScaleFactor: scale)),
            height: Self.clampedHeight(Self.scaledDimension(pointSize.height, backingScaleFactor: scale)),
            scaleFactors: RDPDisplayScaleFactors(backingScaleFactor: scale)
        )
    }

    var monitorLayoutPDU: RDPDisplayControlMonitorLayoutPDU {
        .singlePrimary(
            width: width,
            height: height,
            desktopScaleFactor: scaleFactors.desktopScaleFactor,
            deviceScaleFactor: scaleFactors.deviceScaleFactor
        )
    }

    public var label: String {
        "\(width)x\(height), RDP scale \(scaleFactors.desktopScaleFactor)%/\(scaleFactors.deviceScaleFactor)%"
    }

    private static func scaledDimension(_ pointDimension: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        guard pointDimension.isFinite, pointDimension > 0 else {
            return 0
        }
        let scaledDimension = pointDimension * backingScaleFactor
        return scaledDimension.isFinite ? scaledDimension : CGFloat(UInt32.max)
    }

    private static func clampedWidth(_ value: CGFloat) -> UInt32 {
        let rounded = Int(value.rounded())
        let clamped = min(8192, max(640, rounded))
        return UInt32(clamped.isMultiple(of: 2) ? clamped : clamped - 1)
    }

    private static func clampedHeight(_ value: CGFloat) -> UInt32 {
        UInt32(min(8192, max(480, Int(value.rounded()))))
    }
}

public struct RDPViewerPixelSize: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var backingScaleFactor: CGFloat

    public init(pointSize: CGSize, backingScaleFactor: CGFloat) {
        let displayRequest = RDPDisplayRequest(pointSize: pointSize, backingScaleFactor: backingScaleFactor)
        self.backingScaleFactor = backingScaleFactor
        width = displayRequest.width
        height = displayRequest.height
    }

    public var label: String {
        "\(width)x\(height) view @\(String(format: "%.1fx", backingScaleFactor)), RDP scale "
            + "\(displayScaleFactors.desktopScaleFactor)%/\(displayScaleFactors.deviceScaleFactor)%"
    }

    public var desktopWidthText: String {
        String(width)
    }

    public var desktopHeightText: String {
        String(height)
    }

    public var displayScaleFactors: RDPDisplayScaleFactors {
        RDPDisplayScaleFactors(backingScaleFactor: backingScaleFactor)
    }

    public var displayRequest: RDPDisplayRequest {
        RDPDisplayRequest(width: width, height: height, scaleFactors: displayScaleFactors)
    }
}

public struct RDPFrameMetadata: Equatable, Sendable {
    public var frameID: UInt32?
    public var surfaceID: UInt16
    public var codecID: UInt16
    public var codecName: String
    public var contentKind: RDPGraphicsFrameContentKind
    public var videoCodec: RDPVideoCodec
    public var pixelFormat: UInt8
    public var width: UInt16
    public var height: UInt16
    public var videoByteCount: Int
    public var bitmapByteCount: Int
    public var videoNalUnitTypes: [UInt8]
    public var regionCount: Int

    public var payloadByteCount: Int {
        contentKind == .bitmap ? bitmapByteCount : videoByteCount
    }

    public init(_ frame: RDPGraphicsFrameSnapshot) {
        frameID = frame.frameID
        surfaceID = frame.surfaceID
        codecID = frame.codecID
        codecName = frame.codecName
        contentKind = frame.contentKind
        videoCodec = frame.videoCodec
        pixelFormat = frame.pixelFormat
        width = frame.width
        height = frame.height
        videoByteCount = frame.videoByteCount
        bitmapByteCount = frame.bitmapByteCount
        videoNalUnitTypes = frame.videoNalUnitTypes
        regionCount = frame.regionRects.count
    }
}
