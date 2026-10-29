import AppKit
import Carbon.HIToolbox
import RDPKit

/// The Windows keyboard layout to announce for the Mac's current one, so the server turns
/// scancodes into the characters the keys are labelled with.
enum MacRDPKeyboardLayout {
    static let japanese = RDPKeyboardLayout(rawValue: 0x0000_0411)

    /// The layout of the current input source; an input method such as a CJK IME
    /// reports the layout it types with. Unknown layouts fall back to US English. Japanese
    /// input sources and JIS keyboards may get Windows' Japanese layout instead; see
    /// `windowsLayout(_:isJapaneseInputSource:isJISKeyboard:)`.
    @MainActor
    static func current() -> RDPKeyboardLayout {
        let layoutSourceID: String? = TISCopyCurrentKeyboardLayoutInputSource().flatMap {
            property(kTISPropertyInputSourceID, of: $0.takeRetainedValue())
        }
        let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        return windowsLayout(
            layoutSourceID.map(windowsLayout(forInputSourceID:)) ?? .unitedStates,
            isJapaneseInputSource: inputSource.map {
                isJapanese(
                    inputSourceID: property(kTISPropertyInputSourceID, of: $0) ?? "",
                    languages: property(kTISPropertyInputSourceLanguages, of: $0) ?? []
                )
            } ?? false,
            isJISKeyboard: KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardJIS
        )
    }

    fileprivate static func property<Value>(_ key: CFString, of source: TISInputSource) -> Value? {
        TISGetInputSourceProperty(source, key).flatMap {
            Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? Value
        }
    }

    /// Windows' Japanese layout for a Japanese input source, whatever the keyboard, since the
    /// server starts its Japanese IME with that layout. On a JIS keyboard it replaces US
    /// English too (ABC, US, or a layout with no Windows one): macOS types the JIS legends
    /// with those there, and Windows' Japanese layout types them for the same scancodes,
    /// while its US layout differs on most punctuation keys and types nothing on Yen and Ro.
    /// A JIS keyboard keeps any other layout, such as Korean, whose IME needs its own.
    static func windowsLayout(
        _ inputSourceLayout: RDPKeyboardLayout,
        isJapaneseInputSource: Bool,
        isJISKeyboard: Bool
    ) -> RDPKeyboardLayout {
        if isJapaneseInputSource || (isJISKeyboard && inputSourceLayout == .unitedStates) {
            return japanese
        }
        return inputSourceLayout
    }

    /// A source whose first language is Japanese, as the kana modes of Japanese input methods
    /// report, or any mode of Apple's Japanese input method: its Latin mode (英字) reports
    /// English, but the Eisu and Kana keys switch modes mid-session, while the layout is
    /// announced only at connection. FreeRDP's keyboard_apple.c maps that mode to Japanese too.
    static func isJapanese(inputSourceID: String, languages: [String]) -> Bool {
        languages.first == "ja" || inputSourceID.hasPrefix("com.apple.inputmethod.Kotoeri.")
    }

    /// The Japanese table is what Windows types with a 106/109-key keyboard (kbd106.dll), so
    /// the server is told that keyboard: type 7, subtype 2, as Windows identifies one (subtype
    /// 0 is the 101-key kbd101.dll). Function keys stay at RDPKit's default of 12.
    static func keyboardType(for layout: RDPKeyboardLayout) -> RDPKeyboardType {
        layout == japanese ? .japanese : .ibmEnhanced
    }

    static func keyboardSubType(for layout: RDPKeyboardLayout) -> UInt32 {
        layout == japanese ? 2 : 0
    }

    static func windowsLayout(forInputSourceID identifier: String) -> RDPKeyboardLayout {
        let prefix = "com.apple.keylayout."
        guard identifier.hasPrefix(prefix), let klid = windowsLayouts[String(identifier.dropFirst(prefix.count))] else {
            return .unitedStates
        }
        return RDPKeyboardLayout(rawValue: klid)
    }

    /// FreeRDP's mapping (libfreerdp/locale/keyboard_apple.c), except where it names a
    /// language ID Windows 11 has no layout for: Australian and the Arabic PC layouts get the
    /// Windows layouts they mirror, and Afghan Uzbek, Inuktitut and Myanmar fall back to US.
    /// A layout added here needs its table: rerun Scripts/generate-windows-keyboard-layout-tables.py.
    static let windowsLayouts: [String: UInt32] = [
        "2SetHangul": 0x0000_0412,
        "390Hangul": 0x0000_0412,
        "3SetHangul": 0x0000_0412,
        "AfghanDari": 0x0005_0429,
        "AfghanPashto": 0x0000_0463,
        "Arabic": 0x0000_0401,
        "Arabic-QWERTY": 0x0000_0401,
        "ArabicPC": 0x0000_0401,
        "Armenian-HMQWERTY": 0x0000_042B,
        "Armenian-WesternQWERTY": 0x0000_042B,
        "Australian": 0x0000_0409,
        "Austrian": 0x0000_0407,
        "Azeri": 0x0000_042C,
        "Bangla": 0x0002_0445,
        "Bangla-QWERTY": 0x0002_0445,
        "Belgian": 0x0000_0813,
        "Brazilian": 0x0000_0416,
        "British": 0x0000_0809,
        "British-PC": 0x0000_0809,
        "Bulgarian": 0x0000_0402,
        "Bulgarian-Phonetic": 0x0004_0402,
        "Byelorussian": 0x0000_0423,
        "Canadian": 0x0000_0409,
        "Canadian-CSA": 0x0001_1009,
        "CangjieKeyboard": 0x0000_0404,
        "Cherokee-Nation": 0x0000_045C,
        "Cherokee-QWERTY": 0x0000_0409,
        "Colemak": 0x0000_0409,
        "Croatian": 0x0000_041A,
        "Croatian-PC": 0x0000_041A,
        "Czech": 0x0000_0405,
        "Czech-QWERTY": 0x0001_0405,
        "Danish": 0x0000_0406,
        "Devanagari": 0x0000_0439,
        "Devanagari-QWERTY": 0x0000_0439,
        "Dutch": 0x0002_0409,
        "Dvorak": 0x0001_0409,
        "Dvorak-Left": 0x0003_0409,
        "DVORAK-QWERTYCMD": 0x0001_0409,
        "Dvorak-Right": 0x0004_0409,
        "Estonian": 0x0000_0425,
        "Faroese": 0x0000_0438,
        "Finnish": 0x0000_040B,
        "FinnishExtended": 0x0002_083B,
        "FinnishSami-PC": 0x0001_083B,
        "French": 0x0000_080C,
        "French-numerical": 0x0000_080C,
        "French-PC": 0x0000_040C,
        "Georgian-QWERTY": 0x0001_0437,
        "German": 0x0000_0407,
        "GJCRomaja": 0x0000_0409,
        "Greek": 0x0000_0408,
        "GreekPolytonic": 0x0006_0408,
        "Gujarati": 0x0000_0447,
        "Gujarati-QWERTY": 0x0000_0447,
        "Gurmukhi": 0x0000_0446,
        "Gurmukhi-QWERTY": 0x0000_0446,
        "Hawaiian": 0x0000_0475,
        "Hebrew": 0x0000_040D,
        "Hebrew-PC": 0x0000_040D,
        "Hebrew-QWERTY": 0x0000_040D,
        "HNCRomaja": 0x0000_0409,
        "Hungarian": 0x0000_040E,
        "Hungarian-QWERTY": 0x0000_040E,
        "Icelandic": 0x0000_040F,
        "Irish": 0x0000_1809,
        "IrishExtended": 0x0000_1809,
        "Italian": 0x0000_0410,
        "Italian-Pro": 0x0000_0410,
        "Jawi-QWERTY": 0x0000_0401,
        "Kannada": 0x0000_044B,
        "Kannada-QWERTY": 0x0000_044B,
        "Kazakh": 0x0000_043F,
        "Khmer": 0x0001_0453,
        "Latvian": 0x0000_0426,
        "Lithuanian": 0x0000_0427,
        "Macedonian": 0x0000_042F,
        "Malayalam": 0x0000_044C,
        "Malayalam-QWERTY": 0x0000_044C,
        "Maltese": 0x0000_043A,
        "Maori": 0x0000_0481,
        "Nepali": 0x0000_0461,
        "NorthernSami": 0x0000_043B,
        "Norwegian": 0x0000_0414,
        "NorwegianExtended": 0x0000_0414,
        "NorwegianSami-PC": 0x0000_0414,
        "Oriya": 0x0000_0448,
        "Persian": 0x0005_0429,
        "Persian-ISIRI2901": 0x0005_0429,
        "Polish": 0x0001_0415,
        "PolishPro": 0x0000_0415,
        "Portuguese": 0x0000_0816,
        "Romanian": 0x0000_0418,
        "Romanian-Standard": 0x0001_0418,
        "Russian": 0x0000_0419,
        "Russian-Phonetic": 0x0002_0419,
        "RussianWin": 0x0000_0419,
        "Sami-PC": 0x0002_083B,
        "Serbian": 0x0000_0C1A,
        "Serbian-Latin": 0x0000_081A,
        "Sinhala": 0x0000_045B,
        "Sinhala-QWERTY": 0x0000_045B,
        "Slovak": 0x0000_041B,
        "Slovak-QWERTY": 0x0001_041B,
        "Slovenian": 0x0000_0424,
        "Spanish": 0x0000_040A,
        "Spanish-ISO": 0x0000_040A,
        "Swedish": 0x0000_041D,
        "Swedish-Pro": 0x0000_041D,
        "SwedishSami-PC": 0x0000_041D,
        "SwissFrench": 0x0000_100C,
        "SwissGerman": 0x0000_0807,
        "Telugu": 0x0000_044A,
        "Telugu-QWERTY": 0x0000_044A,
        "Thai": 0x0000_041E,
        "Thai-PattaChote": 0x0001_041E,
        "Tibetan-QWERTY": 0x0000_0451,
        "Tibetan-Wylie": 0x0000_0451,
        "TibetanOtaniUS": 0x0000_0451,
        "Turkish": 0x0001_041F,
        "Turkish-QWERTY": 0x0000_041F,
        "Turkish-QWERTY-PC": 0x0000_041F,
        "Ukrainian": 0x0000_0422,
        "Ukrainian-PC": 0x0000_0422,
        "UnicodeHexInput": 0x0000_0409,
        "Urdu": 0x0000_0420,
        "US": 0x0000_0409,
        "USExtended": 0x0000_0409,
        "USInternational-PC": 0x0000_0409,
        "Uyghur": 0x0000_0480,
        "Vietnamese": 0x0000_042A,
        "Welsh": 0x0000_0452,
    ]
}

/// Whether a key starts a dead key with the Mac's keyboard layout, as Option-E does on US: it
/// types nothing, and the next key types the accent. A custom layout can also give a key no
/// output with Option without making it a dead key; that key then goes as Alt and the key.
@MainActor
enum MacRDPDeadKeys {
    private struct Keystroke: Hashable {
        let inputSourceID: String
        let keyCode: UInt16
        let modifierKeyState: UInt32
    }

    private static var answers: [Keystroke: Bool] = [:]

    /// With the current layout, remembered per input source. A layout whose data cannot be read
    /// counts the key as dead, as Apple's layouts make every Option key that types nothing.
    static func isDeadKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let inputSourceID: String = MacRDPKeyboardLayout.property(kTISPropertyInputSourceID, of: source)
        else {
            return true
        }
        let keystroke = Keystroke(
            inputSourceID: inputSourceID,
            keyCode: keyCode,
            modifierKeyState: modifierKeyState(modifierFlags)
        )
        if let answer = answers[keystroke] {
            return answer
        }
        let answer = isDeadKey(keyCode: keyCode, modifierFlags: modifierFlags, in: source) ?? true
        answers[keystroke] = answer
        return answer
    }

    /// UCKeyTranslate with dead keys on leaves a dead-key state for a key that starts one. Nil
    /// when `source` has no Unicode layout data.
    static func isDeadKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, in source: TISInputSource) -> Bool? {
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue())
        else {
            return nil
        }
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState(modifierFlags),
            UInt32(LMGetKbdType()),
            0,
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        return status == noErr ? deadKeyState != 0 : nil
    }

    /// The Carbon modifier bits (EventModifiers) shifted down a byte, as UCKeyTranslate takes them.
    private static func modifierKeyState(_ modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        let carbonModifiers: [(NSEvent.ModifierFlags, Int)] = [
            (.command, cmdKey), (.shift, shiftKey), (.capsLock, alphaLock), (.option, optionKey), (.control, controlKey),
        ]
        let modifiers = carbonModifiers.reduce(0) { modifiers, pair in
            modifierFlags.contains(pair.0) ? modifiers | pair.1 : modifiers
        }
        return UInt32(modifiers >> 8) & 0xFF
    }
}

/// What Windows types for each character key with one keyboard layout.
struct MacRDPWindowsKeyboardLayout {
    private static let parsed = layouts.mapValues(MacRDPWindowsKeyboardLayout.init)

    private let unshifted: [Unicode.Scalar]
    private let shifted: [Unicode.Scalar]
    private let capsLock: [Unicode.Scalar]

    private init(_ strings: (unshifted: String, shifted: String, capsLock: String)) {
        unshifted = Array(strings.unshifted.unicodeScalars)
        shifted = Array(strings.shifted.unicodeScalars)
        capsLock = Array(strings.capsLock.unicodeScalars)
    }

    /// Nil for a layout with no captured table.
    static func layout(_ layout: RDPKeyboardLayout) -> MacRDPWindowsKeyboardLayout? {
        parsed[layout.rawValue]
    }

    /// The character the key types, or nil when it is a dead key, types nothing or more than
    /// one character, or Caps Lock does something to it other than shift it.
    func character(for scancode: RDPKeyboardScancode, isShifted: Bool, isCapsLocked: Bool) -> Unicode.Scalar? {
        guard !scancode.isExtended, let index = Self.scancodes.firstIndex(of: scancode.code) else {
            return nil
        }
        var isShifted = isShifted
        if isCapsLocked {
            switch capsLock[index] {
            case "S":
                isShifted.toggle()
            case "-":
                break
            default:
                return nil
            }
        }
        let character = isShifted ? shifted[index] : unshifted[index]
        return character == "\0" ? nil : character
    }
}
