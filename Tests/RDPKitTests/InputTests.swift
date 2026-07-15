import Foundation
import NIOCore
import NIOEmbedded
@testable import RDPKit
import Testing

@Test func pointerMoveInputPDUEncodesSlowPathMouseEvent() {
    let packet = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [.pointerMove(x: 0x1234, y: 0x0056)]
    ).encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet == hexData("""
    03 00 00 30 02 f0 80 64 00 05 03 eb 70 22
    22 00 17 00 ee 03 ee 03 01 00 00 01 14 00 1c 00 00 00
    01 00 00 00 00 00 00 00 01 80 00 08 34 12 56 00
    """))
}

@Test func fastPathInputPDUEncodesAllSupportedEventFamilies() throws {
    let packet = try #require(RDPFastPathInputPDU(events: [
        .synchronize(toggleFlags: [.capsLock]),
        .pointerMove(x: 0x1234, y: 0x0056),
        .pointerButton(button: .extended1, isDown: true, x: 20, y: 30),
        .unicode(codeUnit: 0x0041, isReleased: true),
        .keyboard(
            scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true),
            isReleased: true
        ),
    ]).encoded())

    #expect(packet == hexData("""
    14 16
    64
    20 00 08 34 12 56 00
    40 01 80 14 00 1e 00
    81 41 00
    03 4b
    """))
}

@Test func fastPathInputPDUUsesExplicitEventCountAboveFifteen() throws {
    let events = Array(
        repeating: RDPSlowPathInputEvent.keyboard(
            scancode: RDPKeyboardScancode(code: 0x001E),
            isReleased: false
        ),
        count: 16
    )
    let packet = try #require(RDPFastPathInputPDU(events: events).encoded())

    #expect(packet.prefix(3) == Data([0x00, 0x23, 0x10]))
    #expect(packet.count == 35)
}

@Test func fastPathInputPDUUsesTwoBytePacketLength() throws {
    let events = Array(
        repeating: RDPSlowPathInputEvent.pointerMove(x: 1, y: 2),
        count: 100
    )
    let packet = try #require(RDPFastPathInputPDU(events: events).encoded())

    #expect(packet.prefix(4) == Data([0x00, 0x82, 0xC0, 0x64]))
    #expect(packet.count == 704)
}

@Test func fastPathInputPDURejectsUnrepresentableScancode() {
    let packet = RDPFastPathInputPDU(events: [
        .scancode(code: 0x0100, flags: 0),
    ]).encoded()

    #expect(packet == nil)
}

@Test func inputSessionUsesFastPathOnlyWhenServerAdvertisesIt() throws {
    let fastChannel = EmbeddedChannel()
    try fastChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let fastSession = RDPInputSession(
        shareID: 1,
        userChannelID: 1001,
        ioChannelID: 1003,
        channel: fastChannel,
        serverInputFlags: 0x0020
    )
    fastSession.send(.pointerMove(x: 3, y: 4))
    fastChannel.embeddedEventLoop.run()
    var fastBuffer = try #require(try fastChannel.readOutbound(as: ByteBuffer.self))
    let fastBytes = fastBuffer.readBytes(length: fastBuffer.readableBytes)
    let fastPacket = Data(try #require(fastBytes))

    let slowChannel = EmbeddedChannel()
    try slowChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let slowSession = RDPInputSession(
        shareID: 1,
        userChannelID: 1001,
        ioChannelID: 1003,
        channel: slowChannel,
        serverInputFlags: 0x0001
    )
    slowSession.send(.pointerMove(x: 3, y: 4))
    slowChannel.embeddedEventLoop.run()
    var slowBuffer = try #require(try slowChannel.readOutbound(as: ByteBuffer.self))
    let slowBytes = slowBuffer.readBytes(length: slowBuffer.readableBytes)
    let slowPacket = Data(try #require(slowBytes))

    #expect(fastPacket == Data([0x04, 0x09, 0x20, 0x00, 0x08, 0x03, 0x00, 0x04, 0x00]))
    #expect(slowPacket.first == 0x03)
}

@Test func inputPDUChunksOversizedEventBatches() {
    let maximumEventsPerPDU = RDPClientInputPDU.maximumEventsPerPDU
    let events = Array(
        repeating: RDPSlowPathInputEvent.pointerMove(x: 0, y: 0),
        count: maximumEventsPerPDU + 1
    )

    let chunks = RDPClientInputPDU.eventChunks(events)

    #expect(chunks.map(\.count) == [maximumEventsPerPDU, 1])
    for chunk in chunks {
        let userData = RDPClientInputPDU(shareID: 0x0001_03EE, events: chunk)
            .encodedPDUData(userChannelID: 1006)
        #expect(userData.count <= MCSSendDataRequestPDU.maximumUserDataByteCount)
    }
}

@Test func inputPDUChunksEmptyEventBatchesToNoPDUs() {
    #expect(RDPClientInputPDU.eventChunks([]).isEmpty)
}

@Test func pointerButtonInputPDUEncodesDownAndReleaseEvents() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .pointerButton(button: .left, isDown: true, x: 20, y: 30),
            .pointerButton(button: .left, isDown: false, x: 20, y: 30),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 01 80 00 90 14 00 1e 00
    00 00 00 00 01 80 00 10 14 00 1e 00
    """))
}

@Test func extendedPointerButtonInputPDUEncodesMouseXEvents() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .pointerButton(button: .extended1, isDown: true, x: 20, y: 30),
            .pointerButton(button: .extended2, isDown: false, x: 21, y: 31),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 02 80 01 80 14 00 1e 00
    00 00 00 00 02 80 02 00 15 00 1f 00
    """))
}

@Test func wheelInputPDUEncodesVerticalAndHorizontalEvents() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .verticalWheel(rotation: 120, x: 20, y: 30),
            .horizontalWheel(rotation: -120, x: 20, y: 30),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 01 80 78 02 14 00 1e 00
    00 00 00 00 01 80 88 05 14 00 1e 00
    """))
}

@Test func wheelInputPDUClampsToSignedNineBitRotationMask() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .verticalWheel(rotation: 600, x: 20, y: 30),
            .verticalWheel(rotation: -600, x: 20, y: 30),
            .horizontalWheel(rotation: -1, x: 20, y: 30),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(36) == hexData("""
    00 00 00 00 01 80 ff 02 14 00 1e 00
    00 00 00 00 01 80 00 03 14 00 1e 00
    00 00 00 00 01 80 ff 05 14 00 1e 00
    """))
}

@Test func inputSessionDropsHorizontalWheelWithoutServerCapability() {
    let events: [RDPSlowPathInputEvent] = [
        .verticalWheel(rotation: 120, x: 20, y: 30),
        .horizontalWheel(rotation: 120, x: 20, y: 30),
        .pointerMove(x: 21, y: 31),
    ]

    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: nil) == [
        .verticalWheel(rotation: 120, x: 20, y: 30),
        .pointerMove(x: 21, y: 31),
    ])
    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: 0x0001) == [
        .verticalWheel(rotation: 120, x: 20, y: 30),
        .pointerMove(x: 21, y: 31),
    ])
    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: 0x0100) == events)
}

@Test func inputSessionDropsUnicodeAndExtendedMouseWithoutServerCapabilities() {
    let events: [RDPSlowPathInputEvent] = [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false),
        .unicode(codeUnit: 0x0041, isReleased: false),
        .pointerButton(button: .left, isDown: true, x: 20, y: 30),
        .pointerButton(button: .extended1, isDown: true, x: 20, y: 30),
    ]

    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: nil) == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false),
        .pointerButton(button: .left, isDown: true, x: 20, y: 30),
    ])
    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: 0x0001) == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false),
        .pointerButton(button: .left, isDown: true, x: 20, y: 30),
    ])
    #expect(RDPInputSession.supportedEvents(events, serverInputFlags: 0x0015) == events)
}

@Test func synchronizeInputPDUEncodesToggleFlags() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .synchronize(toggleFlags: [.numLock, .capsLock]),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(12) == hexData("""
    00 00 00 00 00 00 00 00 06 00 00 00
    """))
}

@Test func unicodeInputPDUEncodesDownAndReleaseCodeUnits() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .unicode(codeUnit: 0x0041, isReleased: false),
            .unicode(codeUnit: 0x0041, isReleased: true),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 05 00 00 00 41 00 00 00
    00 00 00 00 05 00 00 80 41 00 00 00
    """))
}

@Test func keyboardScancodeInputPDUEncodesPressAndReleaseFlags() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: true),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 04 00 00 00 1c 00 00 00
    00 00 00 00 04 00 00 80 1c 00 00 00
    """))
}

@Test func keyboardScancodeInputPDUEncodesExtendedFlag() {
    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: false),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: true),
        ]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(24) == hexData("""
    00 00 00 00 04 00 00 01 4b 00 00 00
    00 00 00 00 04 00 00 81 4b 00 00 00
    """))
}

@Test func keyboardRepeatInputPDUEncodesWasDownFlag() {
    var tracker = RDPInputStateTracker()
    let scancode = RDPKeyboardScancode(code: 0x001E)
    _ = tracker.keyboard(scancode: scancode, isReleased: false)
    let repeatEvent = tracker.keyboard(scancode: scancode, isReleased: false, isRepeat: true)

    let data = RDPClientInputPDU(
        shareID: 0x0001_03EE,
        events: [repeatEvent]
    ).encodedPDUData(userChannelID: 1006)

    #expect(data.suffix(12) == hexData("""
    00 00 00 00 04 00 00 40 1e 00 00 00
    """))
    #expect(tracker.releasePressedScancodes() == [
        .keyboard(scancode: scancode, isReleased: true),
    ])
}

@Test func inputStateTrackerUsesLastPointerPointForButtonRelease() {
    var tracker = RDPInputStateTracker()

    let downEvent = tracker.pointerButton(.left, isDown: true, at: RDPRemotePoint(x: 20, y: 30))
    let upEvent = tracker.pointerButton(.left, isDown: false, at: nil)

    #expect(downEvent == .pointerButton(button: .left, isDown: true, x: 20, y: 30))
    #expect(upEvent == .pointerButton(button: .left, isDown: false, x: 20, y: 30))
    #expect(tracker.isPointerButtonPressed(.left) == false)
}

@Test func inputStateTrackerIgnoresUnpositionedPointerPress() {
    var tracker = RDPInputStateTracker()

    let event = tracker.pointerButton(.left, isDown: true, at: nil)

    #expect(event == nil)
    #expect(tracker.isPointerButtonPressed(.left) == false)
}

@Test func inputStateTrackerReleasesPressedInputsInStableOrder() {
    var tracker = RDPInputStateTracker()
    let point = RDPRemotePoint(x: 40, y: 50)

    _ = tracker.pointerButton(.right, isDown: true, at: point)
    _ = tracker.pointerButton(.left, isDown: true, at: point)
    _ = tracker.pointerButton(.middle, isDown: true, at: point)
    _ = tracker.keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false)
    _ = tracker.keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: false)

    #expect(tracker.releasePressedInputs() == [
        .pointerButton(button: .left, isDown: false, x: 40, y: 50),
        .pointerButton(button: .middle, isDown: false, x: 40, y: 50),
        .pointerButton(button: .right, isDown: false, x: 40, y: 50),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: true),
    ])
    #expect(tracker.releasePressedInputs().isEmpty)
}

@Test func inputStateTrackerDoesNotTreatKeyboardRepeatsAsNewPresses() {
    var tracker = RDPInputStateTracker()
    let scancode = RDPKeyboardScancode(code: 0x001E)

    _ = tracker.keyboard(scancode: scancode, isReleased: false)
    _ = tracker.keyboard(scancode: scancode, isReleased: false, isRepeat: true)

    #expect(tracker.isScancodePressed(scancode))
    #expect(tracker.releasePressedScancodes() == [
        .keyboard(scancode: scancode, isReleased: true),
    ])
    #expect(tracker.isScancodePressed(scancode) == false)
}

@Test func inputStateTrackerBuildsSynchronizationSequenceForPressedInputs() {
    var tracker = RDPInputStateTracker()
    let point = RDPRemotePoint(x: 40, y: 50)

    _ = tracker.pointerButton(.right, isDown: true, at: point)
    _ = tracker.pointerButton(.left, isDown: true, at: point)
    _ = tracker.keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false)
    _ = tracker.keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: false)

    #expect(tracker.synchronizationEvents(toggleFlags: [.capsLock]) == [
        .synchronize(toggleFlags: [.capsLock]),
        .pointerButton(button: .left, isDown: true, x: 40, y: 50),
        .pointerButton(button: .right, isDown: true, x: 40, y: 50),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x001C), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x004B, isExtended: true), isReleased: false),
    ])
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
