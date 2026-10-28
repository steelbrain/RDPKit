import AppKit
import Carbon.HIToolbox
@testable import RDPClient
import RDPKit
import Testing

@Test func modifierKeysTrackEachSideFromDeviceFlags() throws {
    let leftShift = try #require(MacRDPModifierKey(keyCode: UInt16(kVK_Shift)))
    let rightShift = try #require(MacRDPModifierKey(keyCode: UInt16(kVK_RightShift)))
    let bothDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2 | 0x4)
    let onlyRightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)

    #expect(leftShift.isDown(in: bothDown))
    #expect(rightShift.isDown(in: bothDown))
    #expect(leftShift.isDown(in: onlyRightDown) == false)
    #expect(rightShift.isDown(in: onlyRightDown))
    #expect(leftShift.isDown(in: []) == false)
}

@Test func modifierKeysFallBackToSideIndependentFlags() throws {
    let control = try #require(MacRDPModifierKey(keyCode: UInt16(kVK_Control)))

    #expect(control.isDown(in: .control))
    #expect(control.isDown(in: []) == false)
}

@Test func rightSideAndCommandModifiersUseExtendedScancodes() throws {
    let expected: [Int: RDPKeyboardScancode] = [
        kVK_RightControl: RDPKeyboardScancode(code: 0x1D, isExtended: true),
        kVK_RightOption: RDPKeyboardScancode(code: 0x38, isExtended: true),
        kVK_Command: RDPKeyboardScancode(code: 0x5B, isExtended: true),
        kVK_RightCommand: RDPKeyboardScancode(code: 0x5C, isExtended: true),
        kVK_RightShift: RDPKeyboardScancode(code: 0x36),
    ]
    for (keyCode, scancode) in expected {
        #expect(try #require(MacRDPModifierKey(keyCode: UInt16(keyCode))).scancode == scancode)
    }
}

@Test func navigationAndKeypadKeysMapToExtendedScancodes() {
    let expected: [Int: RDPKeyboardScancode] = [
        kVK_UpArrow: RDPKeyboardScancode(code: 0x48, isExtended: true),
        kVK_Help: RDPKeyboardScancode(code: 0x52, isExtended: true),
        kVK_ForwardDelete: RDPKeyboardScancode(code: 0x53, isExtended: true),
        kVK_PageDown: RDPKeyboardScancode(code: 0x51, isExtended: true),
        kVK_ANSI_KeypadEnter: RDPKeyboardScancode(code: 0x1C, isExtended: true),
        kVK_ANSI_KeypadDivide: RDPKeyboardScancode(code: 0x35, isExtended: true),
        kVK_ContextualMenu: RDPKeyboardScancode(code: 0x5D, isExtended: true),
        kVK_ISO_Section: RDPKeyboardScancode(code: 0x29),
        kVK_F13: RDPKeyboardScancode(code: 0x64),
    ]
    for (keyCode, scancode) in expected {
        #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(keyCode)) == scancode)
    }
}

@Test func functionKeysAlwaysSendScancodesWhileCharactersUseUnicode() {
    #expect(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_F2), modifierFlags: []))
    #expect(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_F4), modifierFlags: []))
    #expect(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_ANSI_A), modifierFlags: []) == false)
    #expect(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_ANSI_A), modifierFlags: .option))
}

@Test func unicodeEventsSkipAppKitFunctionKeyCharacters() {
    let functionKey = String(utf16CodeUnits: [0xF705], count: 1)

    #expect(MacRDPKeyboardMapping.unicodeEvents(for: functionKey).isEmpty)
    #expect(MacRDPKeyboardMapping.unicodeEvents(for: "a") == [
        .unicode(codeUnit: 0x61, isReleased: false),
        .unicode(codeUnit: 0x61, isReleased: true),
    ])
}

@Test func focusSynchronizationKeepsNumLockOnAndMirrorsCapsLock() {
    #expect(MacRDPKeyboardMapping.toggleFlags(for: []) == [.numLock])
    #expect(MacRDPKeyboardMapping.toggleFlags(for: [.capsLock, .shift]) == [.numLock, .capsLock])
}

@Test func horizontalScrollUsesRDPRightPositiveDirection() {
    var accumulator = RDPScrollWheelAccumulator()
    let point = RDPRemotePoint(x: 10, y: 20)

    #expect(accumulator.events(deltaX: 1, deltaY: 1, hasPreciseScrollingDeltas: false, at: point) == [
        .verticalWheel(rotation: 120, x: 10, y: 20),
        .horizontalWheel(rotation: -120, x: 10, y: 20),
    ])
}

@Test func preciseScrollAccumulatesFractionalDeltas() {
    var accumulator = RDPScrollWheelAccumulator()
    let point = RDPRemotePoint(x: 0, y: 0)

    #expect(accumulator.events(deltaX: 0, deltaY: 0.06, hasPreciseScrollingDeltas: true, at: point).isEmpty)
    #expect(accumulator.events(deltaX: 0, deltaY: 0.06, hasPreciseScrollingDeltas: true, at: point) == [
        .verticalWheel(rotation: 1, x: 0, y: 0),
    ])
}

@Test func largeScrollDeltasSplitIntoEncodableRotations() {
    var accumulator = RDPScrollWheelAccumulator()
    let point = RDPRemotePoint(x: 0, y: 0)

    #expect(accumulator.events(deltaX: 0, deltaY: -5, hasPreciseScrollingDeltas: false, at: point) == [
        .verticalWheel(rotation: -255, x: 0, y: 0),
        .verticalWheel(rotation: -255, x: 0, y: 0),
        .verticalWheel(rotation: -90, x: 0, y: 0),
    ])
}
