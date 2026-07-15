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

    init(type: UInt32, length: UInt32) {
        self.type = type
        self.length = length
    }

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

struct RDPDisplayControlCapsPDU: Encodable, Equatable, Sendable {
    var maxNumMonitors: UInt32
    var maxMonitorAreaFactorA: UInt32
    var maxMonitorAreaFactorB: UInt32

    var capabilities: RDPDisplayControlCapabilities {
        RDPDisplayControlCapabilities(
            maxNumMonitors: maxNumMonitors,
            maxMonitorAreaFactorA: maxMonitorAreaFactorA,
            maxMonitorAreaFactorB: maxMonitorAreaFactorB
        )
    }

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

        return try RDPDisplayControlCapsPDU(
            maxNumMonitors: cursor.readLittleEndianUInt32(),
            maxMonitorAreaFactorA: cursor.readLittleEndianUInt32(),
            maxMonitorAreaFactorB: cursor.readLittleEndianUInt32()
        )
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
        guard monitors.isEmpty == false,
              monitors.count <= Int(capabilities.maxNumMonitors)
        else {
            return false
        }

        var totalArea: UInt64 = 0
        for monitor in monitors {
            guard monitor.flags & ~RDPDisplayControlMonitorFlags.supportedMask == 0,
                  monitor.width >= 200,
                  monitor.width <= 8192,
                  monitor.width.isMultiple(of: 2),
                  monitor.height >= 200,
                  monitor.height <= 8192,
                  monitor.orientation == 0
                    || monitor.orientation == 90
                    || monitor.orientation == 180
                    || monitor.orientation == 270,
                  (100 ... 500).contains(monitor.desktopScaleFactor),
                  [100, 140, 180].contains(monitor.deviceScaleFactor)
            else {
                return false
            }

            let monitorArea = UInt64(monitor.width) * UInt64(monitor.height)
            let areaSum = totalArea.addingReportingOverflow(monitorArea)
            guard areaSum.overflow == false else {
                return false
            }
            totalArea = areaSum.partialValue
        }

        guard hasValidPrimaryMonitor(monitors),
              hasNonOverlappingAdjacentMonitors(monitors)
        else {
            return false
        }

        let maximumArea = cappedAreaProduct(
            capabilities.maxNumMonitors,
            capabilities.maxMonitorAreaFactorA,
            capabilities.maxMonitorAreaFactorB
        )
        return totalArea <= maximumArea
    }
}

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

private func hasValidPrimaryMonitor(_ monitors: [RDPDisplayControlMonitorLayout]) -> Bool {
    let primaryMonitors = monitors.filter { $0.flags & RDPDisplayControlMonitorFlags.primary != 0 }
    return primaryMonitors.count == 1
        && primaryMonitors[0].left == 0
        && primaryMonitors[0].top == 0
}

private func hasNonOverlappingAdjacentMonitors(_ monitors: [RDPDisplayControlMonitorLayout]) -> Bool {
    let rectangles = monitors.map(RDPDisplayControlMonitorRect.init)
    var hasAdjacentMonitor = Array(repeating: monitors.count == 1, count: monitors.count)

    for leftIndex in rectangles.indices {
        for rightIndex in rectangles.indices where rightIndex > leftIndex {
            guard rectangles[leftIndex].overlaps(rectangles[rightIndex]) == false else {
                return false
            }
            if rectangles[leftIndex].isAdjacent(to: rectangles[rightIndex]) {
                hasAdjacentMonitor[leftIndex] = true
                hasAdjacentMonitor[rightIndex] = true
            }
        }
    }

    return hasAdjacentMonitor.allSatisfy { $0 }
}

private func cappedAreaProduct(_ lhs: UInt32, _ rhs: UInt32, _ other: UInt32) -> UInt64 {
    let first = UInt64(lhs).multipliedReportingOverflow(by: UInt64(rhs))
    guard first.overflow == false else {
        return UInt64.max
    }
    let second = first.partialValue.multipliedReportingOverflow(by: UInt64(other))
    return second.overflow ? UInt64.max : second.partialValue
}

public final class RDPDisplayControlSession: @unchecked Sendable {
    public let dynamicChannelID: UInt32
    public let capabilities: RDPDisplayControlCapabilities
    private let userChannelID: UInt16
    private let staticChannelID: UInt16
    private let channel: Channel

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

    public func sendSingleMonitorLayout(
        width: UInt32,
        height: UInt32,
        desktopScaleFactor: UInt32 = 100,
        deviceScaleFactor: UInt32 = 100
    ) {
        send(RDPDisplayControlMonitorLayoutPDU.singlePrimary(
            width: width,
            height: height,
            desktopScaleFactor: desktopScaleFactor,
            deviceScaleFactor: deviceScaleFactor
        ))
    }

    public func send(_ request: RDPDisplayRequest) {
        send(request.monitorLayoutPDU)
    }

    func send(_ layout: RDPDisplayControlMonitorLayoutPDU) {
        guard layout.isValid(for: capabilities) else {
            return
        }

        let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
            channelID: dynamicChannelID,
            payload: layout.encoded()
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
}

private func clampedDisplayDimension(_ value: UInt32) -> UInt32 {
    min(8192, max(200, value))
}

private func evenDisplayWidth(_ value: UInt32) -> UInt32 {
    let clamped = clampedDisplayDimension(value)
    return clamped.isMultiple(of: 2) ? clamped : clamped - 1
}

private func clampedDesktopScaleFactor(_ value: UInt32) -> UInt32 {
    min(500, max(100, value))
}

private func nearestDeviceScaleFactor(_ value: UInt32) -> UInt32 {
    if value < 120 {
        return 100
    }
    if value < 160 {
        return 140
    }
    return 180
}
