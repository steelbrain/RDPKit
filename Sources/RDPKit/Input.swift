import Foundation
@preconcurrency import NIOCore

public enum RDPPointerButton: Equatable, Hashable, Sendable {
    case left
    case right
    case middle
    case extended1
    case extended2

    var messageType: UInt16 {
        switch self {
        case .left, .right, .middle:
            0x8001
        case .extended1, .extended2:
            0x8002
        }
    }

    var pointerFlag: UInt16 {
        switch self {
        case .left:
            0x1000
        case .right:
            0x2000
        case .middle:
            0x4000
        case .extended1:
            0x0001
        case .extended2:
            0x0002
        }
    }
}

public struct RDPKeyboardScancode: Equatable, Hashable, Sendable {
    public var code: UInt16
    public var isExtended: Bool

    public init(code: UInt16, isExtended: Bool = false) {
        self.code = code
        self.isExtended = isExtended
    }
}

public struct RDPRemotePoint: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}

public enum RDPSlowPathInputEvent: Equatable, Sendable {
    case pointerMove(x: UInt16, y: UInt16)
    case pointerButton(button: RDPPointerButton, isDown: Bool, x: UInt16, y: UInt16)
    case verticalWheel(rotation: Int, x: UInt16, y: UInt16)
    case horizontalWheel(rotation: Int, x: UInt16, y: UInt16)
    case unicode(codeUnit: UInt16, isReleased: Bool)
    case scancode(code: UInt16, flags: UInt16)

    public static func keyboard(scancode: RDPKeyboardScancode, isReleased: Bool) -> RDPSlowPathInputEvent {
        var flags: UInt16 = isReleased ? 0x8000 : 0
        if scancode.isExtended {
            flags |= 0x0100
        }
        return .scancode(code: scancode.code, flags: flags)
    }

    func encoded(eventTime: UInt32 = 0) -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(eventTime)
        data.appendLittleEndianUInt16(messageType)
        data.append(eventData)
        return data
    }

    private var messageType: UInt16 {
        switch self {
        case .pointerMove, .verticalWheel, .horizontalWheel:
            0x8001
        case let .pointerButton(button, _, _, _):
            button.messageType
        case .unicode:
            0x0005
        case .scancode:
            0x0004
        }
    }

    private var eventData: Data {
        switch self {
        case let .pointerMove(x, y):
            return pointerData(flags: 0x0800, x: x, y: y)
        case let .pointerButton(button, isDown, x, y):
            let flags = button.pointerFlag | (isDown ? 0x8000 : 0)
            return pointerData(flags: flags, x: x, y: y)
        case let .verticalWheel(rotation, x, y):
            return pointerData(flags: wheelFlags(rotation: rotation, baseFlag: 0x0200), x: x, y: y)
        case let .horizontalWheel(rotation, x, y):
            return pointerData(flags: wheelFlags(rotation: rotation, baseFlag: 0x0400), x: x, y: y)
        case let .unicode(codeUnit, isReleased):
            var data = Data()
            data.appendLittleEndianUInt16(isReleased ? 0x8000 : 0)
            data.appendLittleEndianUInt16(codeUnit)
            data.appendLittleEndianUInt16(0)
            return data
        case let .scancode(code, flags):
            var data = Data()
            data.appendLittleEndianUInt16(flags)
            data.appendLittleEndianUInt16(code)
            data.appendLittleEndianUInt16(0)
            return data
        }
    }

    private func pointerData(flags: UInt16, x: UInt16, y: UInt16) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(flags)
        data.appendLittleEndianUInt16(x)
        data.appendLittleEndianUInt16(y)
        return data
    }

    private func wheelFlags(rotation: Int, baseFlag: UInt16) -> UInt16 {
        let magnitude = min(abs(rotation), 0x01FF)
        return baseFlag | (rotation < 0 ? 0x0100 : 0) | UInt16(magnitude)
    }
}

public struct RDPInputStateTracker: Sendable {
    private var pressedScancodes = Set<RDPKeyboardScancode>()
    private var pressedPointerButtons = Set<RDPPointerButton>()

    public private(set) var lastPointerPoint: RDPRemotePoint?

    public init() {}

    public func isScancodePressed(_ scancode: RDPKeyboardScancode) -> Bool {
        pressedScancodes.contains(scancode)
    }

    public func isPointerButtonPressed(_ button: RDPPointerButton) -> Bool {
        pressedPointerButtons.contains(button)
    }

    public mutating func updatePointerLocation(_ point: RDPRemotePoint) {
        lastPointerPoint = point
    }

    public mutating func pointerMove(to point: RDPRemotePoint) -> RDPSlowPathInputEvent {
        updatePointerLocation(point)
        return .pointerMove(x: point.x, y: point.y)
    }

    public mutating func pointerButton(
        _ button: RDPPointerButton,
        isDown: Bool,
        at point: RDPRemotePoint?
    ) -> RDPSlowPathInputEvent? {
        guard let point = point ?? releasePoint(for: button, isDown: isDown) else {
            if isDown == false {
                pressedPointerButtons.remove(button)
            }
            return nil
        }

        updatePointerLocation(point)
        updatePointerButton(button, isDown: isDown)
        return .pointerButton(button: button, isDown: isDown, x: point.x, y: point.y)
    }

    public mutating func keyboard(
        scancode: RDPKeyboardScancode,
        isReleased: Bool,
        trackRelease: Bool = true,
        isRepeat: Bool = false
    ) -> RDPSlowPathInputEvent {
        if trackRelease {
            if isReleased {
                pressedScancodes.remove(scancode)
            } else if isRepeat == false {
                pressedScancodes.insert(scancode)
            }
        }

        return .keyboard(scancode: scancode, isReleased: isReleased)
    }

    public mutating func releasePressedInputs() -> [RDPSlowPathInputEvent] {
        releasePressedPointerButtons() + releasePressedScancodes()
    }

    public mutating func releasePressedPointerButtons() -> [RDPSlowPathInputEvent] {
        guard pressedPointerButtons.isEmpty == false,
              let lastPointerPoint
        else {
            pressedPointerButtons.removeAll()
            return []
        }

        let releaseEvents = pressedPointerButtons
            .sorted { $0.releaseSortOrder < $1.releaseSortOrder }
            .map { button in
                RDPSlowPathInputEvent.pointerButton(
                    button: button,
                    isDown: false,
                    x: lastPointerPoint.x,
                    y: lastPointerPoint.y
                )
            }
        pressedPointerButtons.removeAll()
        return releaseEvents
    }

    public mutating func releasePressedScancodes() -> [RDPSlowPathInputEvent] {
        guard pressedScancodes.isEmpty == false else {
            return []
        }

        let releaseEvents = pressedScancodes
            .sorted { lhs, rhs in
                if lhs.code == rhs.code {
                    return lhs.isExtended == false && rhs.isExtended
                }
                return lhs.code < rhs.code
            }
            .map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: true) }
        pressedScancodes.removeAll()
        return releaseEvents
    }

    private mutating func updatePointerButton(_ button: RDPPointerButton, isDown: Bool) {
        if isDown {
            pressedPointerButtons.insert(button)
        } else {
            pressedPointerButtons.remove(button)
        }
    }

    private func releasePoint(for button: RDPPointerButton, isDown: Bool) -> RDPRemotePoint? {
        guard isDown == false, pressedPointerButtons.contains(button) else {
            return nil
        }
        return lastPointerPoint
    }
}

private extension RDPPointerButton {
    var releaseSortOrder: Int {
        switch self {
        case .left:
            0
        case .middle:
            1
        case .right:
            2
        case .extended1:
            3
        case .extended2:
            4
        }
    }
}

struct RDPClientInputPDU: Equatable, Sendable {
    static let encodedEventByteCount = 12
    static let shareDataHeaderByteCount = 18
    static let inputPayloadHeaderByteCount = 4
    static let maximumEventsPerPDU = max(
        1,
        (
            MCSSendDataRequestPDU.maximumUserDataByteCount
                - shareDataHeaderByteCount
                - inputPayloadHeaderByteCount
        ) / encodedEventByteCount
    )

    var shareID: UInt32
    var events: [RDPSlowPathInputEvent]

    init(shareID: UInt32, events: [RDPSlowPathInputEvent]) {
        self.shareID = shareID
        self.events = events
    }

    static func eventChunks(_ events: [RDPSlowPathInputEvent]) -> [[RDPSlowPathInputEvent]] {
        var chunks: [[RDPSlowPathInputEvent]] = []
        var index = events.startIndex
        while index < events.endIndex {
            let endIndex = events.index(
                index,
                offsetBy: maximumEventsPerPDU,
                limitedBy: events.endIndex
            ) ?? events.endIndex
            chunks.append(Array(events[index ..< endIndex]))
            index = endIndex
        }
        return chunks
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        precondition(events.count <= Int(UInt16.max))
        precondition(events.count <= Self.maximumEventsPerPDU)

        var payload = Data()
        payload.appendLittleEndianUInt16(UInt16(events.count))
        payload.appendLittleEndianUInt16(0)
        for event in events {
            payload.append(event.encoded())
        }

        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: 0x1C,
            payload: payload
        )
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData(userChannelID: userChannelID)
        ).encodedTPKT()
    }
}

public final class RDPInputSession: @unchecked Sendable {
    public let shareID: UInt32
    private let userChannelID: UInt16
    private let ioChannelID: UInt16
    private let channel: Channel

    init(shareID: UInt32, userChannelID: UInt16, ioChannelID: UInt16, channel: Channel) {
        self.shareID = shareID
        self.userChannelID = userChannelID
        self.ioChannelID = ioChannelID
        self.channel = channel
    }

    public func send(_ event: RDPSlowPathInputEvent) {
        send([event])
    }

    public func send(_ events: [RDPSlowPathInputEvent]) {
        guard events.isEmpty == false else {
            return
        }

        for eventChunk in RDPClientInputPDU.eventChunks(events) {
            let packet = RDPClientInputPDU(shareID: shareID, events: eventChunk)
                .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
            sendPacket(packet)
        }
    }

    private func sendPacket(_ packet: Data) {
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
