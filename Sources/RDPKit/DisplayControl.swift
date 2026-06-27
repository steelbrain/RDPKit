import Foundation
@preconcurrency import NIOCore

enum RDPDisplayControlChannel {
    static let name = "Microsoft::Windows::RDS::DisplayControl"
}

enum RDPDisplayControlPDUType {
    static let monitorLayout: UInt32 = 0x0000_0002
    static let caps: UInt32 = 0x0000_0005
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
            flags: 0x0000_0001,
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
}

public final class RDPDisplayControlSession: @unchecked Sendable {
    public let dynamicChannelID: UInt32
    private let userChannelID: UInt16
    private let staticChannelID: UInt16
    private let channel: Channel

    init(dynamicChannelID: UInt32, userChannelID: UInt16, staticChannelID: UInt16, channel: Channel) {
        self.dynamicChannelID = dynamicChannelID
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
        let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
            channelID: dynamicChannelID,
            payload: layout.encoded()
        ).encoded()
        let packet = RDPStaticVirtualChannelPDU(
            payload: dynamicPayload,
            flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol
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
