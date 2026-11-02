#if os(macOS)
import AppKit
import Carbon.HIToolbox
@testable import RDPKitAppKit
import RDPKit
import Testing

@Test func modifierKeysTrackEachSideFromDeviceFlags() throws {
    let leftShift = try #require(RDPMacModifierKey(keyCode: UInt16(kVK_Shift)))
    let rightShift = try #require(RDPMacModifierKey(keyCode: UInt16(kVK_RightShift)))
    let bothDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2 | 0x4)
    let onlyRightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)

    #expect(leftShift.isDown(in: bothDown))
    #expect(rightShift.isDown(in: bothDown))
    #expect(leftShift.isDown(in: onlyRightDown) == false)
    #expect(rightShift.isDown(in: onlyRightDown))
    #expect(leftShift.isDown(in: []) == false)
}

@Test func modifierKeysFallBackToSideIndependentFlags() throws {
    let control = try #require(RDPMacModifierKey(keyCode: UInt16(kVK_Control)))

    #expect(control.isDown(in: .control))
    #expect(control.isDown(in: []) == false)
    // Without a side bit, the flag alone never names this side as held.
    #expect(control.isSideDown(in: .control) == false)
    #expect(control.isSideDown(in: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)))
}

/// A character key types text, or nothing, on its own; Return, the arrows' and Delete's
/// control characters and a key with no output are not one.
@Test func aCharacterKeyIsOneThatTypesTextOrNothingOnItsOwn() {
    for uncomposed in ["a", "¬", " ", ""] {
        #expect(RDPMacKeyboardMapping.isCharacterKey(uncomposed: uncomposed))
    }
    for uncomposed: String? in ["\r", "\u{1C}", "\u{08}", "\u{7F}", "\u{10}", nil] {
        #expect(RDPMacKeyboardMapping.isCharacterKey(uncomposed: uncomposed) == false)
    }
}

/// A side reads as down from its own bit only; a keyboard with no side bits says no side.
@Test func modifierKeysReadTheirOwnSideBit() throws {
    let leftShift = try #require(RDPMacModifierKey(keyCode: UInt16(kVK_Shift)))
    let rightShift = try #require(RDPMacModifierKey(keyCode: UInt16(kVK_RightShift)))
    let onlyRightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)

    #expect(rightShift.isSideDown(in: onlyRightDown))
    #expect(leftShift.isSideDown(in: onlyRightDown) == false)
    #expect(leftShift.isSideDown(in: .shift) == false)
    // A stale side bit without the flag is no press.
    #expect(rightShift.isSideDown(in: NSEvent.ModifierFlags(rawValue: 0x4)) == false)
}

@Test func commandSendsWindowsKeyOnlyWithAnotherKeyOrAsATap() {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let nothingDown = RDPInputStateTracker()
    var inputState = RDPInputStateTracker()
    var windowsKey = RDPMacDeferredModifierKeys()

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
    var heldKeys = RDPMacDeferredModifierKeys()
    #expect(RDPMacDeferredModifierKeys.isDeferred(rightAlt, holdsBackAlt: true))
    #expect(RDPMacDeferredModifierKeys.isDeferred(RDPKeyboardScancode(code: 0x38), holdsBackAlt: true) == false)
    // A server without Unicode input gets right Alt at once, but the Windows keys still wait.
    #expect(RDPMacDeferredModifierKeys.isDeferred(rightAlt, holdsBackAlt: false) == false)
    #expect(RDPMacDeferredModifierKeys.isDeferred(leftWindows, holdsBackAlt: false))

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
        var heldKeys = RDPMacDeferredModifierKeys()
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
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: false) == RDPKeyboardScancode(code: 0x29))
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: true) == RDPKeyboardScancode(code: 0x56))
    let sectionKey = UInt16(kVK_ISO_Section)
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: sectionKey, isISOKeyboard: true) == RDPKeyboardScancode(code: 0x29))
}

@Test func keypadClearDoesNotSendNumLock() {
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_KeypadClear)) == nil)
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
        #expect(try #require(RDPMacModifierKey(keyCode: UInt16(keyCode))).scancode == scancode)
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
        #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(keyCode)) == scancode)
    }
}

/// Eisu and Kana go as LANG2 and LANG1 whatever the Mac types with them (a space), and Yen,
/// Ro and the keypad comma as the PC JIS keys, where the layout check decides.
@Test func jisKeysMapToThePCJISScancodes() {
    let expected: [Int: RDPKeyboardScancode] = [
        kVK_JIS_Eisu: RDPKeyboardScancode(code: 0x71),
        kVK_JIS_Kana: RDPKeyboardScancode(code: 0x72),
        kVK_JIS_Yen: RDPKeyboardScancode(code: 0x7D),
        kVK_JIS_Underscore: RDPKeyboardScancode(code: 0x73),
        kVK_JIS_KeypadComma: RDPKeyboardScancode(code: 0x7E),
    ]
    for (keyCode, scancode) in expected {
        #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(keyCode)) == scancode)
    }
    #expect(sendsScancode(kVK_JIS_Eisu, [], characters: " "))
    #expect(sendsScancode(kVK_JIS_Kana, [], characters: " "))
    #expect(sendsScancode(kVK_JIS_Yen, [], characters: "¥") == false)
    #expect(sendsScancode(kVK_JIS_Underscore, [], characters: "_") == false)
    #expect(sendsScancode(kVK_JIS_KeypadComma, [], characters: ",") == false)
    // US has no key 0x7E, so the keypad comma's "," goes as Unicode there.
    #expect(windowsTypes(",", scancode: 0x7E) == false)
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
    RDPMacKeyboardMapping.shouldSendScancode(
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
    #expect(sendsScancode(kVK_ANSI_L, [.option, .control], characters: "@", ignoringModifiers: "l"))
    #expect(sendsScancode(kVK_ANSI_L, .option, characters: "@", ignoringModifiers: "l", isHeldAsScancode: true))
    #expect(sendsScancode(kVK_LeftArrow, .option, characters: "\u{F702}"))
    // Option changed nothing, or typed a control or function-key character (the Apple logo, at
    // the top of AppKit's function-key range).
    #expect(sendsScancode(kVK_ANSI_L, .option, characters: "l"))
    #expect(sendsScancode(kVK_ANSI_LeftBracket, .option, characters: "\u{1B}", ignoringModifiers: "["))
    #expect(sendsScancode(kVK_ANSI_K, [.option, .shift], characters: "\u{F8FF}", ignoringModifiers: "K"))
    // Without Option, a character a dead key composed is left to the layout check.
    #expect(sendsScancode(kVK_ANSI_E, [], characters: "é", ignoringModifiers: "e") == false)
    #expect(RDPMacKeyboardMapping.optionTypes("\u{F702}", charactersIgnoringModifiers: "\u{F703}") { true } == false)
    #expect(RDPMacKeyboardMapping.optionTypes("\u{1B}", charactersIgnoringModifiers: "a") { true } == false)
}

/// A custom layout can give a key no output with Option without making it a dead key: that key
/// goes as Alt and its scancode. The layout is asked only when right Option typed nothing.
@Test func optionTypingNothingIsADeadKeyOnlyIfTheLayoutSaysSo() {
    #expect(sendsScancode(kVK_ANSI_E, .option, characters: "", ignoringModifiers: "e", isDeadKey: false))
    var questions = 0
    func optionTypes(_ characters: String, _ ignoringModifiers: String) -> Bool {
        RDPMacKeyboardMapping.optionTypes(characters, charactersIgnoringModifiers: ignoringModifiers) {
            questions += 1
            return true
        }
    }
    #expect(optionTypes("", "e"))
    #expect(questions == 1)
    #expect(optionTypes("@", "l"))
    #expect(optionTypes("l", "l") == false)
    #expect(questions == 1)
    #expect(RDPMacKeyboardMapping.shouldSendScancode(
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
        RDPMacDeadKeys.isDeadKey(keyCode: UInt16(keyCode), modifierFlags: modifierFlags, in: us)
    }
    #expect(isDeadKey(kVK_ANSI_E, .option) == true)
    #expect(isDeadKey(kVK_ANSI_L, .option) == false)
    #expect(isDeadKey(kVK_ANSI_E, [.option, .shift]) == false)
    #expect(isDeadKey(kVK_ANSI_E, []) == false)

    // The remembered answer for the Mac's own layout, asked twice, is that layout's.
    let current = try #require(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
    let currentAnswer = RDPMacDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option, in: current) ?? true
    #expect(RDPMacDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option) == currentAnswer)
    #expect(RDPMacDeadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_E), modifierFlags: .option) == currentAnswer)
}

/// What US keys type with no dead key pending: nothing for the dead key Option-E itself.
@MainActor
@Test func theUSLayoutsUncomposedOutput() throws {
    let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
    let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
    let us = try #require(sources.first)
    func output(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> String? {
        RDPMacDeadKeys.output(keyCode: UInt16(keyCode), modifierFlags: modifierFlags, in: us)
    }
    #expect(output(kVK_ANSI_A, []) == "a")
    #expect(output(kVK_ANSI_A, .shift) == "A")
    #expect(output(kVK_ANSI_L, .option) == "¬")
    #expect(output(kVK_ANSI_E, .option) == "")
    #expect(output(kVK_Return, []) == "\r")

    // Right after Option-E, E types "é", Shift-A "Á", Return "´\r" and Option-E "´"; after a
    // key that starts no dead key, nothing is composed.
    func output(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags, after deadKey: (Int, NSEvent.ModifierFlags)) -> String? {
        RDPMacDeadKeys.output(
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
        RDPMacKeyboardMapping.characters(afterChordedDeadKey: composed, uncomposed: uncomposed)
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
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_KeypadEquals)) == RDPKeyboardScancode(code: 0x0D))
    #expect(sendsScancode(kVK_ANSI_KeypadEquals, [], characters: "=") == false)
    #expect(windowsTypes("=", scancode: 0x0D))
    #expect(windowsTypes("=", scancode: 0x0D, layout: 0x0000_0407) == false)
    #expect(windowsTypes("=", scancode: 0x0D, .shift) == false)
}

/// A remote IME commits its candidate with Space, so it goes as its scancode on every layout,
/// and as Unicode only when a dead key composed with it.
@Test func spaceSendsItsScancodeUnlessADeadKeyComposedWithIt() {
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_Space)) == RDPKeyboardScancode(code: 0x39))
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
    RDPMacKeyboardMapping.windowsTypes(
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
        RDPMacKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.keylayout." + name).rawValue
    }
    #expect(layout("US") == 0x0000_0409)
    #expect(layout("German") == 0x0000_0407)
    #expect(layout("British") == 0x0000_0809)
    #expect(layout("French") == 0x0000_080C)
    #expect(layout("Dvorak") == 0x0001_0409)
    #expect(layout("Australian") == 0x0000_0409)
    #expect(layout("ABC") == 0x0000_0409)
    #expect(RDPMacKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.inputmethod.Kotoeri.Japanese") == .unitedStates)
    // Every keyboard that can be announced has a table, so the scancode check covers it.
    for klid in Set(RDPMacKeyboardLayout.windowsLayouts.values) {
        #expect(RDPKeyboard(layout: RDPKeyboardLayout(rawValue: klid)).hasCharacterTable)
    }
}

/// Command and Control chords go as the keys' scancodes, which the server reads with the
/// announced layout, so each Latin letter an Apple layout types has to sit on the key where the
/// announced Windows layout types it, or ⌃Z arrives as Ctrl+Y. A Windows key counts when it
/// types the letter, or its capital with Shift, as Turkish Q's I key types "ı" and "I". Every
/// layout installed on this Mac is checked, with its keyboard type; the layouts mapped by this
/// comparison (2026-11-01) must be among them.
@MainActor
@Test func installedAppleLayoutsAnnounceAWindowsLayoutWithTheirLettersOnTheSameKeys() throws {
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
    let prefix = "com.apple.keylayout."
    var letterCounts: [String: Int] = [:]
    for source in sources {
        guard let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map({
                  Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
              }),
              identifier.hasPrefix(prefix)
        else {
            continue
        }
        let name = String(identifier.dropFirst(prefix.count))
        let keyboard = RDPKeyboard(layout: RDPMacKeyboardLayout.windowsLayout(forInputSourceID: identifier))
        #expect(keyboard.hasCharacterTable, "\(name)")
        var letterCount = 0
        var misplacedLetters: [String] = []
        // The ANSI character keys and the ISO key left of "1" (with Return, Tab and Space).
        for keyCode in 0 ... UInt16(kVK_ANSI_Grave) {
            guard let letter = RDPMacDeadKeys.output(keyCode: keyCode, modifierFlags: [], in: source),
                  letter.count == 1, letter.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) }),
                  let scancode = RDPMacKeyboardMapping.scancode(forKeyCode: keyCode)
            else {
                continue
            }
            letterCount += 1
            let unshifted = keyboard.character(for: scancode, shift: false, capsLock: false)
            let shifted = keyboard.character(for: scancode, shift: true, capsLock: false)
            if unshifted.map(String.init) != letter, shifted.map(String.init) != letter.uppercased() {
                misplacedLetters.append(letter)
            }
        }
        letterCounts[name] = letterCount
        let announced = String(format: "0x%08X", keyboard.layout.rawValue)
        if layoutsWhoseLettersNoTableMatches.contains(name) {
            #expect(misplacedLetters != [], "\(name) now matches \(announced); take it off the list")
        } else {
            #expect(misplacedLetters.sorted() == [], "\(name) is announced as \(announced)")
        }
    }
    // Not vacuous: the layouts were found and their letters read. macOS installs over 200 Apple
    // layouts, and a list of only the enabled ones would leave most of them unchecked.
    #expect(
        letterCounts.count >= 100,
        "Read only \(letterCounts.count) Apple layouts; TISCreateInputSourceList should list every installed one"
    )
    #expect(letterCounts["US"] == 26, "Found \(letterCounts.count) Apple layouts")
    for name in [
        "ABC-AZERTY", "ABC-QWERTZ", "Albanian", "FinnishExtended", "German-DIN-2137", "Hungarian-QWERTY",
        "Kabyle-AZERTY", "Latvian", "Lithuanian", "Lithuanian-LST1582", "Romanian", "Slovenian-QWERTZ",
        "Turkish-Standard",
    ] {
        #expect(letterCounts[name] != nil, "\(name) is not installed")
    }
}

/// Apple layouts whose letters no captured Windows table places as they do.
private let layoutsWhoseLettersNoTableMatches: Set<String> = [
    // Windows has no such layout.
    "Anjal", "Colemak", "Croatian", "Italian", "Serbian-Latin", "Slovenian", "Tibetan-Wylie",
    // Turkish F – Legacy, which has Q, W and X where Windows' Turkish F does not.
    "Turkish",
]

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
        RDPMacKeyboardLayout.windowsKeyboard(inputSourceLayout, isJapaneseInputSource: isJapanese, isJISKeyboard: isJIS)
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
        RDPMacKeyboardLayout.isJapanese(inputSourceID: identifier, languages: languages)
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_Grave), isISOKeyboard: false) == grave)
}

/// On an ISO keyboard the key between left Shift and Z goes as 0x56, where Windows' Japanese
/// 101-key layout types "\" and "|" as US does, so what the Mac types there goes as Unicode, as
/// does what the key left of 1 types.
@Test func theISOKeysGoAsUnicodeWithTheJapanese101KeyLayout() {
    let keyboard = RDPKeyboard.japanese101
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_Grave), isISOKeyboard: true) == RDPKeyboardScancode(code: 0x56))
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

    #expect(RDPMacKeyboardMapping.unicodeEvents(for: functionKey).isEmpty)
    #expect(RDPMacKeyboardMapping.unicodeEvents(for: "a") == [
        .unicode(codeUnit: 0x61, isReleased: false),
        .unicode(codeUnit: 0x61, isReleased: true),
    ])
}

@Test func focusSynchronizationKeepsNumLockOnAndMirrorsCapsLock() {
    #expect(RDPMacKeyboardMapping.toggleFlags(for: []) == [.numLock])
    #expect(RDPMacKeyboardMapping.toggleFlags(for: [.capsLock, .shift]) == [.numLock, .capsLock])
}

private final class RecordedInput: RDPInputEventSending {
    var supportsUnicodeInput = true
    var serverToggleKeys: RDPToggleKeyFlags?
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
    #expect(RDPMacKeyboardMapping.deadKeyText(aheadOf: "´\r") == "´")
    #expect(RDPMacKeyboardMapping.deadKeyText(aheadOf: "´\t") == "´")
    #expect(RDPMacKeyboardMapping.deadKeyText(aheadOf: "´\u{1B}") == "´")
    #expect(RDPMacKeyboardMapping.deadKeyText(aheadOf: "^\u{03}") == "^")
    for characters: String? in [
        nil, "", "\r", "a", "é", "^", "´", "´a", "´\r\r", "\r´", "\u{1B}\r", "\u{F702}", "\u{F702}\r", "\u{F728}",
    ] {
        #expect(RDPMacKeyboardMapping.deadKeyText(aheadOf: characters) == nil)
    }
}

@MainActor
@Test func aDeadKeysAccentGoesAheadOfReturnTabEscAndKeypadEnter() throws {
    let returnKey = RDPKeyboardScancode(code: 0x1C)
    let accent = RDPSlowPathInputEvent.unicode(codeUnit: 0xB4, isReleased: false)
    let accentUp = RDPSlowPathInputEvent.unicode(codeUnit: 0xB4, isReleased: true)
    let input = RecordedInput()
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
    view.inputSession = input
    view.flagsChanged(with: try keyEvent(.flagsChanged, keyCode: kVK_Command, modifierFlags: .command))

    view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_LeftArrow))

    #expect(input.events == [.keyboard(scancode: RDPKeyboardScancode(code: 0x4B, isExtended: true), isReleased: false)])
}

@MainActor
@Test func commandReleasedAloneStillTapsTheWindowsKey() throws {
    let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    let input = RecordedInput()
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
    view.inputSession = input
    view.isDeadKey = { keyCode, flags in Int(keyCode) == kVK_ANSI_E && flags.contains(.option) }
    view.uncomposedOutput = { keyCode, flags in
        Int(keyCode) == kVK_ANSI_E ? (flags.contains(.option) ? "" : "e") : nil
    }
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
    let view = RDPRemoteInputView()
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

/// The server's Caps Lock can change away from the Mac's, as another client of the session can
/// change it: once the server says so, the next key synchronizes the toggle keys first. A
/// server that goes on saying the same after that gets no more synchronizations.
@MainActor
@Test func aCapsLockTheServerSaysChangedIsSynchronizedBeforeTheNextKey() throws {
    let keyA = RDPKeyboardScancode(code: 0x1E)
    let input = RecordedInput()
    let view = RDPRemoteInputView()
    view.inputSession = input
    func pressA() throws -> [RDPSlowPathInputEvent] {
        input.events.removeAll()
        view.keyDown(with: try keyEvent(.keyDown, keyCode: kVK_ANSI_A, characters: "a", charactersIgnoringModifiers: "a"))
        view.keyUp(with: try keyEvent(.keyUp, keyCode: kVK_ANSI_A, characters: "a", charactersIgnoringModifiers: "a"))
        return input.events
    }
    let keys: [RDPSlowPathInputEvent] = [.keyboard(scancode: keyA, isReleased: false), .keyboard(scancode: keyA, isReleased: true)]

    #expect(try pressA() == keys)
    input.serverToggleKeys = [.numLock, .capsLock]
    #expect(try pressA() == [.synchronize(toggleFlags: [.numLock])] + keys)
    // The server did not take it, and says so again.
    #expect(try pressA() == keys)
    input.serverToggleKeys = [.numLock]
    #expect(try pressA() == keys)
    input.serverToggleKeys = [.numLock, .capsLock]
    #expect(try pressA() == [.synchronize(toggleFlags: [.numLock])] + keys)
    // Another toggle key the server changed leaves Caps Lock as the Mac's.
    input.serverToggleKeys = [.scrollLock]
    #expect(try pressA() == keys)
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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
    let view = RDPRemoteInputView()
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

/// A point mapping maps in place of the frame, so a view showing part of the desktop maps
/// through what it shows; without one the frame maps again.
@MainActor
@Test func aPointMappingMapsInPlaceOfTheFrame() throws {
    let input = RecordedInput()
    let view = RDPRemoteInputView()
    view.inputSession = input
    view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
    view.rdpFrame = RDPFrameMetadata(RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "test",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 200, bottom: 100),
        regionRects: [],
        encodedVideoData: Data()
    ))
    let move = try #require(NSEvent.mouseEvent(
        with: .mouseMoved,
        location: CGPoint(x: 100, y: 50),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))

    view.mouseMoved(with: move)
    view.pointMapping = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 400, height: 200),
        bounds: view.bounds,
        coordinateOrigin: .bottomLeft
    )
    view.mouseMoved(with: move)
    view.pointMapping = nil
    view.mouseMoved(with: move)

    #expect(input.events == [.pointerMove(x: 100, y: 50), .pointerMove(x: 200, y: 100), .pointerMove(x: 100, y: 50)])
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
            var heldKeys = RDPMacDeferredModifierKeys()
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

    #expect(RDPMacScrollWheel.pointerMove(to: point, inputState: &inputState) == [.pointerMove(x: 40, y: 30)])
    #expect(RDPMacScrollWheel.pointerMove(to: point, inputState: &inputState).isEmpty)
    #expect(RDPMacScrollWheel.pointerMove(to: RDPRemotePoint(x: 41, y: 30), inputState: &inputState)
        == [.pointerMove(x: 41, y: 30)])
}

/// The JIS keypad comma's scancode types nothing on most layouts, so the comma goes as Unicode
/// unless a modifier makes it a shortcut.
@Test func theJISKeypadCommaTypesAComma() {
    #expect(RDPMacKeyboardMapping.scancode(forKeyCode: UInt16(kVK_JIS_KeypadComma)) == RDPKeyboardScancode(code: 0x7E))
    #expect(sendsScancode(kVK_JIS_KeypadComma, [], characters: ",") == false)
    #expect(sendsScancode(kVK_JIS_KeypadComma, .control, characters: ","))
}
#endif
