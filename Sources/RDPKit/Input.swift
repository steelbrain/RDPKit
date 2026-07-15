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

enum RDPPointerFlags {
    static let wheel: UInt16 = 0x0200
    static let horizontalWheel: UInt16 = 0x0400
    static let wheelNegative: UInt16 = 0x0100
    static let wheelRotationMask: UInt16 = 0x01FF
    static let move: UInt16 = 0x0800
    static let down: UInt16 = 0x8000
}

public struct RDPKeyboardScancode: Equatable, Hashable, Sendable {
    public var code: UInt16
    public var isExtended: Bool

    public init(code: UInt16, isExtended: Bool = false) {
        self.code = code
        self.isExtended = isExtended
    }
}

public struct RDPToggleKeyFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let scrollLock = RDPToggleKeyFlags(rawValue: 0x0000_0001)
    public static let numLock = RDPToggleKeyFlags(rawValue: 0x0000_0002)
    public static let capsLock = RDPToggleKeyFlags(rawValue: 0x0000_0004)
    public static let kanaLock = RDPToggleKeyFlags(rawValue: 0x0000_0008)
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
    case synchronize(toggleFlags: RDPToggleKeyFlags)
    case pointerMove(x: UInt16, y: UInt16)
    case pointerButton(button: RDPPointerButton, isDown: Bool, x: UInt16, y: UInt16)
    case verticalWheel(rotation: Int, x: UInt16, y: UInt16)
    case horizontalWheel(rotation: Int, x: UInt16, y: UInt16)
    case unicode(codeUnit: UInt16, isReleased: Bool)
    case scancode(code: UInt16, flags: UInt16)

    public static func keyboard(
        scancode: RDPKeyboardScancode,
        isReleased: Bool,
        wasDown: Bool = false
    ) -> RDPSlowPathInputEvent {
        var flags: UInt16 = isReleased ? 0x8000 : 0
        if wasDown {
            flags |= 0x4000
        }
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
        case .synchronize:
            0x0000
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
        case let .synchronize(toggleFlags):
            var data = Data()
            data.appendLittleEndianUInt16(0)
            data.appendLittleEndianUInt32(toggleFlags.rawValue)
            return data
        case let .pointerMove(x, y):
            return pointerData(flags: RDPPointerFlags.move, x: x, y: y)
        case let .pointerButton(button, isDown, x, y):
            let flags = button.pointerFlag | (isDown ? RDPPointerFlags.down : 0)
            return pointerData(flags: flags, x: x, y: y)
        case let .verticalWheel(rotation, x, y):
            return pointerData(flags: wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.wheel), x: x, y: y)
        case let .horizontalWheel(rotation, x, y):
            return pointerData(
                flags: wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.horizontalWheel),
                x: x,
                y: y
            )
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
        let clamped = min(255, max(-256, rotation))
        let encodedRotation: UInt16
        if clamped < 0 {
            encodedRotation = UInt16(0x0200 + clamped) & RDPPointerFlags.wheelRotationMask
        } else {
            encodedRotation = UInt16(clamped)
        }
        return baseFlag | encodedRotation
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

        return .keyboard(scancode: scancode, isReleased: isReleased, wasDown: isRepeat && isReleased == false)
    }

    public mutating func releasePressedInputs() -> [RDPSlowPathInputEvent] {
        releasePressedPointerButtons() + releasePressedScancodes()
    }

    public func synchronizationEvents(toggleFlags: RDPToggleKeyFlags = []) -> [RDPSlowPathInputEvent] {
        [.synchronize(toggleFlags: toggleFlags)] + pressedPointerButtonDownEvents() + pressedScancodeDownEvents()
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

    private func pressedPointerButtonDownEvents() -> [RDPSlowPathInputEvent] {
        guard pressedPointerButtons.isEmpty == false,
              let lastPointerPoint
        else {
            return []
        }

        return pressedPointerButtons
            .sorted { $0.releaseSortOrder < $1.releaseSortOrder }
            .map { button in
                RDPSlowPathInputEvent.pointerButton(
                    button: button,
                    isDown: true,
                    x: lastPointerPoint.x,
                    y: lastPointerPoint.y
                )
            }
    }

    private func pressedScancodeDownEvents() -> [RDPSlowPathInputEvent] {
        pressedScancodes
            .sorted { lhs, rhs in
                if lhs.code == rhs.code {
                    return lhs.isExtended == false && rhs.isExtended
                }
                return lhs.code < rhs.code
            }
            .map { RDPSlowPathInputEvent.keyboard(scancode: $0, isReleased: false) }
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
    var isExtended: Bool {
        switch self {
        case .extended1, .extended2:
            return true
        case .left, .right, .middle:
            return false
        }
    }

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

private enum RDPInputCapabilityFlags {
    static let mouseExtended: UInt16 = 0x0004
    static let unicode: UInt16 = 0x0010
    static let mouseHorizontalWheel: UInt16 = 0x0100
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
        precondition(events.isEmpty == false)
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

struct RDPFastPathInputPDU: Equatable, Sendable {
    static let maximumEventsPerPDU = 255

    var events: [RDPSlowPathInputEvent]

    func encoded() -> Data? {
        guard !events.isEmpty, events.count <= Self.maximumEventsPerPDU else {
            return nil
        }
        var encodedEvents = Data()
        for event in events {
            guard let encoded = event.encodedFastPath else {
                return nil
            }
            encodedEvents.append(encoded)
        }

        let usesExplicitEventCount = events.count > 15
        let payloadByteCount = encodedEvents.count + (usesExplicitEventCount ? 1 : 0)
        let usesTwoByteLength = payloadByteCount + 2 >= 128
        let totalByteCount = payloadByteCount + (usesTwoByteLength ? 3 : 2)
        guard totalByteCount <= 0x3FFF else {
            return nil
        }

        var data = Data()
        let headerEventCount = usesExplicitEventCount ? 0 : UInt8(events.count)
        data.appendUInt8(headerEventCount << 2)
        if usesTwoByteLength {
            data.appendUInt8(0x80 | UInt8((totalByteCount >> 8) & 0x7F))
            data.appendUInt8(UInt8(totalByteCount & 0xFF))
        } else {
            data.appendUInt8(UInt8(totalByteCount))
        }
        if usesExplicitEventCount {
            data.appendUInt8(UInt8(events.count))
        }
        data.append(encodedEvents)
        return data
    }
}

private extension RDPSlowPathInputEvent {
    var encodedFastPath: Data? {
        var data = Data()
        switch self {
        case let .synchronize(toggleFlags):
            guard toggleFlags.rawValue <= 0x0F else {
                return nil
            }
            data.appendUInt8(0x60 | UInt8(toggleFlags.rawValue))

        case let .pointerMove(x, y):
            appendFastPathPointer(eventCode: 1, flags: RDPPointerFlags.move, x: x, y: y, to: &data)

        case let .pointerButton(button, isDown, x, y):
            let eventCode: UInt8 = button.isExtended ? 2 : 1
            let flags = button.pointerFlag | (isDown ? RDPPointerFlags.down : 0)
            appendFastPathPointer(eventCode: eventCode, flags: flags, x: x, y: y, to: &data)

        case let .verticalWheel(rotation, x, y):
            appendFastPathPointer(
                eventCode: 1,
                flags: wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.wheel),
                x: x,
                y: y,
                to: &data
            )

        case let .horizontalWheel(rotation, x, y):
            appendFastPathPointer(
                eventCode: 1,
                flags: wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.horizontalWheel),
                x: x,
                y: y,
                to: &data
            )

        case let .unicode(codeUnit, isReleased):
            data.appendUInt8(0x80 | (isReleased ? 0x01 : 0))
            data.appendLittleEndianUInt16(codeUnit)

        case let .scancode(code, flags):
            guard code <= UInt16(UInt8.max),
                  flags & ~UInt16(0xC300) == 0
            else {
                return nil
            }
            var fastPathFlags: UInt8 = 0
            if flags & 0x8000 != 0 {
                fastPathFlags |= 0x01
            }
            if flags & 0x0100 != 0 {
                fastPathFlags |= 0x02
            }
            if flags & 0x0200 != 0 {
                fastPathFlags |= 0x04
            }
            data.appendUInt8(fastPathFlags)
            data.appendUInt8(UInt8(code))
        }
        return data
    }

    func appendFastPathPointer(
        eventCode: UInt8,
        flags: UInt16,
        x: UInt16,
        y: UInt16,
        to data: inout Data
    ) {
        data.appendUInt8(eventCode << 5)
        data.appendLittleEndianUInt16(flags)
        data.appendLittleEndianUInt16(x)
        data.appendLittleEndianUInt16(y)
    }
}

public final class RDPInputSession: @unchecked Sendable {
    public let shareID: UInt32
    private let userChannelID: UInt16
    private let ioChannelID: UInt16
    private let channel: Channel
    private let serverInputFlags: UInt16?

    init(
        shareID: UInt32,
        userChannelID: UInt16,
        ioChannelID: UInt16,
        channel: Channel,
        serverInputFlags: UInt16? = nil
    ) {
        self.shareID = shareID
        self.userChannelID = userChannelID
        self.ioChannelID = ioChannelID
        self.channel = channel
        self.serverInputFlags = serverInputFlags
    }

    public func send(_ event: RDPSlowPathInputEvent) {
        send([event])
    }

    public func send(_ events: [RDPSlowPathInputEvent]) {
        let supportedEvents = Self.supportedEvents(events, serverInputFlags: serverInputFlags)
        guard supportedEvents.isEmpty == false else {
            return
        }

        if serverInputFlags.supportsFastPathInput {
            for eventChunk in supportedEvents.chunked(maximumCount: RDPFastPathInputPDU.maximumEventsPerPDU) {
                guard let packet = RDPFastPathInputPDU(events: eventChunk).encoded() else {
                    sendSlowPath(eventChunk)
                    continue
                }
                sendPacket(packet)
            }
            return
        }
        sendSlowPath(supportedEvents)
    }

    private func sendSlowPath(_ events: [RDPSlowPathInputEvent]) {
        for eventChunk in RDPClientInputPDU.eventChunks(events) {
            let packet = RDPClientInputPDU(shareID: shareID, events: eventChunk)
                .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
            sendPacket(packet)
        }
    }

    static func supportedEvents(
        _ events: [RDPSlowPathInputEvent],
        serverInputFlags: UInt16?
    ) -> [RDPSlowPathInputEvent] {
        events.filter { event in
            switch event {
            case .unicode:
                return serverInputFlags.supports(RDPInputCapabilityFlags.unicode)
            case let .pointerButton(button, _, _, _) where button.isExtended:
                return serverInputFlags.supports(RDPInputCapabilityFlags.mouseExtended)
            case .horizontalWheel:
                return serverInputFlags.supports(RDPInputCapabilityFlags.mouseHorizontalWheel)
            default:
                return true
            }
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

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard !isEmpty else {
            return []
        }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index ..< end]))
            index = end
        }
        return chunks
    }
}

private extension Optional where Wrapped == UInt16 {
    var supportsFastPathInput: Bool {
        map { $0 & 0x0028 != 0 } ?? false
    }

    func supports(_ flag: UInt16) -> Bool {
        map { $0 & flag != 0 } ?? false
    }
}
