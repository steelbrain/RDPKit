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
    #expect(MacRDPDeferredModifierKeys.isDeferred(rightAlt, holdsBackAlt: true))
    #expect(MacRDPDeferredModifierKeys.isDeferred(RDPKeyboardScancode(code: 0x38), holdsBackAlt: true) == false)
    // A server without Unicode input gets right Alt at once, but the Windows keys still wait.
    #expect(MacRDPDeferredModifierKeys.isDeferred(rightAlt, holdsBackAlt: false) == false)
    #expect(MacRDPDeferredModifierKeys.isDeferred(leftWindows, holdsBackAlt: false))

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

/// Eisu and Kana go as LANG2 and LANG1 whatever the Mac types with them (a space), and Yen and
/// Ro as the PC JIS keys, where the layout check decides.
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
    isAltPressed: Bool = false,
    isDeadKey: Bool = true
) -> Bool {
    MacRDPKeyboardMapping.shouldSendScancode(
        forKeyCode: UInt16(keyCode),
        characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        modifierFlags: modifierFlags,
        isHeldAsScancode: isHeldAsScancode,
        isAltPressed: isAltPressed,
        isDeadKey: { isDeadKey }
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
    #expect(MacRDPKeyboardMapping.optionTypes("\u{F702}", charactersIgnoringModifiers: "\u{F703}") { true } == false)
    #expect(MacRDPKeyboardMapping.optionTypes("\u{1B}", charactersIgnoringModifiers: "a") { true } == false)
}

/// A custom layout can give a key no output with Option without making it a dead key: that key
/// goes as Alt and its scancode. The layout is asked only when right Option typed nothing.
@Test func optionTypingNothingIsADeadKeyOnlyIfTheLayoutSaysSo() {
    #expect(sendsScancode(kVK_ANSI_E, .option, characters: "", ignoringModifiers: "e", isDeadKey: false))
    var questions = 0
    func optionTypes(_ characters: String, _ ignoringModifiers: String) -> Bool {
        MacRDPKeyboardMapping.optionTypes(characters, charactersIgnoringModifiers: ignoringModifiers) {
            questions += 1
            return true
        }
    }
    #expect(optionTypes("", "e"))
    #expect(questions == 1)
    #expect(optionTypes("@", "l"))
    #expect(optionTypes("l", "l") == false)
    #expect(questions == 1)
    #expect(MacRDPKeyboardMapping.shouldSendScancode(
        forKeyCode: UInt16(kVK_ANSI_E),
        characters: "",
        charactersIgnoringModifiers: "e",
        modifierFlags: .option,
        isHeldAsScancode: false,
        isAltPressed: true
    ) {
        questions += 1
        return true
    })
    #expect(questions == 1)
}

/// Apple's US layout, loaded by its ID so the answer does not depend on the Mac's own layout.
@MainActor
@Test func theUSLayoutsOptionEIsADeadKey() throws {
    let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
    let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
    let us = try #require(sources.first)
    func isDeadKey(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Bool? {
        MacRDPDeadKeys.isDeadKey(keyCode: UInt16(keyCode), modifierFlags: modifierFlags, in: us)
    }
    #expect(isDeadKey(kVK_ANSI_E, .option) == true)
    #expect(isDeadKey(kVK_ANSI_L, .option) == false)
    #expect(isDeadKey(kVK_ANSI_E, [.option, .shift]) == false)
    #expect(isDeadKey(kVK_ANSI_E, []) == false)

    // The remembered answer for the Mac's own layout, asked twice, is that layout's.
    let current = try #require(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
    let currentAnswer = MacRDPDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option, in: current) ?? true
    #expect(MacRDPDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option) == currentAnswer)
    #expect(MacRDPDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option) == currentAnswer)
}

/// What US keys type with no dead key pending: nothing for the dead key Option-E itself.
@MainActor
@Test func theUSLayoutsUncomposedOutput() throws {
    let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
    let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
    let us = try #require(sources.first)
    func output(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> String? {
        MacRDPDeadKeys.output(keyCode: UInt16(keyCode), modifierFlags: modifierFlags, in: us)
    }
    #expect(output(kVK_ANSI_A, []) == "a")
    #expect(output(kVK_ANSI_A, .shift) == "A")
    #expect(output(kVK_ANSI_L, .option) == "¬")
    #expect(output(kVK_ANSI_E, .option) == "")
    #expect(output(kVK_Return, []) == "\r")

    // Right after Option-E, E types "é", Shift-A "Á", Return "´\r" and Option-E "´"; after a
    // key that starts no dead key, nothing is composed.
    func output(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags, after deadKey: (Int, NSEvent.ModifierFlags)) -> String? {
        MacRDPDeadKeys.output(
            keyCode: UInt16(keyCode),
            modifierFlags: modifierFlags,
            afterDeadKey: UInt16(deadKey.0),
            deadKeyModifierFlags: deadKey.1,
            in: us
        )
    }
    #expect(output(kVK_ANSI_E, [], after: (kVK_ANSI_E, .option)) == "é")
    #expect(output(kVK_ANSI_A, .shift, after: (kVK_ANSI_E, .option)) == "Á")
    #expect(output(kVK_Return, [], after: (kVK_ANSI_E, .option)) == "´\r")
    #expect(output(kVK_ANSI_E, .option, after: (kVK_ANSI_E, .option)) == "´")
    #expect(output(kVK_ANSI_E, [], after: (kVK_ANSI_L, .option)) == nil)
}

/// After a dead key went as an Alt chord, the next key is decided by what it types on its own,
/// except a control or function key, whose characters stay AppKit's.
@Test func theKeyAfterAChordedDeadKeyIsDecidedByItsUncomposedOutput() {
    func characters(_ composed: String?, _ uncomposed: String?) -> String? {
        MacRDPKeyboardMapping.characters(afterChordedDeadKey: composed, uncomposed: uncomposed)
    }
    #expect(characters("á", "a") == "a")
    #expect(characters("´¬", "¬") == "¬")
    #expect(characters("´", "") == "")
    #expect(characters("´\r", "\r") == "´\r")
    #expect(characters("\u{F702}", "\u{1C}") == "\u{F702}")
    #expect(characters("á", nil) == "á")
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

/// A Caps Lock letter goes as its scancode whether or not `charactersIgnoringModifiers` has
/// Caps Lock in it; Caps Lock with Shift types "A" on the Mac but "a" on Windows.
@Test func aCapsLockLetterGoesAsItsScancode() {
    #expect(windowsTypes("A", scancode: 0x1E, .capsLock))
    #expect(windowsTypes("A", ignoringModifiers: "a", scancode: 0x1E, .capsLock))
    #expect(windowsTypes("A", ignoringModifiers: "a", scancode: 0x1E) == false)
    #expect(windowsTypes("A", scancode: 0x1E, [.capsLock, .shift]) == false)
    #expect(windowsTypes("É", ignoringModifiers: "e", scancode: 0x12, .capsLock) == false)
}

private func windowsTypes(
    _ characters: String,
    ignoringModifiers: String? = nil,
    scancode: UInt16,
    _ modifierFlags: NSEvent.ModifierFlags = [],
    layout: UInt32 = 0x0000_0409,
    keyboard: RDPKeyboard? = nil
) -> Bool {
    MacRDPKeyboardMapping.windowsTypes(
        characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        for: RDPKeyboardScancode(code: scancode),
        modifierFlags: modifierFlags,
        keyboard: keyboard ?? RDPKeyboard(layout: RDPKeyboardLayout(rawValue: layout))
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
    let japanese = RDPKeyboard.japanese106
    let unshifted: [(String, UInt16)] = [
        ("2", 0x03), ("-", 0x0C), ("^", 0x0D), ("q", 0x10), ("@", 0x1A), ("[", 0x1B),
        (";", 0x27), (":", 0x28), ("]", 0x2B), ("/", 0x35), ("\\", 0x73), ("\\", 0x7D),
    ]
    for (characters, scancode) in unshifted {
        #expect(windowsTypes(characters, scancode: scancode, keyboard: japanese))
    }
    let shifted: [(String, UInt16)] = [
        ("\"", 0x03), ("&", 0x07), ("'", 0x08), ("=", 0x0C), ("~", 0x0D), ("Q", 0x10), ("`", 0x1A),
        ("{", 0x1B), ("+", 0x27), ("*", 0x28), ("}", 0x2B), ("?", 0x35), ("_", 0x73), ("|", 0x7D),
    ]
    for (characters, scancode) in shifted {
        #expect(windowsTypes(characters, scancode: scancode, .shift, keyboard: japanese))
    }
    #expect(windowsTypes("Q", scancode: 0x10, .capsLock, keyboard: japanese))
    // What US types on those keys goes as Unicode, as does what Windows types nothing for:
    // Shift-0 (the Mac types "0"), and Hankaku/Zenkaku where ANSI keyboards have "`".
    #expect(windowsTypes("@", scancode: 0x03, .shift, keyboard: japanese) == false)
    #expect(windowsTypes("=", scancode: 0x0D, keyboard: japanese) == false)
    #expect(windowsTypes("0", scancode: 0x0B, .shift, keyboard: japanese) == false)
    #expect(windowsTypes("`", scancode: 0x29, keyboard: japanese) == false)
    // The Mac's Yen key types "¥" (U+00A5), not the "\" Windows types there, and its Ro key
    // types "_" without Shift too.
    #expect(windowsTypes("¥", scancode: 0x7D, keyboard: japanese) == false)
    #expect(windowsTypes("_", scancode: 0x73, keyboard: japanese) == false)
}

/// Windows' Japanese layout with a 101-key keyboard types what US types, where the 106/109-key
/// one types the JIS legends.
@Test func theJapanese101KeyTableTypesWhatUSTypes() {
    let keyboard = RDPKeyboard.japanese101
    #expect(windowsTypes("@", scancode: 0x03, .shift, keyboard: keyboard))
    #expect(windowsTypes("\"", scancode: 0x03, .shift, keyboard: keyboard) == false)
    #expect(windowsTypes("`", scancode: 0x29, keyboard: keyboard))
    #expect(windowsTypes("~", scancode: 0x29, .shift, keyboard: keyboard))
    #expect(windowsTypes("A", scancode: 0x1E, .capsLock, keyboard: keyboard))
    // The ISO key types "\" and "|", and the JIS keys nothing.
    #expect(windowsTypes("\\", scancode: 0x56, keyboard: keyboard))
    #expect(windowsTypes("|", scancode: 0x56, .shift, keyboard: keyboard))
    #expect(windowsTypes("\\", scancode: 0x73, keyboard: keyboard) == false)
    #expect(windowsTypes("\\", scancode: 0x7D, keyboard: keyboard) == false)
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
    // Every keyboard that can be announced has a table, so the scancode check covers it.
    for klid in Set(MacRDPKeyboardLayout.windowsLayouts.values) {
        #expect(RDPKeyboard(layout: RDPKeyboardLayout(rawValue: klid)).hasCharacterTable)
    }
}

/// A Control shortcut goes as the scancode of the key the Mac types its letter on, so the
/// Windows layout announced has to type the same letter there. These Mac layouts were mapped by
/// that comparison (2026-11-01); each letter key of theirs must type its letter on Windows too.
@MainActor
@Test func macLayoutsAnnounceAWindowsLayoutWithTheirLettersInPlace() throws {
    let names = [
        "ABC-AZERTY", "ABC-QWERTZ", "Albanian", "FinnishExtended", "German-DIN-2137", "Hungarian-QWERTY",
        "Kabyle-AZERTY", "Latvian", "Lithuanian", "Lithuanian-LST1582", "Romanian", "Slovenian-QWERTZ",
        "Turkish-Standard",
    ]
    let letterKeys: [(keyCode: Int, scancode: UInt16)] = [
        (kVK_ANSI_A, 0x1E), (kVK_ANSI_B, 0x30), (kVK_ANSI_C, 0x2E), (kVK_ANSI_D, 0x20), (kVK_ANSI_E, 0x12),
        (kVK_ANSI_F, 0x21), (kVK_ANSI_G, 0x22), (kVK_ANSI_H, 0x23), (kVK_ANSI_I, 0x17), (kVK_ANSI_J, 0x24),
        (kVK_ANSI_K, 0x25), (kVK_ANSI_L, 0x26), (kVK_ANSI_M, 0x32), (kVK_ANSI_N, 0x31), (kVK_ANSI_O, 0x18),
        (kVK_ANSI_P, 0x19), (kVK_ANSI_Q, 0x10), (kVK_ANSI_R, 0x13), (kVK_ANSI_S, 0x1F), (kVK_ANSI_T, 0x14),
        (kVK_ANSI_U, 0x16), (kVK_ANSI_V, 0x2F), (kVK_ANSI_W, 0x11), (kVK_ANSI_X, 0x2D), (kVK_ANSI_Y, 0x15),
        (kVK_ANSI_Z, 0x2C),
    ]
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    let sources = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    var layoutData: [String: Data] = [:]
    for source in sources {
        guard let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            continue
        }
        layoutData[Unmanaged<CFString>.fromOpaque(identifier).takeUnretainedValue() as String] =
            Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
    }

    for name in names {
        let identifier = "com.apple.keylayout." + name
        let data = try #require(layoutData[identifier], "\(name) is not installed")
        let windows = RDPKeyboard(layout: MacRDPKeyboardLayout.windowsLayout(forInputSourceID: identifier))
        #expect(windows.hasCharacterTable, "\(name)")
        for key in letterKeys {
            let macCharacter = data.withUnsafeBytes { bytes -> String? in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(key.keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &characters
                )
                return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
            }
            let windowsCharacter = windows.character(for: RDPKeyboardScancode(code: key.scancode), shift: false, capsLock: false)
            #expect(windowsCharacter.map(String.init) == macCharacter, "\(name), key code \(key.keyCode)")
        }
    }
}

/// Only a Japanese input source that types with US English gets Windows' Japanese layout: as
/// a 106/109-key keyboard on a JIS keyboard, and as a 101-key one, which types what US types,
/// on an ANSI or ISO keyboard. Everything else keeps the input source's layout, so Command and
/// Control chords reach the server on the keys the Mac puts them on.
@Test func onlyAJapaneseInputSourceTypingWithUSEnglishAnnouncesAJapaneseKeyboard() {
    let german = RDPKeyboardLayout(rawValue: 0x0000_0407)
    let french = RDPKeyboardLayout(rawValue: 0x0000_080C)
    let dvorak = RDPKeyboardLayout(rawValue: 0x0001_0409)
    let korean = RDPKeyboardLayout(rawValue: 0x0000_0412)
    func keyboard(_ inputSourceLayout: RDPKeyboardLayout, isJapanese: Bool, isJIS: Bool) -> RDPKeyboard {
        MacRDPKeyboardLayout.windowsKeyboard(inputSourceLayout, isJapaneseInputSource: isJapanese, isJISKeyboard: isJIS)
    }
    #expect(keyboard(.unitedStates, isJapanese: true, isJIS: true) == .japanese106)
    #expect(keyboard(.unitedStates, isJapanese: true, isJIS: false) == .japanese101)
    // A Japanese input method typing with another layout, on any keyboard.
    for other in [german, french, dvorak] {
        #expect(keyboard(other, isJapanese: true, isJIS: true) == RDPKeyboard(layout: other))
        #expect(keyboard(other, isJapanese: true, isJIS: false) == RDPKeyboard(layout: other))
    }
    // An input source that is not Japanese, on any keyboard.
    #expect(keyboard(.unitedStates, isJapanese: false, isJIS: true) == .unitedStates)
    #expect(keyboard(korean, isJapanese: false, isJIS: true) == RDPKeyboard(layout: korean))
    #expect(keyboard(.unitedStates, isJapanese: false, isJIS: false) == .unitedStates)

    // Type 7 with subtype 2 is kbd106.dll, with subtype 0 kbd101.dll; other layouts go as IBM
    // enhanced keyboards.
    #expect(RDPKeyboard.japanese106.layout == RDPKeyboardLayout.japanese)
    #expect(RDPKeyboard.japanese106.type == .japanese)
    #expect(RDPKeyboard.japanese106.subType == 2)
    #expect(RDPKeyboard.japanese101.layout == RDPKeyboardLayout.japanese)
    #expect(RDPKeyboard.japanese101.type == .japanese)
    #expect(RDPKeyboard.japanese101.subType == 0)
    for other in [.unitedStates, german, korean] {
        #expect(keyboard(other, isJapanese: false, isJIS: false).type == .ibmEnhanced)
        #expect(keyboard(other, isJapanese: false, isJIS: false).subType == 0)
    }
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
    view.keyboard = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0407))
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
    view.keyboard = .japanese106

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Kana, characters: " "))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_JIS_Kana, characters: " "))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_LeftBracket, characters: "@"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Yen, characters: "¥"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Yen, characters: "|", modifierFlags: .shift))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Eisu, characters: " "))

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x72), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x72), isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x1A), isReleased: false),
        .unicode(codeUnit: 0xA5, isReleased: false),
        .unicode(codeUnit: 0xA5, isReleased: true),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x7D), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x71), isReleased: false),
    ])
}

/// Shift-Eisu goes as LANG2 with Windows' Japanese 106/109-key layout too, which turns it into
/// IME Off with Shift held and leaves Caps Lock alone (live, 2026-10-29), unlike that layout's
/// own Shift-英数.
@MainActor
@Test func theViewSendsShiftEisuAsLANG2WithTheJapanese106KeyLayout() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboard = .japanese106

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Eisu, characters: " ", modifierFlags: .shift))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_JIS_Eisu, characters: " ", modifierFlags: .shift))

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x71), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x71), isReleased: true),
    ])
}

/// With Windows' Japanese 101-key layout, what a Mac typing with US English types goes as
/// scancodes, and Eisu and Kana, which that layout turns into IME Off and On, go as LANG2 and
/// LANG1, Shift-Eisu too.
@MainActor
@Test func theViewSendsUSKeysAsScancodesWithTheJapanese101KeyLayout() throws {
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboard = .japanese101

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_2, characters: "@", charactersIgnoringModifiers: "@", modifierFlags: .shift))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_LeftBracket, characters: "["))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_Quote, characters: "'"))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Kana, characters: " "))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_JIS_Eisu, characters: " ", modifierFlags: .shift))

    #expect(input.events == [
        .keyboard(scancode: RDPKeyboardScancode(code: 0x03), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x1A), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x28), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x72), isReleased: false),
        .keyboard(scancode: RDPKeyboardScancode(code: 0x71), isReleased: false),
    ])
}

/// Alt-` turns Microsoft's Japanese IME on and off on a 101-key keyboard: left Option, which
/// goes as Alt at once, and the key left of 1 (kVK_ISO_Section on ISO keyboards, sent as 0x29
/// like the ANSI grave key) go as that, though Option makes the key a dead key on the Mac.
@MainActor
@Test func leftOptionAndTheKeyLeftOfOneGoAsAltGraveWithTheJapanese101KeyLayout() throws {
    let leftAlt = RDPKeyboardScancode(code: 0x38)
    let grave = RDPKeyboardScancode(code: 0x29)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboard = .japanese101

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Option, modifierFlags: leftOptionFlags))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ISO_Section, charactersIgnoringModifiers: "§", modifierFlags: leftOptionFlags))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ISO_Section, charactersIgnoringModifiers: "§", modifierFlags: leftOptionFlags))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Option))

    #expect(input.events == [
        .keyboard(scancode: leftAlt, isReleased: false),
        .keyboard(scancode: grave, isReleased: false),
        .keyboard(scancode: grave, isReleased: true),
        .keyboard(scancode: leftAlt, isReleased: true),
    ])
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_Grave), isISOKeyboard: false) == grave)
}

/// On an ISO keyboard the key between left Shift and Z goes as 0x56, where Windows' Japanese
/// 101-key layout types "\" and "|" as US does, so what the Mac types there goes as Unicode, as
/// does what the key left of 1 types.
@Test func theISOKeysGoAsUnicodeWithTheJapanese101KeyLayout() {
    let keyboard = RDPKeyboard.japanese101
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_Grave), isISOKeyboard: true) == RDPKeyboardScancode(code: 0x56))
    #expect(windowsTypes("`", scancode: 0x56, keyboard: keyboard) == false)
    #expect(windowsTypes("~", scancode: 0x56, .shift, keyboard: keyboard) == false)
    #expect(windowsTypes("§", scancode: 0x29, keyboard: keyboard) == false)
    #expect(windowsTypes("±", scancode: 0x29, .shift, keyboard: keyboard) == false)
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

private final class RecordedInput: RDPInputEventSending {
    var supportsUnicodeInput = true
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

// With no session the view still tracks what it would have sent, so a session attached later
// gets nothing stale: a focus loss with no session lets go of the Windows key a Command chord
// took down, so Command released with a session sends no Windows key release.
@MainActor
@Test func inputMadeWithNoSessionLeavesNothingStaleForTheNextOne() throws {
    let keyA = RDPKeyboardScancode(code: 0x1E)
    let view = RemoteInputCaptureNSView()
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command, modifierFlags: .command))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_A, characters: "a", modifierFlags: .command))
    _ = view.resignFirstResponder()
    let first = RecordedInput()
    view.inputSession = first
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command))
    #expect(first.events.isEmpty)

    // A key pressed with a session, released after the session went, then pressed with another.
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_A, characters: "a"))
    view.inputSession = nil
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_A, characters: "a"))
    let second = RecordedInput()
    view.inputSession = second
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_A, characters: "a"))

    #expect(first.events == [.keyboard(scancode: keyA, isReleased: false), .keyboard(scancode: keyA, isReleased: true)])
    #expect(second.events == [.keyboard(scancode: keyA, isReleased: false)])
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

    // Only the order matters here, not where on the desktop the wheel event lands. The server
    // had the pointer nowhere yet, so it moves there first.
    let events = input.events.map { event -> RDPSlowPathInputEvent in
        switch event {
        case let .verticalWheel(rotation, _, _):
            .verticalWheel(rotation: rotation, x: 0, y: 0)
        case .pointerMove:
            .pointerMove(x: 0, y: 0)
        default:
            event
        }
    }
    #expect(events == [
        .keyboard(scancode: leftWindows, isReleased: false),
        .pointerMove(x: 0, y: 0),
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
    view.keyboard = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0407))
    var deadKeyQuestions: [Int] = []
    view.isDeadKey = { keyCode, _ in
        deadKeyQuestions.append(Int(keyCode))
        return true
    }
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
    // The layout is asked only about the key Option typed nothing with.
    #expect(deadKeyQuestions == [kVK_ANSI_E])
}

/// A key a custom layout gives no Option output, without making it a dead key, goes as Alt and
/// the key, like any key right Option types nothing new with.
@MainActor
@Test func rightOptionSendsAltWithAKeyThatTypesNothingButIsNoDeadKey() throws {
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let keyE = RDPKeyboardScancode(code: 0x12)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.isDeadKey = { _, _ in false }

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption, modifierFlags: rightOptionFlags))
    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_E, characters: "", charactersIgnoringModifiers: "e", modifierFlags: rightOptionFlags))
    view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_E, characters: "", charactersIgnoringModifiers: "e", modifierFlags: rightOptionFlags))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_RightOption))

    #expect(input.events == [
        .keyboard(scancode: rightAlt, isReleased: false),
        .keyboard(scancode: keyE, isReleased: false),
        .keyboard(scancode: keyE, isReleased: true),
        .keyboard(scancode: rightAlt, isReleased: true),
    ])
}

/// Left Option-E goes as Alt-E, a shortcut, but macOS still starts its dead key and composes the
/// next key with the accent: that key goes as what it types on its own, and no accent goes ahead
/// of Return. Right Option does the same once its Alt is on the server.
@MainActor
@Test func theKeyAfterADeadKeySentAsAnAltChordIsNotComposed() throws {
    let leftAlt = RDPKeyboardScancode(code: 0x38)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let keyE = RDPKeyboardScancode(code: 0x12)
    let keyA = RDPKeyboardScancode(code: 0x1E)
    let returnKey = RDPKeyboardScancode(code: 0x1C)
    let leftArrow = RDPKeyboardScancode(code: 0x4B, isExtended: true)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.isDeadKey = { keyCode, flags in Int(keyCode) == kVK_ANSI_E && flags.contains(.option) }
    view.uncomposedOutput = { keyCode, flags in
        [kVK_ANSI_A: "a", kVK_Return: "\r", kVK_ANSI_E: flags.contains(.option) ? "" : "e"][Int(keyCode)]
    }
    func modifier(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: keyCode, modifierFlags: flags))
    }
    func press(_ keyCode: Int, _ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags = []) throws {
        view.keyDown(with: try keyEvent(.keyDown, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring, modifierFlags: flags))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring, modifierFlags: flags))
    }
    func leftOptionE() throws {
        try modifier(kVK_Option, leftOptionFlags)
        try press(kVK_ANSI_E, "", "e", leftOptionFlags)
        try modifier(kVK_Option, [])
    }

    // Left Option-E, then "a", which macOS reports as "á"; only that key is affected.
    try leftOptionE()
    try press(kVK_ANSI_A, "á", "a")
    try press(kVK_ANSI_A, "á", "a")
    // Left Option-E, then Return, reported as "´\r".
    try leftOptionE()
    try press(kVK_Return, "´\r", "\r")
    // Right Option-E once Left Arrow sent its Alt, then "a".
    try modifier(kVK_RightOption, rightOptionFlags)
    try press(kVK_LeftArrow, "\u{F702}", "\u{F702}", rightOptionFlags)
    try press(kVK_ANSI_E, "", "e", rightOptionFlags)
    try modifier(kVK_RightOption, [])
    try press(kVK_ANSI_A, "á", "a")
    // Focus lost in between: the next key goes as it is.
    try leftOptionE()
    _ = view.resignFirstResponder()
    try press(kVK_ANSI_A, "á", "a")

    let altE: [RDPSlowPathInputEvent] = [
        .keyboard(scancode: leftAlt, isReleased: false),
        .keyboard(scancode: keyE, isReleased: false),
        .keyboard(scancode: keyE, isReleased: true),
        .keyboard(scancode: leftAlt, isReleased: true),
    ]
    let keyAPress: [RDPSlowPathInputEvent] = [
        .keyboard(scancode: keyA, isReleased: false),
        .keyboard(scancode: keyA, isReleased: true),
    ]
    let composedA: [RDPSlowPathInputEvent] = [
        .unicode(codeUnit: 0xE1, isReleased: false),
        .unicode(codeUnit: 0xE1, isReleased: true),
    ]
    #expect(input.events == altE + keyAPress + composedA
        + altE + [.keyboard(scancode: returnKey, isReleased: false), .keyboard(scancode: returnKey, isReleased: true)]
        + [
            .keyboard(scancode: rightAlt, isReleased: false),
            .keyboard(scancode: leftArrow, isReleased: false),
            .keyboard(scancode: leftArrow, isReleased: true),
            .keyboard(scancode: keyE, isReleased: false),
            .keyboard(scancode: keyE, isReleased: true),
            .keyboard(scancode: rightAlt, isReleased: true),
        ] + keyAPress
        + altE + composedA)
}

/// US left Option-E goes as Alt-E, and macOS spends right Option-E after it on that dead key's
/// accent, typing "´", which goes nowhere. The second dead key is the user's, so E after it
/// types "é", whether or not macOS left a dead key pending (German's Option dead keys leave
/// none). Only the key right after it is composed.
@MainActor
@Test func aDeadKeyRightAfterAChordedDeadKeyComposesTheKeyAfterIt() throws {
    let leftAlt = RDPKeyboardScancode(code: 0x38)
    let keyE = RDPKeyboardScancode(code: 0x12)
    let input = RecordedInput()
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.isDeadKey = { keyCode, flags in Int(keyCode) == kVK_ANSI_E && flags.contains(.option) }
    view.uncomposedOutput = { keyCode, flags in Int(keyCode) == kVK_ANSI_E && flags.contains(.option) ? "" : nil }
    view.composedOutput = { keyCode, flags, deadKeyCode, deadKeyFlags in
        Int(keyCode) == kVK_ANSI_E && flags.isEmpty && Int(deadKeyCode) == kVK_ANSI_E && deadKeyFlags.contains(.option)
            ? "é" : nil
    }
    func modifier(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: keyCode, modifierFlags: flags))
    }
    func press(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
        view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_E, characters: characters, charactersIgnoringModifiers: "e", modifierFlags: flags))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_E, characters: characters, charactersIgnoringModifiers: "e", modifierFlags: flags))
    }

    try modifier(kVK_Option, leftOptionFlags)
    try press("", leftOptionFlags)
    try modifier(kVK_Option, [])
    try modifier(kVK_RightOption, rightOptionFlags)
    try press("´", rightOptionFlags)
    try modifier(kVK_RightOption, [])
    try press("e")
    try press("e")

    #expect(input.events == [
        .keyboard(scancode: leftAlt, isReleased: false),
        .keyboard(scancode: keyE, isReleased: false),
        .keyboard(scancode: keyE, isReleased: true),
        .keyboard(scancode: leftAlt, isReleased: true),
        .unicode(codeUnit: 0xE9, isReleased: false),
        .unicode(codeUnit: 0xE9, isReleased: true),
        .keyboard(scancode: keyE, isReleased: false),
        .keyboard(scancode: keyE, isReleased: true),
    ])
}

/// Letters Caps Lock shifts go as scancodes, so the server's Caps Lock has to match the Mac's.
/// A toggle the view never saw, such as one made while a menu was open, shows up in the next
/// key's or click's flags, which synchronize the toggle-key state first, with the keys held.
/// Before the first synchronization there is no state to compare with.
@MainActor
@Test func aCapsLockChangeTheViewMissedIsSynchronizedBeforeTheNextKeyOrClick() throws {
    let leftControl = RDPKeyboardScancode(code: 0x1D)
    let keyA = RDPKeyboardScancode(code: 0x1E)
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
    func pressA(_ characters: String, _ flags: NSEvent.ModifierFlags) throws {
        view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_A, characters: characters, charactersIgnoringModifiers: "a", modifierFlags: flags))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_A, characters: characters, charactersIgnoringModifiers: "a", modifierFlags: flags))
    }

    try pressA("A", .capsLock)
    #expect(input.events == [.keyboard(scancode: keyA, isReleased: false), .keyboard(scancode: keyA, isReleased: true)])

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_CapsLock))
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Control, modifierFlags: .control))
    input.events.removeAll()
    try pressA("\u{01}", [.control, .capsLock])
    #expect(input.events == [
        .synchronize(toggleFlags: [.numLock, .capsLock]),
        .keyboard(scancode: leftControl, isReleased: false),
        .keyboard(scancode: keyA, isReleased: false),
        .keyboard(scancode: keyA, isReleased: true),
    ])

    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Control, modifierFlags: .capsLock))
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
        .synchronize(toggleFlags: [.numLock]),
        .pointerButton(button: .left, isDown: true, x: 10, y: 10),
    ])
}

/// A server that takes no Unicode input gets the keys pressed, so its own layout types the
/// text: right Option goes as Alt at once (AltGr), and a key whose character would have gone as
/// Unicode, a dead key included, goes as its scancode with Shift as held. The Mac's composed
/// characters and accents never go, and no other key stands in for them.
@MainActor
@Test func withoutUnicodeInputEveryKeyGoesAsItsScancode() throws {
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    let leftShift = RDPKeyboardScancode(code: 0x2A)
    let input = RecordedInput()
    input.supportsUnicodeInput = false
    let view = RemoteInputCaptureNSView()
    view.inputSession = input
    view.keyboard = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0407))
    view.isDeadKey = { keyCode, _ in Int(keyCode) == kVK_ANSI_Equal }
    view.uncomposedOutput = { keyCode, _ in [kVK_ANSI_E: "e", kVK_Return: "\r"][Int(keyCode)] }
    func modifier(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws {
        view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: keyCode, modifierFlags: flags))
    }
    func press(_ keyCode: Int, _ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags = []) throws {
        view.keyDown(with: try keyEvent(.keyDown, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring, modifierFlags: flags))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring, modifierFlags: flags))
    }
    func scancodes(_ codes: UInt16...) -> [RDPSlowPathInputEvent] {
        codes.flatMap { code in
            [true, false].map { .keyboard(scancode: RDPKeyboardScancode(code: code), isReleased: !$0) }
        }
    }

    // German Mac: Option-L types "@", which German Windows has on AltGr-Q.
    try modifier(kVK_RightOption, rightOptionFlags)
    try press(kVK_ANSI_L, "@", "l", rightOptionFlags)
    try modifier(kVK_RightOption, [])
    // The dead key "´", then "e", which the Mac composes to "é"; then "´" and Return ("´\r").
    try press(kVK_ANSI_Equal, "", "´")
    try press(kVK_ANSI_E, "é", "e")
    try press(kVK_ANSI_Equal, "", "´")
    try press(kVK_Return, "´\r", "\r")
    // A layout with no table: every character would have gone as Unicode.
    view.keyboard = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x1234_5678))
    try press(kVK_ANSI_Q, "q", "q")
    let shift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
    try modifier(kVK_Shift, shift)
    try press(kVK_ANSI_Q, "Q", "Q", shift)
    try modifier(kVK_Shift, [])
    // A key with no scancode sends nothing.
    try press(kVK_ANSI_KeypadClear, "\u{F739}", "\u{F739}")

    #expect(input.events == [.keyboard(scancode: rightAlt, isReleased: false)]
        + scancodes(0x26)
        + [.keyboard(scancode: rightAlt, isReleased: true)]
        + scancodes(0x0D, 0x12, 0x0D, 0x1C, 0x10)
        + [.keyboard(scancode: leftShift, isReleased: false)]
        + scancodes(0x10)
        + [.keyboard(scancode: leftShift, isReleased: true)])
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
    view.keyboard = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0407))
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

/// Command or right Option pressed while Shift, Control, left Option or a mouse button is down
/// on the server is a chord: released after it, it sends no Win or Alt tap, which would open the
/// Start menu or the menu bar.
@Test func aKeyHeldBackWhileAModifierOrButtonIsDownIsNoTap() {
    let leftShift = RDPKeyboardScancode(code: 0x2A)
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let rightAlt = RDPKeyboardScancode(code: 0x38, isExtended: true)
    var shiftDown = RDPInputStateTracker()
    _ = shiftDown.keyboard(scancode: leftShift, isReleased: false)
    var dragging = RDPInputStateTracker()
    _ = dragging.pointerButton(.left, isDown: true, at: RDPRemotePoint(x: 1, y: 1))

    for inputState in [shiftDown, dragging] {
        for held in [leftWindows, rightAlt] {
            var heldKeys = MacRDPDeferredModifierKeys()
            heldKeys.press(held, inputState: inputState)
            #expect(heldKeys.release(held).isEmpty)
        }
    }
}

/// The server gets the pointer where the wheel turns before the wheel events, unless it already
/// has it there.
@Test func theWheelMovesThePointerFirstWhenTheServerHasItElsewhere() {
    var inputState = RDPInputStateTracker()
    let point = RDPRemotePoint(x: 40, y: 30)

    #expect(MacRDPScrollWheel.pointerMove(to: point, inputState: &inputState) == [.pointerMove(x: 40, y: 30)])
    #expect(MacRDPScrollWheel.pointerMove(to: point, inputState: &inputState).isEmpty)
    #expect(MacRDPScrollWheel.pointerMove(to: RDPRemotePoint(x: 41, y: 30), inputState: &inputState)
        == [.pointerMove(x: 41, y: 30)])
}

/// The JIS keypad comma's scancode types nothing on most layouts, so the comma goes as Unicode
/// unless a modifier makes it a shortcut.
@Test func theJISKeypadCommaTypesAComma() {
    #expect(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_JIS_KeypadComma)) == RDPKeyboardScancode(code: 0x7E))
    #expect(sendsScancode(kVK_JIS_KeypadComma, [], characters: ",") == false)
    #expect(sendsScancode(kVK_JIS_KeypadComma, .control, characters: ","))
}
