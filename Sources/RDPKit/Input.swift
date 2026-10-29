import Foundation
@preconcurrency import NIOCore

public enum RDPPointerButton: CaseIterable, Equatable, Hashable, Sendable {
    case left
    case right
    case middle
    case extended1
    case extended2

    var isExtended: Bool {
        self == .extended1 || self == .extended2
    }

    // PTRFLAGS_BUTTON1-3 (TS_POINTER_EVENT) or PTRXFLAGS_BUTTON1-2 (TS_POINTERX_EVENT).
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

/// A Windows keyboard layout identifier (KLID), such as 0x00000407 for German. The server
/// turns scancodes into characters with this layout, so it should match the local keyboard
/// ([MS-RDPBCGR] 2.2.1.3.2, 2.2.7.1.6).
public struct RDPKeyboardLayout: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let unitedStates = RDPKeyboardLayout(rawValue: 0x0000_0409)
}

/// The kind of keyboard the server assumes when it maps scancodes ([MS-RDPBCGR] 2.2.1.3.2).
public struct RDPKeyboardType: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// An IBM enhanced (101- or 102-key) keyboard.
    public static let ibmEnhanced = RDPKeyboardType(rawValue: 4)
    /// A Japanese keyboard.
    public static let japanese = RDPKeyboardType(rawValue: 7)
}

/// The keyboard announced in the Client Core Data and again in the Input Capability
/// Set, which SHOULD match ([MS-RDPBCGR] 2.2.1.3.2, 2.2.7.1.6).
struct RDPClientKeyboard: Equatable, Sendable {
    var layout = RDPKeyboardLayout.unitedStates
    var type = RDPKeyboardType.ibmEnhanced
    var subType: UInt32 = 0
    var functionKeyCount: UInt32 = 12
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
    /// One UTF-16 code unit. Send text as it is typed: Windows 11 apps garble a long burst of
    /// non-ASCII Unicode events sent at once (later characters repeat the last one), even one per PDU.
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

    // Slow-path TS_INPUT_EVENT (MS-RDPBCGR 2.2.8.1.1.3.1.1); eventTime is ignored by the server.
    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0)
        if let pointer = pointerEvent {
            data.appendLittleEndianUInt16(pointer.isExtended ? 0x8002 : 0x8001)
            data.appendLittleEndianUInt16(pointer.flags)
            data.appendLittleEndianUInt16(pointer.x)
            data.appendLittleEndianUInt16(pointer.y)
            return data
        }
        switch self {
        case let .synchronize(toggleFlags):
            data.appendLittleEndianUInt16(0x0000)
            data.appendLittleEndianUInt16(0)
            data.appendLittleEndianUInt32(toggleFlags.rawValue)
        case let .unicode(codeUnit, isReleased):
            data.appendLittleEndianUInt16(0x0005)
            data.appendLittleEndianUInt16(isReleased ? 0x8000 : 0)
            data.appendLittleEndianUInt16(codeUnit)
            data.appendLittleEndianUInt16(0)
        case let .scancode(code, flags):
            data.appendLittleEndianUInt16(0x0004)
            data.appendLittleEndianUInt16(flags)
            data.appendLittleEndianUInt16(code)
            data.appendLittleEndianUInt16(0)
        case .pointerMove, .pointerButton, .verticalWheel, .horizontalWheel:
            break
        }
        return data
    }

    // Fast-path input event (MS-RDPBCGR 2.2.8.1.2.2); nil when the event has no fast-path form.
    var encodedFastPath: Data? {
        var data = Data()
        if let pointer = pointerEvent {
            data.appendUInt8((pointer.isExtended ? 2 : 1) << 5)
            data.appendLittleEndianUInt16(pointer.flags)
            data.appendLittleEndianUInt16(pointer.x)
            data.appendLittleEndianUInt16(pointer.y)
            return data
        }
        switch self {
        case let .synchronize(toggleFlags):
            guard toggleFlags.rawValue <= 0x0F else {
                return nil
            }
            data.appendUInt8(0x60 | UInt8(toggleFlags.rawValue))
        case let .unicode(codeUnit, isReleased):
            data.appendUInt8(0x80 | (isReleased ? 0x01 : 0))
            data.appendLittleEndianUInt16(codeUnit)
        case let .scancode(code, flags):
            // KBDFLAGS_DOWN (0x4000) has no fast-path equivalent and is dropped.
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
        case .pointerMove, .pointerButton, .verticalWheel, .horizontalWheel:
            break
        }
        return data
    }

    // TS_POINTER_EVENT / TS_POINTERX_EVENT fields shared by the slow- and fast-path encodings.
    private var pointerEvent: (isExtended: Bool, flags: UInt16, x: UInt16, y: UInt16)? {
        switch self {
        case let .pointerMove(x, y):
            (false, RDPPointerFlags.move, x, y)
        case let .pointerButton(button, isDown, x, y):
            (button.isExtended, button.pointerFlag | (isDown ? RDPPointerFlags.down : 0), x, y)
        case let .verticalWheel(rotation, x, y):
            (false, Self.wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.wheel), x, y)
        case let .horizontalWheel(rotation, x, y):
            (false, Self.wheelFlags(rotation: rotation, baseFlag: RDPPointerFlags.horizontalWheel), x, y)
        case .synchronize, .unicode, .scancode:
            nil
        }
    }

    // The rotation is a 9-bit two's complement value (WheelRotationMask with PTRFLAGS_WHEEL_NEGATIVE).
    // `wheelEventsSplit` keeps sent rotations in range; the clamp only guards direct encoding.
    private static func wheelFlags(rotation: Int, baseFlag: UInt16) -> UInt16 {
        let clamped = min(255, max(-256, rotation))
        return baseFlag | (UInt16(bitPattern: Int16(clamped)) & RDPPointerFlags.wheelRotationMask)
    }

    private static let maximumWheelRotation = 255
    /// Bounds the events one absurd rotation can produce (about 68 notches).
    private static let maximumSplitWheelEventCount = 32

    /// A wheel rotation one event cannot hold, split into several events; other events unchanged.
    var wheelEventsSplit: [RDPSlowPathInputEvent] {
        switch self {
        case let .verticalWheel(rotation, x, y):
            Self.splitWheelRotation(rotation).map { .verticalWheel(rotation: $0, x: x, y: y) }
        case let .horizontalWheel(rotation, x, y):
            Self.splitWheelRotation(rotation).map { .horizontalWheel(rotation: $0, x: x, y: y) }
        default:
            [self]
        }
    }

    private static func splitWheelRotation(_ rotation: Int) -> [Int] {
        let limit = maximumWheelRotation * maximumSplitWheelEventCount
        var remaining = min(limit, max(-limit, rotation))
        var rotations: [Int] = []
        repeat {
            let next = min(maximumWheelRotation, max(-maximumWheelRotation, remaining))
            rotations.append(next)
            remaining -= next
        } while remaining != 0
        return rotations
    }
}

/// Turns scroll deltas into wheel events, carrying fractions of a rotation unit over to the next
/// call so small trackpad deltas add up. One wheel notch is `unitsPerNotch` rotation units.
public struct RDPScrollWheelAccumulator: Sendable {
    public static let unitsPerNotch = 120.0

    private var verticalRemainder = 0.0
    private var horizontalRemainder = 0.0

    public init() {}

    /// `vertical` is positive for scrolling up and `horizontal` positive for scrolling right, both
    /// in rotation units. `RDPInputSession` splits rotations larger than one event can hold.
    public mutating func events(vertical: Double, horizontal: Double, at point: RDPRemotePoint) -> [RDPSlowPathInputEvent] {
        var events: [RDPSlowPathInputEvent] = []
        if let rotation = Self.wholeRotation(vertical, remainder: &verticalRemainder) {
            events.append(.verticalWheel(rotation: rotation, x: point.x, y: point.y))
        }
        if let rotation = Self.wholeRotation(horizontal, remainder: &horizontalRemainder) {
            events.append(.horizontalWheel(rotation: rotation, x: point.x, y: point.y))
        }
        return events
    }

    private static func wholeRotation(_ units: Double, remainder: inout Double) -> Int? {
        let total = remainder + units
        guard let whole = Int(exactly: total.rounded(.towardZero)) else {
            return nil
        }
        remainder = total - Double(whole)
        return whole == 0 ? nil : whole
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
        lastPointerPoint = point
        return .pointerMove(x: point.x, y: point.y)
    }

    /// A release without a position (for example outside the viewport) is sent at the last pointer location.
    public mutating func pointerButton(
        _ button: RDPPointerButton,
        isDown: Bool,
        at point: RDPRemotePoint?
    ) -> RDPSlowPathInputEvent? {
        let releasePoint = isDown || !pressedPointerButtons.contains(button) ? nil : lastPointerPoint
        guard let point = point ?? releasePoint else {
            return nil
        }

        lastPointerPoint = point
        if isDown {
            pressedPointerButtons.insert(button)
        } else {
            pressedPointerButtons.remove(button)
        }
        return .pointerButton(button: button, isDown: isDown, x: point.x, y: point.y)
    }

    /// A press of a key already down is a repeat, flagged KBDFLAGS_DOWN (MS-RDPBCGR 2.2.8.1.1.3.1.1.1).
    /// Every press marks the key down, so its release is sent even when the first press the server
    /// sees is an auto-repeat, for example one that arrives after focus returned mid-hold.
    public mutating func keyboard(scancode: RDPKeyboardScancode, isReleased: Bool) -> RDPSlowPathInputEvent {
        if isReleased {
            pressedScancodes.remove(scancode)
            return .keyboard(scancode: scancode, isReleased: true)
        }
        let wasDown = pressedScancodes.insert(scancode).inserted == false
        return .keyboard(scancode: scancode, isReleased: false, wasDown: wasDown)
    }

    /// Releases every tracked key and button, for example when the viewer loses focus.
    public mutating func releasePressedInputs() -> [RDPSlowPathInputEvent] {
        let events = pressedInputEvents(isDown: false)
        pressedPointerButtons.removeAll()
        pressedScancodes.removeAll()
        return events
    }

    /// MS-RDPBCGR 2.2.8.1.1.3.1.1.5: a Synchronize event resets the server key state to all keys up
    /// and SHOULD be followed by key-down events for the keyboard keys and mouse buttons still down.
    public func synchronizationEvents(toggleFlags: RDPToggleKeyFlags = []) -> [RDPSlowPathInputEvent] {
        [.synchronize(toggleFlags: toggleFlags)] + pressedInputEvents(isDown: true)
    }

    private func pressedInputEvents(isDown: Bool) -> [RDPSlowPathInputEvent] {
        var events: [RDPSlowPathInputEvent] = []
        if let lastPointerPoint {
            events += RDPPointerButton.allCases
                .filter(pressedPointerButtons.contains)
                .map { .pointerButton(button: $0, isDown: isDown, x: lastPointerPoint.x, y: lastPointerPoint.y) }
        }
        events += pressedScancodes
            .sorted { ($0.code, $0.isExtended ? 1 : 0) < ($1.code, $1.isExtended ? 1 : 0) }
            .map { .keyboard(scancode: $0, isReleased: !isDown) }
        return events
    }
}

/// TS_INPUT_CAPABILITYSET inputFlags ([MS-RDPBCGR] 2.2.7.1.6).
enum RDPInputCapabilityFlags {
    static let scancodes: UInt16 = 0x0001
    static let mouseExtended: UInt16 = 0x0004
    static let fastPathInput: UInt16 = 0x0008
    static let unicode: UInt16 = 0x0010
    static let fastPathInput2: UInt16 = 0x0020
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

    func encodedPDUData(userChannelID: UInt16) -> Data {
        precondition(events.isEmpty == false)
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

        // fpInputHeader carries numEvents only up to 15; otherwise the optional numEvents byte follows the length.
        let usesExplicitEventCount = events.count > 15
        let payloadByteCount = encodedEvents.count + (usesExplicitEventCount ? 1 : 0)
        let usesTwoByteLength = payloadByteCount + 2 >= 128
        let totalByteCount = payloadByteCount + (usesTwoByteLength ? 3 : 2)

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

public final class RDPInputSession: Sendable {
    public let shareID: UInt32
    private let userChannelID: UInt16
    private let ioChannelID: UInt16
    private let channel: Channel
    private let serverInputFlags: UInt16
    private let deactivation = RDPSendCutoff()

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
        self.serverInputFlags = serverInputFlags ?? 0
    }

    public func send(_ event: RDPSlowPathInputEvent) {
        send([event])
    }

    /// Drops events the server's Input Capability Set does not allow and uses fast-path input when advertised
    /// (MS-RDPBCGR 2.2.7.1.6, INPUT_FLAG_FASTPATH_INPUT/INPUT_FLAG_FASTPATH_INPUT2). Sends nothing once the
    /// server has deactivated the session.
    public func send(_ events: [RDPSlowPathInputEvent]) {
        guard !deactivation.isCutOff else {
            return
        }
        let supportedEvents = Self.supportedEvents(events.flatMap(\.wheelEventsSplit), serverInputFlags: serverInputFlags)
        let fastPathFlags = RDPInputCapabilityFlags.fastPathInput | RDPInputCapabilityFlags.fastPathInput2
        guard serverInputFlags & fastPathFlags != 0 else {
            sendSlowPath(supportedEvents)
            return
        }
        for eventChunk in supportedEvents.chunked(maximumCount: RDPFastPathInputPDU.maximumEventsPerPDU) {
            if let packet = RDPFastPathInputPDU(events: eventChunk).encoded() {
                sendPacket(packet)
            } else {
                sendSlowPath(eventChunk)
            }
        }
    }

    /// After Deactivate All the client MUST stop sending input ([MS-RDPBCGR] 3.2.5.5.1); the
    /// reactivation hands out a new session.
    func deactivate() {
        deactivation.cut()
    }

    private func sendSlowPath(_ events: [RDPSlowPathInputEvent]) {
        for eventChunk in events.chunked(maximumCount: RDPClientInputPDU.maximumEventsPerPDU) {
            let packet = RDPClientInputPDU(shareID: shareID, events: eventChunk)
                .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
            sendPacket(packet)
        }
    }

    static func supportedEvents(
        _ events: [RDPSlowPathInputEvent],
        serverInputFlags: UInt16
    ) -> [RDPSlowPathInputEvent] {
        events.filter { event in
            switch event {
            case .unicode:
                serverInputFlags & RDPInputCapabilityFlags.unicode != 0
            case let .pointerButton(button, _, _, _) where button.isExtended:
                serverInputFlags & RDPInputCapabilityFlags.mouseExtended != 0
            case .horizontalWheel:
                serverInputFlags & RDPInputCapabilityFlags.mouseHorizontalWheel != 0
            default:
                true
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

/// Stops a session handed to the app from sending once the server has ended what it sends
/// on; checked from any thread.
final class RDPSendCutoff: @unchecked Sendable {
    private let lock = NSLock()
    private var cutOff = false

    var isCutOff: Bool {
        lock.withLock { cutOff }
    }

    func cut() {
        lock.withLock { cutOff = true }
    }
}

extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0 ..< Swift.min($0 + maximumCount, count)])
        }
    }
}
