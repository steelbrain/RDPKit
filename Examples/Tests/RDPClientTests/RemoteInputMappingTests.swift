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
    let nothingDown = RDPInputStateTracker()
    var inputState = RDPInputStateTracker()
    var windowsKey = MacRDPDeferredModifierKeys()

    // Command released alone: a Win tap.
    windowsKey.press(leftWindows, inputState: nothingDown)
    #expect(windowsKey.release(leftWindows) == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .keyboard(scancode: leftWindows, isReleased: true),
    ])

    // Another key while Command is held: Win down goes first and is then tracked as pressed.
    windowsKey.press(leftWindows, inputState: nothingDown)
    #expect(windowsKey.flush(&inputState) == [.keyboard(scancode: leftWindows, isReleased: false)])
    #expect(inputState.isScancodePressed(leftWindows))
    #expect(windowsKey.release(leftWindows).isEmpty)

    // A shortcut handled locally (only its key-up seen), or focus loss: nothing at all.
    windowsKey.press(leftWindows, inputState: nothingDown)
    windowsKey.noteChordedElsewhere()
    #expect(windowsKey.release(leftWindows).isEmpty)
    windowsKey.press(leftWindows, inputState: nothingDown)
    windowsKey.reset()
    #expect(windowsKey.isHeld(leftWindows) == false)
}

/// Shift and the other modifiers send held Windows keys ahead of them, but not Alt, since
/// Option-Shift types characters too.
@Test func rightAltIsHeldBackLikeTheWindowsKeyButNotSentAheadOfModifiers() {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let nothingDown = RDPInputStateTracker()
    var inputState = RDPInputStateTracker()
    var heldKeys = MacRDPDeferredModifierKeys()
    #expect(MacRDPDeferredModifierKeys.isDeferred(rightAlt))
    #expect(MacRDPDeferredModifierKeys.isDeferred(RDPKeyboardScancode(code: 0x38)) == false)

    // Released alone: an Alt tap; ahead of another key: Alt down.
    heldKeys.press(rightAlt, inputState: nothingDown)
    #expect(heldKeys.release(rightAlt) == [
        .keyboard(scancode: rightAlt, isReleased: false),
        .keyboard(scancode: rightAlt, isReleased: true),
    ])
    heldKeys.press(rightAlt, inputState: nothingDown)
    #expect(heldKeys.flush(&inputState) == [.keyboard(scancode: rightAlt, isReleased: false)])
    #expect(inputState.isScancodePressed(rightAlt))

    // Ahead of Shift: Win goes, Alt stays held back, and releasing it is no tap.
    heldKeys.press(leftWindows, inputState: nothingDown)
    heldKeys.press(rightAlt, inputState: nothingDown)
    #expect(heldKeys.flushWindowsKeys(&inputState) == [.keyboard(scancode: leftWindows, isReleased: false)])
    #expect(heldKeys.isHeld(rightAlt))
    #expect(heldKeys.release(rightAlt).isEmpty)
    heldKeys.press(rightAlt, inputState: nothingDown)
    #expect(heldKeys.flushWindowsKeys(&inputState).isEmpty)
    #expect(heldKeys.release(rightAlt).isEmpty)

    // Held back together, as in Cmd-Option-Esc, which the server never sees: no taps.
    heldKeys.press(leftWindows, inputState: nothingDown)
    heldKeys.press(rightAlt, inputState: nothingDown)
    #expect(heldKeys.release(rightAlt).isEmpty)
    #expect(heldKeys.release(leftWindows).isEmpty)
}

/// Command-click sends Win, so the other Command or right Option pressed while that Win is
/// down is a chord too, and the same goes the other way round: released alone, it sends
/// nothing rather than a tap, and with another key it still goes down ahead of it.
@Test func aKeyHeldBackWhileAnotherIsOnTheServerIsNoTap() {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let rightWindows = RDPKeyboardScancode(code: 0x5C, isExtended: true)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    for (first, second) in [(leftWindows, rightWindows), (leftWindows, rightAlt), (rightAlt, leftWindows)] {
        var inputState = RDPInputStateTracker()
        var heldKeys = MacRDPDeferredModifierKeys()
        heldKeys.press(first, inputState: inputState)
        #expect(heldKeys.flush(&inputState) == [.keyboard(scancode: first, isReleased: false)])

        heldKeys.press(second, inputState: inputState)
        #expect(heldKeys.release(second).isEmpty)
        heldKeys.press(second, inputState: inputState)
        #expect(heldKeys.flush(&inputState) == [.keyboard(scancode: second, isReleased: false)])
    }
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

/// Eisu and Kana go as LANG2 and LANG1 whatever the Mac types with them (a space), or with
/// Windows' Japanese layout as its 英数 and ひらがな keys, and Yen and Ro as the PC JIS keys,
/// where the layout check decides.
@Test func jisKeysMapToThePCJISScancodes() {
    let expected: [Int: RDPKeyboardScancode] = [
        kVK_JIS_Eisu: RDPKeyboardScancode(code: 0x71),
        kVK_JIS_Kana: RDPKeyboardScancode(code: 0x72),
        kVK_JIS_Yen: RDPKeyboardScancode(code: 0x7D),
        kVK_JIS_Underscore: RDPKeyboardScancode(code: 0x73),
    ]
    for (keyCode, scancode) in expected {
        #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(keyCode)) == scancode)
    }
    let japanese = MacRDPKeyboardLayout.japanese
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_JIS_Eisu), layout: japanese) == RDPKeyboardScancode(code: 0x3A))
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_JIS_Kana), layout: japanese) == RDPKeyboardScancode(code: 0x70))
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_JIS_Yen), layout: japanese) == RDPKeyboardScancode(code: 0x7D))
    #expect(sendsScancode(kVK_JIS_Eisu, [], characters: " "))
    #expect(sendsScancode(kVK_JIS_Kana, [], characters: " "))
    #expect(sendsScancode(kVK_JIS_Yen, [], characters: "¥") == false)
    #expect(sendsScancode(kVK_JIS_Underscore, [], characters: "_") == false)
}

private func sendsScancode(
    _ keyCode: Int,
    _ modifierFlags: NSEvent.ModifierFlags,
    characters: String = "a",
    ignoringModifiers: String? = nil,
    isHeldAsScancode: Bool = false,
    isAltPressed: Bool = false
) -> Bool {
    MacRDPKeyboardMapping.shouldSendScancode(
        forKeyCode: UInt16(keyCode),
        characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        modifierFlags: modifierFlags,
        isHeldAsScancode: isHeldAsScancode,
        isAltPressed: isAltPressed
    )
}

/// Character keys without modifiers go as scancodes only when the layout check agrees.
@Test func functionKeysAndModifiedKeysAlwaysSendScancodes() {
    #expect(sendsScancode(kVK_F2, [], characters: "\u{F705}"))
    #expect(sendsScancode(kVK_F4, [], characters: "\u{F707}"))
    #expect(sendsScancode(kVK_ANSI_A, []) == false)
    #expect(sendsScancode(kVK_ANSI_A, .control, characters: "\u{1}", ignoringModifiers: "a"))
    #expect(sendsScancode(kVK_ANSI_A, .option))
}

/// Right Option is held back, so Option with no Alt on the server types what the Mac layout
/// puts on the key ("@" is Option-L on German); with Alt there, or with Command or Control, the
/// key goes as its scancode.
@Test func optionTypesTheMacLayoutsCharactersUnlessAltIsOnTheServer() {
    #expect(sendsScancode(kVK_ANSI_L, .option, characters: "@", ignoringModifiers: "l") == false)
    #expect(sendsScancode(kVK_ANSI_7, [.option, .shift], characters: "\\", ignoringModifiers: "/") == false)
    // A dead key types nothing; the next key types its accent.
    #expect(sendsScancode(kVK_ANSI_E, .option, characters: "", ignoringModifiers: "e") == false)

    #expect(sendsScancode(kVK_ANSI_L, .option, characters: "@", ignoringModifiers: "l", isAltPressed: true))
    #expect(sendsScancode(kVK_ANSI_L, [.option, .command], characters: "@", ignoringModifiers: "l"))
    #expect(sendsScancode(kVK_ANSI_L, .option, characters: "@", ignoringModifiers: "l", isHeldAsScancode: true))
    #expect(sendsScancode(kVK_LeftArrow, .option, characters: "\u{F702}"))
    #expect(MacRDPKeyboardMapping.optionTypes("\u{F702}", charactersIgnoringModifiers: "\u{F703}") == false)
    #expect(MacRDPKeyboardMapping.optionTypes("\u{1B}", charactersIgnoringModifiers: "a") == false)
}

/// PC keypads have no "=", and German has a dead key where the main "=" key is.
@Test func keypadEqualsSendsTheEqualsKeyScancodeOnlyWhereTheLayoutTypesIt() {
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_KeypadEquals)) == RDPKeyboardScancode(code: 0x0D))
    #expect(sendsScancode(kVK_ANSI_KeypadEquals, [], characters: "=") == false)
    #expect(windowsTypes("=", scancode: 0x0D))
    #expect(windowsTypes("=", scancode: 0x0D, layout: 0x0000_0407) == false)
    #expect(windowsTypes("=", scancode: 0x0D, .shift) == false)
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

/// Windows' Japanese layout (106/109-key) types the JIS legends, as macOS does on a JIS
/// keyboard, so those keys go as scancodes.
@Test func theJapaneseTableTypesTheJISLegends() {
    let japanese: UInt32 = 0x0000_0411
    let unshifted: [(String, UInt16)] = [
        ("2", 0x03), ("-", 0x0C), ("^", 0x0D), ("q", 0x10), ("@", 0x1A), ("[", 0x1B),
        (";", 0x27), (":", 0x28), ("]", 0x2B), ("/", 0x35), ("\\", 0x73), ("\\", 0x7D),
    ]
    for (characters, scancode) in unshifted {
        #expect(windowsTypes(characters, scancode: scancode, layout: japanese))
    }
    let shifted: [(String, UInt16)] = [
        ("\"", 0x03), ("&", 0x07), ("'", 0x08), ("=", 0x0C), ("~", 0x0D), ("Q", 0x10), ("`", 0x1A),
        ("{", 0x1B), ("+", 0x27), ("*", 0x28), ("}", 0x2B), ("?", 0x35), ("_", 0x73), ("|", 0x7D),
    ]
    for (characters, scancode) in shifted {
        #expect(windowsTypes(characters, scancode: scancode, .shift, layout: japanese))
    }
    #expect(windowsTypes("Q", scancode: 0x10, .capsLock, layout: japanese))
    // What US types on those keys goes as Unicode, as does what Windows types nothing for:
    // Shift-0 (the Mac types "0"), and Hankaku/Zenkaku where ANSI keyboards have "`".
    #expect(windowsTypes("@", scancode: 0x03, .shift, layout: japanese) == false)
    #expect(windowsTypes("=", scancode: 0x0D, layout: japanese) == false)
    #expect(windowsTypes("0", scancode: 0x0B, .shift, layout: japanese) == false)
    #expect(windowsTypes("`", scancode: 0x29, layout: japanese) == false)
    // The Mac's Yen key types "¥" (U+00A5), not the "\" Windows types there, and its Ro key
    // types "_" without Shift too.
    #expect(windowsTypes("¥", scancode: 0x7D, layout: japanese) == false)
    #expect(windowsTypes("_", scancode: 0x73, layout: japanese) == false)
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
    #expect(MacRDPWindowsKeyboardLayout.layout(MacRDPKeyboardLayout.japanese) != nil)
    for table in MacRDPWindowsKeyboardLayout.layouts.values {
        #expect(table.unshifted.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
        #expect(table.shifted.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
        #expect(table.capsLock.unicodeScalars.count == MacRDPWindowsKeyboardLayout.scancodes.count)
    }
}

/// A Japanese input source gets Windows' Japanese layout on any keyboard, and a JIS keyboard
/// gets it in place of US English, but keeps other layouts; Japanese goes as a 106/109-key
/// keyboard, the one its table describes.
@Test func japaneseInputSourcesAndJISKeyboardsAnnounceTheJapaneseKeyboard() {
    let japanese = MacRDPKeyboardLayout.japanese
    let german = RDPKeyboardLayout(rawValue: 0x0000_0407)
    let korean = RDPKeyboardLayout(rawValue: 0x0000_0412)
    func layout(_ inputSourceLayout: RDPKeyboardLayout, isJapanese: Bool, isJIS: Bool) -> RDPKeyboardLayout {
        MacRDPKeyboardLayout.windowsLayout(inputSourceLayout, isJapaneseInputSource: isJapanese, isJISKeyboard: isJIS)
    }
    #expect(layout(.unitedStates, isJapanese: true, isJIS: true) == japanese)
    #expect(layout(.unitedStates, isJapanese: true, isJIS: false) == japanese)
    #expect(layout(german, isJapanese: true, isJIS: false) == japanese)
    #expect(layout(.unitedStates, isJapanese: false, isJIS: true) == japanese)
    #expect(layout(german, isJapanese: false, isJIS: true) == german)
    #expect(layout(korean, isJapanese: false, isJIS: true) == korean)
    #expect(layout(.unitedStates, isJapanese: false, isJIS: false) == .unitedStates)

    #expect(MacRDPKeyboardLayout.keyboardType(for: japanese) == .japanese)
    #expect(MacRDPKeyboardLayout.keyboardSubType(for: japanese) == 2)
    #expect(MacRDPKeyboardLayout.keyboardType(for: .unitedStates) == .ibmEnhanced)
    #expect(MacRDPKeyboardLayout.keyboardSubType(for: korean) == 0)
}

/// Apple's Japanese input method counts in every mode, though its Latin mode (英字) reports
/// English; other sources count when their first language is Japanese.
@Test func japaneseInputSourcesAreRecognized() {
    func isJapanese(_ identifier: String, _ languages: [String]) -> Bool {
        MacRDPKeyboardLayout.isJapanese(inputSourceID: identifier, languages: languages)
    }
    #expect(isJapanese("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", ["ja"]))
    #expect(isJapanese("com.apple.inputmethod.Kotoeri.RomajiTyping.Roman", ["en"]))
    #expect(isJapanese("com.apple.inputmethod.Kotoeri.KanaTyping.Japanese.Katakana", ["ja"]))
    #expect(isJapanese("com.example.inputmethod.Japanese", ["ja", "en"]))
    #expect(isJapanese("com.apple.keylayout.ABC", ["en", "fr"]) == false)
    #expect(isJapanese("com.apple.inputmethod.Korean.2SetKorean", ["ko"]) == false)
    #expect(isJapanese("com.example.inputmethod.Multilingual", ["en", "ja"]) == false)
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

/// What macOS types on a JIS keyboard, with Windows' Japanese layout announced.
@MainActor
@Test func theViewSendsJISKeysAsTheJapaneseLayoutTypesThem() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboardLayout = MacRDPKeyboardLayout.japanese

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Kana, characters: " "))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_JIS_Kana, characters: " "))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_LeftBracket, characters: "@"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Yen, characters: "¥"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Yen, characters: "|", modifierFlags: .shift))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Eisu, characters: " "))

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x70), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x70), isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x1A), isReleased: false),
        .unicode(codeUnit: 0xA5, isReleased: false),
        .unicode(codeUnit: 0xA5, isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x7D), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x3A), isReleased: false),
    ])
}

@Test func aKeyHeldAsAScancodeRepeatsAsThatScancodeAfterItsModifierIsReleased() {
    #expect(sendsScancode(kVK_ANSI_C, [], characters: "c", isHeldAsScancode: true))
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
    modifierFlags: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false
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
        isARepeat: isARepeat,
        keyCode: UInt16(keyCode)
    ))
}

/// After a dead key, macOS puts its accent ahead of the control character Return, Tab, Esc and
/// keypad Enter type; those keys go as scancodes, so the accent goes as Unicode first.
@Test func deadKeyTextAheadOfAControlCharacterIsFound() {
    #expect(MacRDPKeyboardMapping.deadKeyText(aheadOf: "´\r") == "´")
    #expect(MacRDPKeyboardMapping.deadKeyText(aheadOf: "´\t") == "´")
    #expect(MacRDPKeyboardMapping.deadKeyText(aheadOf: "´\u{1B}") == "´")
    #expect(MacRDPKeyboardMapping.deadKeyText(aheadOf: "^\u{03}") == "^")
    for characters: String? in [nil, "", "\r", "a", "´", "´a", "´\r\r", "\r´", "\u{F702}", "\u{F702}\r", "\u{F728}"] {
        #expect(MacRDPKeyboardMapping.deadKeyText(aheadOf: characters) == nil)
    }
}

@MainActor
@Test func aDeadKeysAccentGoesAheadOfReturnTabEscAndKeypadEnter() throws {
    let returnKey = RDPKeyboardScancode(code: 0x1C)
    let accent = RDPSlowPathInputEvent.unicode(codeUnit: 0xB4, isReleased: false)
    let accentUp = RDPSlowPathInputEvent.unicode(codeUnit: 0xB4, isReleased: true)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input

    // US Option-E, then Return; its repeat and key-up send the key alone.
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Return, characters: "´\r", charactersIgnoringModifiers: "\r"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Return, characters: "´\r", isARepeat: true))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_Return, characters: "\r"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Tab, characters: "´\t"))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_Tab, characters: "\t"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Escape, characters: "´\u{1B}"))
    // German "^", then keypad Enter.
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_KeypadEnter, characters: "^\u{03}"))
    // With Control, which types no text, the key goes alone.
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_Tab, characters: "´\t", modifierFlags: .control))

    #expect(input.events == [
        accent, accentUp, .keyboard(scancode: returnKey, isReleased: false),
        .keyboard(scancode: returnKey, isReleased: false, wasDown: true),
        .keyboard(scancode: returnKey, isReleased: true),
        accent, accentUp, .keyboard(scancode: RDPKeyboardScancode(code: 0x0F), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x0F), isReleased: true),
        accent, accentUp, .keyboard(scancode: RDPKeyboardScancode(code: 0x01), isReleased: false),
        .unicode(codeUnit: 0x5E, isReleased: false),
        .unicode(codeUnit: 0x5E, isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x1C, isExtended: true), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x0F), isReleased: false),
    ])
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

// Command-click sends Win, and the other Command or right Option tapped while it is down must not
// send a lone tap; nor must Command after Option-click sent Alt. Chords with a key still go.
@MainActor
@Test func aModifierTappedWhileAnotherIsOnTheServerSendsNoTap() throws {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let rightWindows = RDPKeyboardScancode(code: 0x5C, isExtended: true)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let keyR = RDPKeyboardScancode(code: 0x13)
    // Device-dependent side bits (NX_DEVICE*KEYMASK).
    let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
    let bothCommands = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x18)
    let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
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
    func modifier(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: keyCode, modifierFlags: flags))
    }
    func click(_ flags: NSEvent.ModifierFlags) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: 10, y: 90),
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }
    func pressR(_ flags: NSEvent.ModifierFlags) throws {
        view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_R, characters: "r", modifierFlags: flags))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_R, characters: "r", modifierFlags: flags))
    }

    // Command-click; the other Command tapped, then with R; right Option tapped.
    try modifier(kVK_Command, leftCommand)
    try click(leftCommand)
    try modifier(kVK_RightCommand, bothCommands)
    try modifier(kVK_RightCommand, leftCommand)
    try modifier(kVK_RightCommand, bothCommands)
    try pressR(bothCommands)
    try modifier(kVK_RightCommand, leftCommand)
    try modifier(kVK_RightOption, leftCommand.union(rightOption))
    try modifier(kVK_RightOption, leftCommand)
    try modifier(kVK_Command, [])
    // Option-click; Command tapped, then with R.
    try modifier(kVK_RightOption, rightOption)
    try click(rightOption)
    try modifier(kVK_Command, rightOption.union(leftCommand))
    try modifier(kVK_Command, rightOption)
    try modifier(kVK_Command, rightOption.union(leftCommand))
    try pressR(rightOption.union(leftCommand))
    try modifier(kVK_Command, rightOption)
    try modifier(kVK_RightOption, [])

    // Only the order matters here, not where on the desktop the clicks land.
    let events = input.events.map { event in
        guard case let .pointerButton(button, isDown, _, _) = event else {
            return event
        }
        return .pointerButton(button: button, isDown: isDown, x: 0, y: 0)
    }
    #expect(events == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .pointerButton(button: .left, isDown: true, x: 0, y: 0),
        .pointerButton(button: .left, isDown: false, x: 0, y: 0),
        .keyboard(scancode: rightWindows, isReleased: false),
        .keyboard(scancode: keyR, isReleased: false),
        .keyboard(scancode: keyR, isReleased: true),
        .keyboard(scancode: rightWindows, isReleased: true),
        .keyboard(scancode: leftWindows, isReleased: true),
        .keyboard(scancode: rightAlt, isReleased: false),
        .pointerButton(button: .left, isDown: true, x: 0, y: 0),
        .pointerButton(button: .left, isDown: false, x: 0, y: 0),
        .keyboard(scancode: leftWindows, isReleased: false),
        .keyboard(scancode: keyR, isReleased: false),
        .keyboard(scancode: keyR, isReleased: true),
        .keyboard(scancode: leftWindows, isReleased: true),
        .keyboard(scancode: rightAlt, isReleased: true),
    ])
}

// Command and scrolling is a chord: the server gets Win with the wheel, not a Win tap that opens
// the Start menu.
@MainActor
@Test func commandAndScrollSendsTheWindowsKeyWithTheWheel() throws {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    let wheelLine = try #require(CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: 1,
        wheel2: 0,
        wheel3: 0
    ))
    wheelLine.flags = .maskCommand
    wheelLine.location = CGPoint(x: 100, y: 100)
    let scroll = try #require(NSEvent(cgEvent: wheelLine))
    // Where the event lands on screen depends on the display, so the view moves to put it at (10, 10).
    view.frame = CGRect(x: scroll.locationInWindow.x - 10, y: scroll.locationInWindow.y - 10, width: 100, height: 100)
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

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command, modifierFlags: .command))
    view.scrollWheel(with: scroll)
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command))

    // Only the order matters here, not where on the desktop the wheel event lands.
    let events = input.events.map { event in
        guard case let .verticalWheel(rotation, _, _) = event else {
            return event
        }
        return .verticalWheel(rotation: rotation, x: 0, y: 0)
    }
    #expect(events == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .verticalWheel(rotation: 120, x: 0, y: 0),
        .keyboard(scancode: leftWindows, isReleased: true),
    ])
}

// Device-dependent side bits (NX_DEVICE*KEYMASK), which tell left and right Option apart.
private let leftOptionFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
private let rightOptionFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)

@MainActor
@Test func rightOptionTypesWhatTheMacLayoutPutsOnOptionWithoutAlt() throws {
    let leftShift = RDPKeyboardScancode(code: 0x2A)
    let rightOptionShift = rightOptionFlags.union(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2))
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
    func key(_ type: NSEvent.EventType, _ keyCode: Int, _ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags) throws {
        let event = try keyEvent(type, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring, modifierFlags: flags)
        if type == .keyDown {
            view.keyDown(with: event)
        } else {
            view.keyUp(with: event)
        }
    }

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption, modifierFlags: rightOptionFlags))
    // Option-L types "@" on a German Mac, and its auto-repeat again.
    try key(.keyDown, kVK_ANSI_L, "@", "l", rightOptionFlags)
    try key(.keyDown, kVK_ANSI_L, "@", "l", rightOptionFlags)
    try key(.keyUp, kVK_ANSI_L, "@", "l", rightOptionFlags)
    // Option-Shift-7 types "\".
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Shift, modifierFlags: rightOptionShift))
    try key(.keyDown, kVK_ANSI_7, "\\", "/", rightOptionShift)
    try key(.keyUp, kVK_ANSI_7, "\\", "/", rightOptionShift)
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Shift, modifierFlags: rightOptionFlags))
    // Option-E types a dead key; the accent comes with the next key, after Option is up.
    try key(.keyDown, kVK_ANSI_E, "", "e", rightOptionFlags)
    try key(.keyUp, kVK_ANSI_E, "", "e", rightOptionFlags)
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption))
    try key(.keyDown, kVK_ANSI_E, "é", "e", [])

    #expect(input.events == [
        .unicode(codeUnit: 0x40, isReleased: false),
        .unicode(codeUnit: 0x40, isReleased: true),
        .unicode(codeUnit: 0x40, isReleased: false),
        .unicode(codeUnit: 0x40, isReleased: true),
        .keyboard(scancode: leftShift, isReleased: false),
        .unicode(codeUnit: 0x5C, isReleased: false),
        .unicode(codeUnit: 0x5C, isReleased: true),
        .keyboard(scancode: leftShift, isReleased: true),
        .unicode(codeUnit: 0xE9, isReleased: false),
        .unicode(codeUnit: 0xE9, isReleased: true),
    ])
}

/// Left Option goes as Alt at once, for shortcuts; right Option goes as Alt ahead of a key it
/// types nothing new with, or as a tap when released alone.
@MainActor
@Test func optionGoesAsAltForShortcutsAndATap() throws {
    let leftAlt = RDPKeyboardScancode(code: 0x38)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let leftArrow = RDPKeyboardScancode(code: 0x4B, isExtended: true)
    let keyL = RDPKeyboardScancode(code: 0x26)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption, modifierFlags: rightOptionFlags))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_LeftArrow, characters: "\u{F702}", modifierFlags: rightOptionFlags))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_LeftArrow, characters: "\u{F702}", modifierFlags: rightOptionFlags))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Option, modifierFlags: leftOptionFlags))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_L, characters: "@", charactersIgnoringModifiers: "l", modifierFlags: leftOptionFlags))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_L, characters: "@", charactersIgnoringModifiers: "l", modifierFlags: leftOptionFlags))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Option))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption, modifierFlags: rightOptionFlags))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption))

    #expect(input.events == [
        .keyboard(scancode: rightAlt, isReleased: false),
        .keyboard(scancode: leftArrow, isReleased: false),
        .keyboard(scancode: leftArrow, isReleased: true),
        .keyboard(scancode: rightAlt, isReleased: true),
        .keyboard(scancode: leftAlt, isReleased: false),
        .keyboard(scancode: keyL, isReleased: false),
        .keyboard(scancode: keyL, isReleased: true),
        .keyboard(scancode: leftAlt, isReleased: true),
        .keyboard(scancode: rightAlt, isReleased: false),
        .keyboard(scancode: rightAlt, isReleased: true),
    ])

    // Focus lost while right Option is held back: nothing reached the server, so nothing is sent.
    input.events.removeAll()
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption, modifierFlags: rightOptionFlags))
    _ = view.resignFirstResponder()
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption))
    #expect(input.events.isEmpty)
}

/// PC keypads have no "=": the main "=" key's scancode types it on US, but German has a dead
/// key there.
@MainActor
@Test func keypadEqualsGoesAsUnicodeWhereTheLayoutHasNoEqualsKey() throws {
    let equalsKey = RDPKeyboardScancode(code: 0x0D)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_KeypadEquals, characters: "="))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_KeypadEquals, characters: "="))
    view.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_KeypadEquals, characters: "="))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_KeypadEquals, characters: "="))

    #expect(input.events == [
        .keyboard(scancode: equalsKey, isReleased: false),
        .keyboard(scancode: equalsKey, isReleased: true),
        .unicode(codeUnit: 0x3D, isReleased: false),
        .unicode(codeUnit: 0x3D, isReleased: true),
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
