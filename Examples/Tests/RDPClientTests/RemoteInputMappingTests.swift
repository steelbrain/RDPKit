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

@Test func releasingTheLastSideOfAModifierWithoutSideBitsReleasesBothSides() throws {
    let leftShift = try #require(MacRDPModifierKey(keyCode: UInt16(kVK_Shift)))
    let rightShift = try #require(MacRDPModifierKey(keyCode: UInt16(kVK_RightShift)))
    let bothPressed: (RDPKeyboardScancode) -> Bool = { _ in true }

    // With no side bits, releasing one Shift leaves .shift set, so nothing tells which side it was.
    #expect(leftShift.changes(in: .shift, isPressed: bothPressed).isEmpty)
    let release = rightShift.changes(in: [], isPressed: bothPressed)
    #expect(release.map(\.scancode) == [RDPKeyboardScancode(code: 0x36), RDPKeyboardScancode(code: 0x2A)])
    #expect(release.allSatisfy { $0.isDown == false })
    #expect(leftShift.changes(in: .shift) { _ in false }.map(\.scancode) == [RDPKeyboardScancode(code: 0x2A)])
}

@Test func commandSendsWindowsKeyOnlyWithAnotherKeyOrAsATap() {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    var inputState = RDPInputStateTracker()
    var windowsKey = MacRDPDeferredWindowsKey()

    // Command released alone: a Win tap.
    windowsKey.press(leftWindows)
    #expect(windowsKey.release(leftWindows) == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .keyboard(scancode: leftWindows, isReleased: true),
    ])

    // Another key while Command is held: Win down goes first and is then tracked as pressed.
    windowsKey.press(leftWindows)
    #expect(windowsKey.flush(&inputState) == [.keyboard(scancode: leftWindows, isReleased: false)])
    #expect(inputState.isScancodePressed(leftWindows))
    #expect(windowsKey.release(leftWindows).isEmpty)

    // A shortcut handled locally (only its key-up seen), or focus loss: nothing at all.
    windowsKey.press(leftWindows)
    windowsKey.noteChordedElsewhere()
    #expect(windowsKey.release(leftWindows).isEmpty)
    windowsKey.press(leftWindows)
    windowsKey.reset()
    #expect(windowsKey.isHeld(leftWindows) == false)
}

/// The key ANSI keyboards have left of "1" sits between left Shift and Z on ISO keyboards.
@Test func graveKeyCodeFollowsTheKeyboardType() {
    let graveKey = UInt16(kVK_ANSI_Grave)
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: false) == RDPKeyboardScancode(code: 0x29))
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: true) == RDPKeyboardScancode(code: 0x56))
    let sectionKey = UInt16(kVK_ISO_Section)
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: sectionKey, isISOKeyboard: true) == RDPKeyboardScancode(code: 0x29))
}

@Test func keypadClearDoesNotSendNumLock() {
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_KeypadClear)) == nil)
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
    func sendsScancode(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        MacRDPKeyboardMapping.shouldSendScancode(
            forKeyCode: UInt16(keyCode),
            modifierFlags: modifierFlags,
            isHeldAsScancode: false
        )
    }
    #expect(sendsScancode(kVK_F2, []))
    #expect(sendsScancode(kVK_F4, []))
    #expect(sendsScancode(kVK_ANSI_A, []) == false)
    #expect(sendsScancode(kVK_ANSI_A, .option))
}

@Test func aKeyHeldAsAScancodeRepeatsAsThatScancodeAfterItsModifierIsReleased() {
    #expect(MacRDPKeyboardMapping.shouldSendScancode(
        forKeyCode: UInt16(kVK_ANSI_C),
        modifierFlags: [],
        isHeldAsScancode: true
    ))
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

@Test func scrollDeltasConvertToRDPRotationUnits() {
    let lines = MacRDPScrollWheel.rotationUnits(deltaX: 1, deltaY: 1, hasPreciseScrollingDeltas: false)
    let points = MacRDPScrollWheel.rotationUnits(deltaX: -0.5, deltaY: 2, hasPreciseScrollingDeltas: true)

    #expect(lines.vertical == 120 && lines.horizontal == -120)
    #expect(points.vertical == 20 && points.horizontal == 5)
}

private final class RecordedInput: RDPInputEventSending {
    var events: [RDPSlowPathInputEvent] = []

    func send(_ events: [RDPSlowPathInputEvent]) {
        self.events += events
    }
}

@MainActor
private func keyEvent(
    _ type: NSEvent.EventType,
    keyCode: Int,
    characters: String = "",
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: UInt16(keyCode)
    ))
}

@MainActor
@Test func keysHeldWhenTheViewLosesFocusAreReleased() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Shift, modifierFlags: .shift))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_DownArrow, modifierFlags: .shift))
    input.events.removeAll()

    _ = view.resignFirstResponder()

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x2A), isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x50, isExtended: true), isReleased: true),
    ])
}

// A modifier released while a menu is open never reaches the view as flagsChanged.
@MainActor
@Test func aModifierReleaseTheViewMissedIsSentBeforeTheNextEvent() throws {
    let leftControl = RDPKeyboardScancode(code: 0x1D)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    view.rdpFrame = RDPFrameMetadata(RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "test",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 100, bottom: 100),
        regionRects: [],
        encodedVideoData: Data()
    ))

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Control, modifierFlags: .control))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_X, characters: "x"))
    #expect(input.events == [
        .keyboard(scancode: leftControl, isReleased: false),
        .keyboard(scancode: leftControl, isReleased: true),
        .unicode(codeUnit: 0x78, isReleased: false),
        .unicode(codeUnit: 0x78, isReleased: true),
    ])

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Control, modifierFlags: .control))
    input.events.removeAll()
    view.mouseDown(with: try #require(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: CGPoint(x: 10, y: 90),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )))
    #expect(input.events == [
        .keyboard(scancode: leftControl, isReleased: true),
        .pointerButton(button: .left, isDown: true, x: 10, y: 10),
    ])
}

// Command released while another app (Spotlight) had the keyboard: Win never reached the
// server, so the next key must not take it down there.
@MainActor
@Test func aCommandReleaseTheViewMissedDropsTheDeferredWindowsKey() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command, modifierFlags: .command))

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_LeftArrow))

    #expect(input.events == [.keyboard(scancode: RDPKeyboardScancode(code: 0x4B, isExtended: true), isReleased: false)])
}

@MainActor
@Test func commandReleasedAloneStillTapsTheWindowsKey() throws {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command, modifierFlags: .command))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command))

    #expect(input.events == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .keyboard(scancode: leftWindows, isReleased: true),
    ])
}
