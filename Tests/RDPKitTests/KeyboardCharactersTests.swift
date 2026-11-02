@testable import RDPKit
import Testing

private func character(
    _ keyboard: RDPKeyboard,
    _ code: UInt16,
    shift: Bool = false,
    capsLock: Bool = false
) -> Unicode.Scalar? {
    keyboard.character(for: RDPKeyboardScancode(code: code), shift: shift, capsLock: capsLock)
}

/// A key types what the layout's table holds for Shift and Caps Lock, Caps Lock shifting only
/// the keys it shifts on Windows.
@Test func aKeyboardTypesItsLayoutsCharacters() {
    let unitedStates = RDPKeyboard.unitedStates
    #expect(character(unitedStates, 0x1E) == "a")
    #expect(character(unitedStates, 0x1E, shift: true) == "A")
    #expect(character(unitedStates, 0x1E, capsLock: true) == "A")
    #expect(character(unitedStates, 0x1E, shift: true, capsLock: true) == "a")
    // Caps Lock leaves the digits alone on US, and shifts them on French.
    #expect(character(unitedStates, 0x02, capsLock: true) == "1")
    let french = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_040C))
    #expect(character(french, 0x02) == "&")
    #expect(character(french, 0x02, capsLock: true) == "1")
    #expect(character(french, 0x02, shift: true, capsLock: true) == "&")
}

/// A dead key, a key Caps Lock does something else to, an extended key, a key with no column
/// and a keyboard with no table have no character.
@Test func aKeyWithoutOneCharacterHasNone() {
    let german = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0407))
    #expect(character(german, 0x0C) == "ß")
    // ´ is a dead key on German.
    #expect(character(german, 0x0D) == nil)
    let czech = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0405))
    #expect(character(czech, 0x03) == "ě")
    #expect(character(czech, 0x03, shift: true) == "2")
    #expect(character(czech, 0x03, capsLock: true) == nil)
    #expect(RDPKeyboard.unitedStates.character(for: RDPKeyboardScancode(code: 0x1E, isExtended: true), shift: false, capsLock: false) == nil)
    #expect(character(.unitedStates, 0x39) == nil)
    let unknown = RDPKeyboard(layout: RDPKeyboardLayout(rawValue: 0x0000_0000))
    #expect(unknown.hasCharacterTable == false)
    #expect(character(unknown, 0x1E) == nil)
}

/// Japanese's tables follow the keyboard type and subtype: the 106/109-key one types the JIS
/// legends, the 101-key one what US types on every key, and Japanese announced with another
/// keyboard type has none.
@Test func japanesesTablesFollowTheKeyboardTypeAndSubtype() {
    #expect(RDPKeyboard.japanese106.hasCharacterTable)
    #expect(character(.japanese106, 0x03, shift: true) == "\"")
    #expect(character(.japanese106, 0x1A) == "@")
    #expect(character(.japanese106, 0x7D) == "\\")
    #expect(RDPKeyboard.japanese101.hasCharacterTable)
    for code in RDPKeyboardCharacterTable.scancodes {
        for (shift, capsLock) in [(false, false), (true, false), (false, true), (true, true)] {
            #expect(character(.japanese101, code, shift: shift, capsLock: capsLock) == character(.unitedStates, code, shift: shift, capsLock: capsLock))
        }
    }
    #expect(RDPKeyboard(layout: .japanese).hasCharacterTable == false)
    #expect(RDPKeyboard(layout: .japanese, type: .japanese, subType: 1).hasCharacterTable == false)
}

/// Every table has a character and a Caps Lock flag for each key.
@Test func everyKeyboardTableCoversEveryKey() {
    let tables = Array(RDPKeyboardCharacterTable.layouts.values) + RDPKeyboardCharacterTable.japaneseLayouts.values
    #expect(tables.count >= 80, "the tables hold 90 keyboards")
    for table in tables {
        #expect(table.unshifted.unicodeScalars.count == RDPKeyboardCharacterTable.scancodes.count)
        #expect(table.shifted.unicodeScalars.count == RDPKeyboardCharacterTable.scancodes.count)
        #expect(table.capsLock.unicodeScalars.count == RDPKeyboardCharacterTable.scancodes.count)
        #expect(table.capsLock.unicodeScalars.allSatisfy { "S-?".unicodeScalars.contains($0) })
    }
    for klid in RDPKeyboardCharacterTable.layouts.keys {
        #expect(RDPKeyboard(layout: RDPKeyboardLayout(rawValue: klid)).hasCharacterTable)
    }
}

/// A configuration's keyboard is its layout, type and subtype together, both ways.
@Test func aConfigurationsKeyboardIsItsLayoutTypeAndSubtype() {
    var configuration = RDPConnectionConfiguration(host: "example.test")
    #expect(configuration.keyboard == .unitedStates)

    configuration.keyboard = .japanese106
    #expect(configuration.keyboardLayout == .japanese)
    #expect(configuration.keyboardType == .japanese)
    #expect(configuration.keyboardSubType == 2)

    configuration.keyboardSubType = 0
    #expect(configuration.keyboard == RDPKeyboard(layout: .japanese, type: .japanese))
}

