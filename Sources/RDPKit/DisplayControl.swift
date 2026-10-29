import Foundation
@preconcurrency import NIOCore

enum RDPDisplayControlChannel {
    static let name = "Microsoft::Windows::RDS::DisplayControl"
}

enum RDPDisplayControlPDUType {
    static let monitorLayout: UInt32 = 0x0000_0002
    static let caps: UInt32 = 0x0000_0005
}

enum RDPDisplayControlMonitorFlags {
    static let primary: UInt32 = 0x0000_0001
    static let supportedMask: UInt32 = primary
}

struct RDPDisplayControlHeader: Equatable, Sendable {
    var type: UInt32
    var length: UInt32

    static func parse(from cursor: inout ByteCursor) throws -> RDPDisplayControlHeader {
        try RDPDisplayControlHeader(
            type: cursor.readLittleEndianUInt32(),
            length: cursor.readLittleEndianUInt32()
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(type)
        data.appendLittleEndianUInt32(length)
        return data
    }
}

public struct RDPDisplayControlCapabilities: Encodable, Equatable, Sendable {
    public var maxNumMonitors: UInt32
    public var maxMonitorAreaFactorA: UInt32
    public var maxMonitorAreaFactorB: UInt32

    public init(
        maxNumMonitors: UInt32,
        maxMonitorAreaFactorA: UInt32,
        maxMonitorAreaFactorB: UInt32
    ) {
        self.maxNumMonitors = maxNumMonitors
        self.maxMonitorAreaFactorA = maxMonitorAreaFactorA
        self.maxMonitorAreaFactorB = maxMonitorAreaFactorB
    }
}

struct RDPDisplayControlCapsPDU: Equatable, Sendable {
    var capabilities: RDPDisplayControlCapabilities

    static func parseIfPresent(from data: Data) throws -> RDPDisplayControlCapsPDU? {
        guard data.count >= 8 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDisplayControlHeader.parse(from: &cursor)
        guard header.type == RDPDisplayControlPDUType.caps else {
            return nil
        }
        guard Int(header.length) == data.count,
              header.length == 20
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return try RDPDisplayControlCapsPDU(capabilities: RDPDisplayControlCapabilities(
            maxNumMonitors: cursor.readLittleEndianUInt32(),
            maxMonitorAreaFactorA: cursor.readLittleEndianUInt32(),
            maxMonitorAreaFactorB: cursor.readLittleEndianUInt32()
        ))
    }
}

public struct RDPDisplayControlMonitorLayout: Equatable, Sendable {
    public var flags: UInt32
    public var left: Int32
    public var top: Int32
    public var width: UInt32
    public var height: UInt32
    public var physicalWidth: UInt32
    public var physicalHeight: UInt32
    public var orientation: UInt32
    public var desktopScaleFactor: UInt32
    public var deviceScaleFactor: UInt32

    public init(
        flags: UInt32 = 0,
        left: Int32 = 0,
        top: Int32 = 0,
        width: UInt32,
        height: UInt32,
        physicalWidth: UInt32 = 0,
        physicalHeight: UInt32 = 0,
        orientation: UInt32 = 0,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) {
        self.flags = flags
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.orientation = orientation
        self.desktopScaleFactor = desktopScaleFactor
        self.deviceScaleFactor = deviceScaleFactor
    }

    /// Whether ``flags`` has DISPLAYCONTROL_MONITOR_PRIMARY: the primary monitor, whose top-left
    /// is 0,0.
    public var isPrimary: Bool {
        get {
            flags & RDPDisplayControlMonitorFlags.primary != 0
        }
        set {
            flags = newValue
                ? flags | RDPDisplayControlMonitorFlags.primary
                : flags & ~RDPDisplayControlMonitorFlags.primary
        }
    }

    public static func singlePrimary(
        width: UInt32,
        height: UInt32,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) -> RDPDisplayControlMonitorLayout {
        RDPDisplayControlMonitorLayout(
            flags: RDPDisplayControlMonitorFlags.primary,
            width: evenDisplayWidth(width),
            height: clampedDisplayDimension(height),
            desktopScaleFactor: clampedDesktopScaleFactor(desktopScaleFactor),
            deviceScaleFactor: nearestDeviceScaleFactor(deviceScaleFactor)
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        data.appendLittleEndianUInt32(UInt32(bitPattern: left))
        data.appendLittleEndianUInt32(UInt32(bitPattern: top))
        data.appendLittleEndianUInt32(width)
        data.appendLittleEndianUInt32(height)
        data.appendLittleEndianUInt32(physicalWidth)
        data.appendLittleEndianUInt32(physicalHeight)
        data.appendLittleEndianUInt32(orientation)
        data.appendLittleEndianUInt32(desktopScaleFactor)
        data.appendLittleEndianUInt32(deviceScaleFactor)
        return data
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPDisplayControlMonitorLayout {
        guard cursor.remaining >= 40 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return try RDPDisplayControlMonitorLayout(
            flags: cursor.readLittleEndianUInt32(),
            left: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            top: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            width: cursor.readLittleEndianUInt32(),
            height: cursor.readLittleEndianUInt32(),
            physicalWidth: cursor.readLittleEndianUInt32(),
            physicalHeight: cursor.readLittleEndianUInt32(),
            orientation: cursor.readLittleEndianUInt32(),
            desktopScaleFactor: cursor.readLittleEndianUInt32(),
            deviceScaleFactor: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPDisplayControlMonitorLayoutPDU: Equatable, Sendable {
    var monitors: [RDPDisplayControlMonitorLayout]

    init(monitors: [RDPDisplayControlMonitorLayout]) {
        precondition(monitors.isEmpty == false)
        self.monitors = monitors
    }

    static func singlePrimary(
        width: UInt32,
        height: UInt32,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) -> RDPDisplayControlMonitorLayoutPDU {
        RDPDisplayControlMonitorLayoutPDU(
            monitors: [
                .singlePrimary(
                    width: width,
                    height: height,
                    desktopScaleFactor: desktopScaleFactor,
                    deviceScaleFactor: deviceScaleFactor
                ),
            ]
        )
    }

    func encoded() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(40)
        body.appendLittleEndianUInt32(UInt32(monitors.count))
        for monitor in monitors {
            body.append(monitor.encoded())
        }

        let length = UInt32(8 + body.count)
        var data = RDPDisplayControlHeader(
            type: RDPDisplayControlPDUType.monitorLayout,
            length: length
        ).encoded()
        data.append(body)
        return data
    }

    static func parseIfPresent(from data: Data) throws -> RDPDisplayControlMonitorLayoutPDU? {
        guard data.count >= 8 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDisplayControlHeader.parse(from: &cursor)
        guard header.type == RDPDisplayControlPDUType.monitorLayout else {
            return nil
        }
        guard Int(header.length) == data.count,
              data.count >= 16
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let monitorLayoutSize = try cursor.readLittleEndianUInt32()
        let monitorCount = try Int(cursor.readLittleEndianUInt32())
        guard monitorLayoutSize == 40,
              monitorCount > 0,
              cursor.remaining == monitorCount * 40
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        var monitors: [RDPDisplayControlMonitorLayout] = []
        monitors.reserveCapacity(monitorCount)
        for _ in 0 ..< monitorCount {
            try monitors.append(RDPDisplayControlMonitorLayout.parse(from: &cursor))
        }

        return RDPDisplayControlMonitorLayoutPDU(monitors: monitors)
    }

    func isValid(for capabilities: RDPDisplayControlCapabilities) -> Bool {
        (try? RDPMonitorLayout(monitors: monitors).validate(for: capabilities)) != nil
    }
}

/// Why ``RDPMonitorLayout`` or ``RDPDisplayControlSession`` refused a layout. A monitor is
/// named by its index in ``RDPMonitorLayout/monitors``.
public enum RDPMonitorLayoutError: Error, Equatable, CustomStringConvertible, Sendable {
    case noMonitors
    /// More monitors than a layout holds, or than the server's
    /// ``RDPDisplayControlCapabilities/maxNumMonitors``.
    case tooManyMonitors(count: Int, maximum: Int)
    case invalidWidth(monitor: Int)
    case invalidHeight(monitor: Int)
    /// A flag besides DISPLAYCONTROL_MONITOR_PRIMARY.
    case unsupportedFlags(monitor: Int)
    case invalidOrientation(monitor: Int)
    case invalidScaleFactors(monitor: Int)
    /// This many monitors are primary, rather than one.
    case primaryMonitorCount(Int)
    case primaryMonitorNotAtOrigin
    case overlappingMonitors(Int, Int)
    /// The monitor touches no other.
    case detachedMonitor(monitor: Int)
    /// The monitors' bounding box is wider or taller than `maximum` pixels.
    case desktopTooLarge(maximum: Int)
    /// The monitors cover more pixels than the server's capabilities allow.
    case areaTooLarge(area: UInt64, maximum: UInt64)

    public var description: String {
        switch self {
        case .noMonitors:
            "A monitor layout needs a monitor."
        case let .tooManyMonitors(count, maximum):
            "The layout has \(count) monitors; at most \(maximum) are allowed."
        case let .invalidWidth(monitor):
            "Monitor \(monitor) must be 200 to 8192 pixels wide, an even number."
        case let .invalidHeight(monitor):
            "Monitor \(monitor) must be 200 to 8192 pixels high."
        case let .unsupportedFlags(monitor):
            "Monitor \(monitor) has a flag other than primary."
        case let .invalidOrientation(monitor):
            "Monitor \(monitor) must be turned 0, 90, 180 or 270 degrees."
        case let .invalidScaleFactors(monitor):
            "Monitor \(monitor) needs a desktop scale factor of 100 to 500 and a device scale factor of 100, 140 or 180."
        case let .primaryMonitorCount(count):
            "A monitor layout needs one primary monitor, not \(count)."
        case .primaryMonitorNotAtOrigin:
            "The primary monitor's top-left must be at 0,0."
        case let .overlappingMonitors(first, second):
            "Monitors \(first) and \(second) overlap."
        case let .detachedMonitor(monitor):
            "Monitor \(monitor) must touch another monitor along an edge or at a corner."
        case let .desktopTooLarge(maximum):
            "The monitors must fit in \(maximum) by \(maximum) pixels."
        case let .areaTooLarge(area, maximum):
            "The monitors cover \(area) pixels; the server allows \(maximum)."
        }
    }
}

/// The monitors of a remote desktop: what ``RDPDisplayControlSession`` asks the server for
/// ([MS-RDPEDISP] 2.2.2.2), and what a connection can start with
/// (``RDPConnectionConfiguration/monitorLayout``, [MS-RDPBCGR] 2.2.1.3.6) when they form one
/// group. A monitor's left and top are pixels from the primary monitor's top-left, so one left
/// of or above it has negative ones.
public struct RDPMonitorLayout: Equatable, Sendable {
    /// The most Client Monitor Data and ResetGraphics hold ([MS-RDPBCGR] 2.2.1.3.6,
    /// [MS-RDPEGFX] 2.2.2.14).
    static let maximumMonitorCount = 16
    /// The widest and tallest graphics output ResetGraphics describes ([MS-RDPEGFX] 2.2.2.14).
    static let maximumDesktopDimension = 32766

    /// In the order the server receives them.
    public let monitors: [RDPDisplayControlMonitorLayout]

    /// Throws ``RDPMonitorLayoutError`` unless the monitors follow [MS-RDPEDISP] 2.2.2.2.1:
    /// - 1 to 16 of them, the most Client Monitor Data and ResetGraphics hold;
    /// - each 200 to 8192 pixels wide, an even number, and 200 to 8192 high, with no flag but
    ///   the primary one, an orientation of 0, 90, 180 or 270, a desktop scale factor of 100 to
    ///   500 and a device scale factor of 100, 140 or 180;
    /// - one primary monitor, at 0,0;
    /// - none overlapping another, and each touching another along an edge or at a corner;
    /// - all within 32,766 by 32,766 pixels, the largest desktop RDPGFX describes
    ///   ([MS-RDPEGFX] 2.2.2.14).
    public init(monitors: [RDPDisplayControlMonitorLayout]) throws {
        try Self.validate(monitors)
        self.monitors = monitors
    }

    private init(validated monitors: [RDPDisplayControlMonitorLayout]) {
        self.monitors = monitors
    }

    /// One primary monitor, its size and scale factors moved into range as
    /// ``RDPDisplayControlMonitorLayout/singlePrimary(width:height:desktopScaleFactor:deviceScaleFactor:)``
    /// moves them.
    public static func singlePrimary(
        width: UInt32,
        height: UInt32,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) -> RDPMonitorLayout {
        RDPMonitorLayout(validated: [
            .singlePrimary(
                width: width,
                height: height,
                desktopScaleFactor: desktopScaleFactor,
                deviceScaleFactor: deviceScaleFactor
            ),
        ])
    }

    /// The width of the monitors' bounding box: the desktop the server makes of them.
    public var desktopWidth: UInt32 {
        UInt32(bounds.width)
    }

    /// The height of the monitors' bounding box.
    public var desktopHeight: UInt32 {
        UInt32(bounds.height)
    }

    /// Throws ``RDPMonitorLayoutError`` unless the server's DisplayControl capabilities allow
    /// the layout ([MS-RDPEDISP] 2.2.2.1): at most MaxNumMonitors monitors, covering at most
    /// MaxNumMonitors × MaxMonitorAreaFactorA × MaxMonitorAreaFactorB pixels.
    public func validate(for capabilities: RDPDisplayControlCapabilities) throws {
        guard monitors.count <= Int(capabilities.maxNumMonitors) else {
            throw RDPMonitorLayoutError.tooManyMonitors(
                count: monitors.count,
                maximum: Int(capabilities.maxNumMonitors)
            )
        }
        // At most 16 monitors of 8192 by 8192 pixels: no overflow.
        let area = monitors.reduce(UInt64(0)) { $0 + UInt64($1.width) * UInt64($1.height) }
        let maximumArea = cappedAreaProduct(
            capabilities.maxNumMonitors,
            capabilities.maxMonitorAreaFactorA,
            capabilities.maxMonitorAreaFactorB
        )
        guard area <= maximumArea else {
            throw RDPMonitorLayoutError.areaTooLarge(area: area, maximum: maximumArea)
        }
    }

    /// Whether every monitor reaches every other through monitors that touch, along an edge or
    /// at a corner, as [MS-RDPEDISP] 3.1.5.2 counts touching. That section asks only that each
    /// monitor touch another, and Windows 11 applies separate groups through Display Control,
    /// but a connection drops them (``RDPConnectionConfiguration/monitorLayout``).
    var formsOneGroup: Bool {
        let rectangles = monitors.map(RDPDisplayControlMonitorRect.init)
        var reached: Set<Int> = [0]
        var unvisited = [0]
        while let index = unvisited.popLast() {
            for other in rectangles.indices where !reached.contains(other)
                && rectangles[index].isAdjacent(to: rectangles[other])
            {
                reached.insert(other)
                unvisited.append(other)
            }
        }
        return reached.count == rectangles.count
    }

    private var bounds: RDPDisplayControlMonitorRect {
        RDPDisplayControlMonitorRect(bounding: monitors)
    }

    private static func validate(_ monitors: [RDPDisplayControlMonitorLayout]) throws {
        guard monitors.isEmpty == false else {
            throw RDPMonitorLayoutError.noMonitors
        }
        guard monitors.count <= maximumMonitorCount else {
            throw RDPMonitorLayoutError.tooManyMonitors(count: monitors.count, maximum: maximumMonitorCount)
        }
        for (index, monitor) in monitors.enumerated() {
            try validate(monitor, at: index)
        }
        let primaryMonitors = monitors.filter(\.isPrimary)
        guard primaryMonitors.count == 1 else {
            throw RDPMonitorLayoutError.primaryMonitorCount(primaryMonitors.count)
        }
        guard primaryMonitors[0].left == 0, primaryMonitors[0].top == 0 else {
            throw RDPMonitorLayoutError.primaryMonitorNotAtOrigin
        }
        try validateArrangement(monitors.map(RDPDisplayControlMonitorRect.init))
        let bounds = RDPDisplayControlMonitorRect(bounding: monitors)
        guard bounds.width <= maximumDesktopDimension, bounds.height <= maximumDesktopDimension else {
            throw RDPMonitorLayoutError.desktopTooLarge(maximum: maximumDesktopDimension)
        }
    }

    private static func validate(_ monitor: RDPDisplayControlMonitorLayout, at index: Int) throws {
        guard monitor.flags & ~RDPDisplayControlMonitorFlags.supportedMask == 0 else {
            throw RDPMonitorLayoutError.unsupportedFlags(monitor: index)
        }
        guard (200 ... 8192).contains(monitor.width), monitor.width.isMultiple(of: 2) else {
            throw RDPMonitorLayoutError.invalidWidth(monitor: index)
        }
        guard (200 ... 8192).contains(monitor.height) else {
            throw RDPMonitorLayoutError.invalidHeight(monitor: index)
        }
        guard [0, 90, 180, 270].contains(monitor.orientation) else {
            throw RDPMonitorLayoutError.invalidOrientation(monitor: index)
        }
        guard (100 ... 500).contains(monitor.desktopScaleFactor),
              [100, 140, 180].contains(monitor.deviceScaleFactor)
        else {
            throw RDPMonitorLayoutError.invalidScaleFactors(monitor: index)
        }
    }

    /// No monitor overlaps another, and each touches another.
    private static func validateArrangement(_ rectangles: [RDPDisplayControlMonitorRect]) throws {
        var hasAdjacentMonitor = Array(repeating: rectangles.count == 1, count: rectangles.count)
        for leftIndex in rectangles.indices {
            for rightIndex in rectangles.indices where rightIndex > leftIndex {
                guard rectangles[leftIndex].overlaps(rectangles[rightIndex]) == false else {
                    throw RDPMonitorLayoutError.overlappingMonitors(leftIndex, rightIndex)
                }
                if rectangles[leftIndex].isAdjacent(to: rectangles[rightIndex]) {
                    hasAdjacentMonitor[leftIndex] = true
                    hasAdjacentMonitor[rightIndex] = true
                }
            }
        }
        if let detached = hasAdjacentMonitor.firstIndex(of: false) {
            throw RDPMonitorLayoutError.detachedMonitor(monitor: detached)
        }
    }
}

/// A monitor's rectangle, right and bottom exclusive, in 64 bits so that no sum overflows.
private struct RDPDisplayControlMonitorRect {
    var left: Int64
    var top: Int64
    var right: Int64
    var bottom: Int64

    init(_ monitor: RDPDisplayControlMonitorLayout) {
        left = Int64(monitor.left)
        top = Int64(monitor.top)
        right = left + Int64(monitor.width)
        bottom = top + Int64(monitor.height)
    }

    /// The bounding box of `monitors`, which must not be empty.
    init(bounding monitors: [RDPDisplayControlMonitorLayout]) {
        self = monitors.dropFirst().map(Self.init).reduce(Self(monitors[0])) { bounds, rect in
            var bounds = bounds
            bounds.left = min(bounds.left, rect.left)
            bounds.top = min(bounds.top, rect.top)
            bounds.right = max(bounds.right, rect.right)
            bounds.bottom = max(bounds.bottom, rect.bottom)
            return bounds
        }
    }

    var width: Int64 {
        right - left
    }

    var height: Int64 {
        bottom - top
    }

    func overlaps(_ other: RDPDisplayControlMonitorRect) -> Bool {
        max(left, other.left) < min(right, other.right)
            && max(top, other.top) < min(bottom, other.bottom)
    }

    func isAdjacent(to other: RDPDisplayControlMonitorRect) -> Bool {
        let horizontalRangesTouch = max(left, other.left) <= min(right, other.right)
        let verticalRangesTouch = max(top, other.top) <= min(bottom, other.bottom)
        return (right == other.left || other.right == left) && verticalRangesTouch
            || (bottom == other.top || other.bottom == top) && horizontalRangesTouch
    }
}

private func cappedAreaProduct(_ lhs: UInt32, _ rhs: UInt32, _ other: UInt32) -> UInt64 {
    let first = UInt64(lhs).multipliedReportingOverflow(by: UInt64(rhs))
    guard first.overflow == false else {
        return UInt64.max
    }
    let second = first.partialValue.multipliedReportingOverflow(by: UInt64(other))
    return second.overflow ? UInt64.max : second.partialValue
}

public final class RDPDisplayControlSession: Sendable {
    public let dynamicChannelID: UInt32
    public let capabilities: RDPDisplayControlCapabilities
    private let userChannelID: UInt16
    private let staticChannelID: UInt16
    private let channel: Channel
    private let cutoff = RDPSendCutoff()

    init(
        dynamicChannelID: UInt32,
        capabilities: RDPDisplayControlCapabilities,
        userChannelID: UInt16,
        staticChannelID: UInt16,
        channel: Channel
    ) {
        self.dynamicChannelID = dynamicChannelID
        self.capabilities = capabilities
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
    }

    /// Sends ``RDPMonitorLayout/singlePrimary(width:height:desktopScaleFactor:deviceScaleFactor:)``,
    /// or nothing when the server's ``capabilities`` do not allow it.
    public func sendSingleMonitorLayout(
        width: UInt32,
        height: UInt32,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) {
        try? send(RDPMonitorLayout.singlePrimary(
            width: width,
            height: height,
            desktopScaleFactor: desktopScaleFactor,
            deviceScaleFactor: deviceScaleFactor
        ))
    }

    /// Sends the request's one monitor, or nothing when the server's ``capabilities`` do not
    /// allow it.
    public func send(_ request: RDPDisplayRequest) {
        try? send(request.monitorLayout)
    }

    /// Asks the server for `layout` ([MS-RDPEDISP] 2.2.2.2). Throws ``RDPMonitorLayoutError``
    /// when the server's ``capabilities`` do not allow it. Sends nothing once the server has
    /// closed this session's channel or opened another DisplayControl channel, whose session
    /// `onDisplayControlReady` hands out.
    public func send(_ layout: RDPMonitorLayout) throws {
        try layout.validate(for: capabilities)
        guard !cutoff.isCutOff else {
            return
        }

        let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
            channelID: dynamicChannelID,
            payload: RDPDisplayControlMonitorLayoutPDU(monitors: layout.monitors).encoded()
        ).encoded()
        let packet = RDPStaticVirtualChannelPDU(
            payload: dynamicPayload,
            flags: RDPStaticVirtualChannelFlags.complete
        )
            .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            var buffer = self.channel.allocator.buffer(capacity: packet.count)
            buffer.writeBytes(packet)
            self.channel.writeAndFlush(buffer, promise: nil)
        }
    }

    func end() {
        cutoff.cut()
    }
}

private func clampedDisplayDimension(_ value: UInt32) -> UInt32 {
    min(8192, max(200, value))
}

private func evenDisplayWidth(_ value: UInt32) -> UInt32 {
    let clamped = clampedDisplayDimension(value)
    return clamped.isMultiple(of: 2) ? clamped : clamped - 1
}

func clampedDesktopScaleFactor(_ value: UInt32) -> UInt32 {
    min(500, max(100, value))
}

func nearestDeviceScaleFactor(_ value: UInt32) -> UInt32 {
    if value < 120 {
        return 100
    }
    if value < 160 {
        return 140
    }
    return 180
}
