import Foundation
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
    00 00 00 00 01 80 78 05 14 00 1e 00
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

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
