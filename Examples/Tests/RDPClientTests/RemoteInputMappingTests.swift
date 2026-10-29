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

/// Character keys without modifiers go as scancodes only when the layout check agrees.
@Test func functionKeysAndModifiedKeysAlwaysSendScancodes() {
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

/// A remote IME commits its candidate with Space, so it goes as its scancode on every layout,
/// and as Unicode only when a dead key composed with it.
@Test func spaceSendsItsScancodeUnlessADeadKeyComposedWithIt() {
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_Space)) == RDPKeyboardScancode(code: 0x39))
    for layout: UInt32 in [0x0000_0409, 0x0000_0407, 0x0000_0419, 0x1234_5678] {
        #expect(windowsTypes(" ", scancode: 0x39, layout: layout))
        #expect(windowsTypes(" ", scancode: 0x39, .shift, layout: layout))
    }
    #expect(windowsTypes("^", ignoringModifiers: " ", scancode: 0x39, layout: 0x0000_0407) == false)
}

private func windowsTypes(
    _ characters: String,
    ignoringModifiers: String? = nil,
    scancode: UInt16,
    _ modifierFlags: NSEvent.ModifierFlags = [],
    layout: UInt32 = 0x0000_0409
) -> Bool {
    MacRDPKeyboardMapping.windowsTypes(
        characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        for: RDPKeyboardScancode(code: scancode),
        modifierFlags: modifierFlags,
        layout: RDPKeyboardLayout(rawValue: layout)
    )
}

@Test func charactersUSWindowsTypesForTheScancodeGoAsScancodes() {
    #expect(windowsTypes("a", scancode: 0x1E))
    #expect(windowsTypes("A", scancode: 0x1E, .shift))
    #expect(windowsTypes(";", scancode: 0x27))
    #expect(windowsTypes(":", scancode: 0x27, .shift))
    #expect(windowsTypes("`", scancode: 0x29))
    // Caps Lock shifts letters only, as on Windows.
    #expect(windowsTypes("A", scancode: 0x1E, .capsLock))
    #expect(windowsTypes("1", scancode: 0x02, .capsLock))
    #expect(windowsTypes("a", scancode: 0x1E, [.capsLock, .shift]))
}

@Test func charactersWindowsTypesDifferentlyGoAsUnicode() {
    // The ISO key between left Shift and Z goes as 0x56, which US Windows types as "\".
    #expect(windowsTypes("`", scancode: 0x56) == false)
    #expect(windowsTypes("§", scancode: 0x29) == false)
    #expect(windowsTypes("a", scancode: 0x1E, .shift) == false)
    #expect(windowsTypes("ab", scancode: 0x1E) == false)
    // A character a dead key composed.
    #expect(windowsTypes("é", ignoringModifiers: "e", scancode: 0x12) == false)
    #expect(windowsTypes("e", ignoringModifiers: "é", scancode: 0x12) == false)
    // JIS keys type nothing with the US layout, and a layout with no table sends Unicode.
    #expect(windowsTypes("¥", scancode: 0x7D) == false)
    #expect(windowsTypes("a", scancode: 0x1E, layout: 0x1234_5678) == false)
}

@Test func theScancodeCheckFollowsTheAnnouncedLayout() {
    // German: QWERTZ, and "^" is a dead key on Windows.
    #expect(windowsTypes("z", scancode: 0x15, layout: 0x0000_0407))
    #expect(windowsTypes("z", scancode: 0x15) == false)
    #expect(windowsTypes("ß", scancode: 0x0C, layout: 0x0000_0407))
    #expect(windowsTypes("<", scancode: 0x56, layout: 0x0000_0407))
    #expect(windowsTypes("^", scancode: 0x29, layout: 0x0000_0407) == false)
    // French (Belgian, what Apple's French maps to) has digits on Shift.
    #expect(windowsTypes("a", scancode: 0x10, layout: 0x0000_080C))
    #expect(windowsTypes("1", scancode: 0x02, .shift, layout: 0x0000_080C))
    #expect(windowsTypes("&", scancode: 0x02, layout: 0x0000_080C))
    // Russian.
    #expect(windowsTypes("ф", scancode: 0x1E, layout: 0x0000_0419))
}

@Test func macInputSourcesMapToWindowsLayoutsWithCapturedTables() {
    func layout(_ name: String) -> UInt32 {
        MacRDPKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.keylayout." + name).rawValue
    }
    #expect(layout("US") == 0x0000_0409)
    #expect(layout("German") == 0x0000_0407)
    #expect(layout("British") == 0x0000_0809)
    #expect(layout("French") == 0x0000_080C)
    #expect(layout("Dvorak") == 0x0001_0409)
    #expect(layout("Australian") == 0x0000_0409)
    #expect(layout("ABC") == 0x0000_0409)
    #expect(MacRDPKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.inputmethod.Kotoeri.Japanese") == .unitedStates)
    // Every layout that can be announced has a table, so the scancode check covers it.
    for klid in Set(MacRDPKeyboardLayout.windowsLayouts.values) {
        #expect(MacRDPWindowsKeyboardLayout.layout(RDPKeyboardLayout(rawValue: klid)) != nil)
    }
    for table in MacRDPWindowsKeyboardLayout.layouts.values {
        #expect(table.unshifted.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
        #expect(table.shifted.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
        #expect(table.capsLock.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
    }
}

@MainActor
@Test func theViewSendsMatchingCharactersAsScancodesAndSpaceAlways() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_Q, characters: "q"))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_Q, characters: "q"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Space, characters: " "))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_Space, characters: " "))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_E, characters: "é", charactersIgnoringModifiers: "e"))
    // A dead key types nothing, and Space after it the accent.
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_6, characters: "", charactersIgnoringModifiers: "^"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Space, characters: "^", charactersIgnoringModifiers: " "))
    view.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_Y, characters: "z"))

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x10), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x10), isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x39), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x39), isReleased: true),
        .unicode(codeUnit: 0xE9, isReleased: false),
        .unicode(codeUnit: 0xE9, isReleased: true),
        .unicode(codeUnit: 0x5E, isReleased: false),
        .unicode(codeUnit: 0x5E, isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x15), isReleased: false),
    ])
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
    charactersIgnoringModifiers: String? = nil,
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
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
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
        .keyboard(scancode: RDPKeyboardScancode(code: 0x2D), isReleased: false),
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

// A drag that leaves the letterboxed desktop holds the pointer on its edge; a plain move there
// sends nothing.
@MainActor
@Test func aDragPastTheDesktopStopsOnItsEdge() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
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
    func event(_ type: NSEvent.EventType, at location: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 180, y: 50)))
    #expect(input.events.isEmpty)
    view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 180, y: 50)))
    view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 10, y: -20)))
    #expect(input.events == [.pointerMove(x: 99, y: 50), .pointerMove(x: 0, y: 99)])
}
