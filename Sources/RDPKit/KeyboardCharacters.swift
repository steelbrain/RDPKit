/// A keyboard as a client announces it: a Windows layout, and the keyboard type and subtype,
/// which choose between the layout's tables where Windows has more than one ([MS-RDPBCGR]
/// 2.2.1.3.2). Of the layouts `character(for:shift:capsLock:)` knows, only Japanese has more
/// than one: Windows 11's registry (`Terminal Server\KeyboardType Mapping\JPN`) maps type 7
/// with subtype 2 to the 106/109-key kbd106.dll, and with subtype 0 to the 101-key kbd101.dll
/// (live, 2026-10-29). Announce it with `RDPConnectionConfiguration`'s `keyboardLayout`,
/// `keyboardType` and `keyboardSubType`.
public struct RDPKeyboard: Hashable, Sendable {
    public var layout: RDPKeyboardLayout
    public var type: RDPKeyboardType
    /// An OEM-dependent value; 0 for most keyboards.
    public var subType: UInt32

    public init(layout: RDPKeyboardLayout, type: RDPKeyboardType = .ibmEnhanced, subType: UInt32 = 0) {
        self.layout = layout
        self.type = type
        self.subType = subType
    }

    public static let unitedStates = RDPKeyboard(layout: .unitedStates)
    /// Windows' Japanese layout with a 106/109-key keyboard (kbd106.dll).
    public static let japanese106 = RDPKeyboard(layout: .japanese, type: .japanese, subType: 2)
    /// Windows' Japanese layout with a 101-key keyboard (kbd101.dll).
    public static let japanese101 = RDPKeyboard(layout: .japanese, type: .japanese)

    /// Whether `character(for:shift:capsLock:)` knows what this keyboard types: every layout
    /// a Mac input source announces does, with an IBM enhanced keyboard of subtype 0, and
    /// Japanese with the Japanese keyboard type and subtype 0 or 2.
    public var hasCharacterTable: Bool {
        RDPKeyboardCharacterTable.table(for: self) != nil
    }

    /// The character Windows types for `scancode` with this keyboard, from tables Windows 11
    /// reported. Nil when the key is a dead key or types nothing or more than one character,
    /// when Caps Lock does something to it other than shift it, and for a key or keyboard with
    /// no table. A client can send a typed character as the key's scancode when this matches
    /// it, and as Unicode otherwise.
    public func character(for scancode: RDPKeyboardScancode, shift: Bool, capsLock: Bool) -> Unicode.Scalar? {
        RDPKeyboardCharacterTable.table(for: self)?.character(for: scancode, isShifted: shift, isCapsLocked: capsLock)
    }
}

extension RDPKeyboardLayout {
    /// Japanese, whose characters follow the keyboard type and subtype; see `RDPKeyboard`.
    public static let japanese = RDPKeyboardLayout(rawValue: 0x0000_0411)
}

/// What Windows types for each character key with one keyboard; the tables are generated into
/// WindowsKeyboardLayoutTables.swift.
struct RDPKeyboardCharacterTable {
    private static let parsed = Dictionary(
        uniqueKeysWithValues: layouts.map { klid, strings in
            (RDPKeyboard(layout: RDPKeyboardLayout(rawValue: klid)), RDPKeyboardCharacterTable(strings))
        } + japaneseLayouts.map { subType, strings in
            (RDPKeyboard(layout: .japanese, type: .japanese, subType: subType), RDPKeyboardCharacterTable(strings))
        }
    )

    private let unshifted: [Unicode.Scalar]
    private let shifted: [Unicode.Scalar]
    private let capsLock: [Unicode.Scalar]

    private init(_ strings: (unshifted: String, shifted: String, capsLock: String)) {
        unshifted = Array(strings.unshifted.unicodeScalars)
        shifted = Array(strings.shifted.unicodeScalars)
        capsLock = Array(strings.capsLock.unicodeScalars)
    }

    static func table(for keyboard: RDPKeyboard) -> RDPKeyboardCharacterTable? {
        parsed[keyboard]
    }

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
