import Foundation

/// The file names the side a clipboard file is copied to accepts: `apple` for remote files
/// saved on this device, `windows` for local files the server pastes.
/// The paths a set of files has taken, ignoring case, and the number each name tries next, so
/// the thousandth "a.txt" does not try the 999 numbers before its own.
struct RDPClipboardUsedFileNames {
    fileprivate var paths = Set<String>()
    fileprivate var nextNumbers: [String: Int] = [:]
}

enum RDPClipboardFileNameRules {
    /// APFS and HFS+: no "/" or ":", at most 255 UTF-8 bytes. Control characters and line
    /// separators go too, so a name shows on one line, and so do the bidi embeddings,
    /// overrides and isolates, which can show "x\u{202E}fdp.command" as "xdnammoc.pdf".
    /// Other format characters, such as ZWNJ, ZWJ and bidi marks, spell names and are kept.
    /// A leading "." becomes "_": Finder hides such a name, so a server could leave ".zshrc"
    /// or ".ssh" unseen wherever the user pastes.
    case apple
    /// Windows (Naming Files, Paths, and Namespaces), for a path relative to where the server
    /// pastes: cFileName carries a file inside a folder as "folder\file", as the shell's
    /// FILEGROUPDESCRIPTORW does. `\` or `/` separates its components, and each has none of
    /// `: * ? " < > |` or U+0000-U+001F, no device name such as CON or NUL.txt, no trailing
    /// dot or space, and at most the 255 UTF-16 code units NTFS allows. The whole path is at
    /// most the 259 code units cFileName holds before its terminator.
    case windows

    // Not `.controlCharacters`: that is Cf as well as Cc.
    private static let invalidAppleScalars = CharacterSet(charactersIn: ":")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x00) ... Unicode.Scalar(0x1F)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x7F) ... Unicode.Scalar(0x9F)))
        .union(.newlines)
        .union(CharacterSet(charactersIn: "\u{202A}" ... "\u{202E}"))
        .union(CharacterSet(charactersIn: "\u{2066}" ... "\u{2069}"))
    private static let invalidWindowsScalars = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x00) ... Unicode.Scalar(0x1F)))

    /// Names Windows opens as a device whatever follows the first dot: "nul.tar.gz" is NUL.
    private static let windowsDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        for digit in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{B9}", "\u{B2}", "\u{B3}"] {
            names.insert("COM" + digit)
            names.insert("LPT" + digit)
        }
        return names
    }()

    /// 255 UTF-8 bytes on APFS and HFS+, 255 UTF-16 code units on NTFS.
    private static let maximumComponentLength = 255
    /// The UTF-16 code units cFileName holds before its terminating null.
    private static let maximumWindowsPathLength = 259

    /// `fileName` made valid, as a single component, and different, ignoring case, from every
    /// name in `usedFileNames`, which it joins. A clash gets "-2", "-3" and so on before the
    /// extension.
    func uniqueFileName(_ fileName: String, usedFileNames: inout RDPClipboardUsedFileNames) -> String {
        uniquePath(of: sanitizedFileName(fileName), in: nil, usedPaths: &usedFileNames)
    }

    /// The paths `entries`, local files and folders, are offered to Windows under, in order:
    /// each made valid as `windows` describes, and different, ignoring case, from every other.
    ///
    /// A folder keeps the path it first gets, from its own entry or the first entry inside
    /// it, and every later entry inside it uses that path. So a folder numbered to differ from
    /// a file or another folder still holds its entries. Folders are told apart as they are
    /// spelled: "What?" and "What*" both become "What_", and the second is "What_-2" with
    /// everything in it.
    static func windowsPaths(of entries: [(fileName: String, isDirectory: Bool)]) -> [String] {
        var usedPaths = RDPClipboardUsedFileNames()
        // Each folder's path, by its components as given, joined with "\".
        var folderPaths: [String: String] = [:]
        return entries.map { entry in
            let components = windows.windowsComponents(of: entry.fileName)
            guard let name = components.last else {
                return windows.uniquePath(of: windows.fallbackFileName, in: nil, usedPaths: &usedPaths)
            }
            var folder: String?
            var key = ""
            for component in components.dropLast() {
                key += key.isEmpty ? component.given : "\\" + component.given
                if let path = folderPaths[key] {
                    folder = path
                } else {
                    folder = windows.uniquePath(of: component.valid, in: folder, usedPaths: &usedPaths)
                    folderPaths[key] = folder
                }
            }
            key += key.isEmpty ? name.given : "\\" + name.given
            if entry.isDirectory, let path = folderPaths[key] {
                return path
            }
            let path = windows.uniquePath(of: name.valid, in: folder, usedPaths: &usedPaths)
            if entry.isDirectory {
                folderPaths[key] = path
            }
            return path
        }
    }

    /// `name`, a valid component, in `folder`, and different, ignoring case, from every path
    /// in `usedPaths`, which it joins. A clash gets "-2", "-3" and so on before the extension
    /// of `name`.
    ///
    /// A Windows path too long for cFileName has `name` shortened before the extension. When
    /// `folder` leaves no room for one character of its base name, its extension and its
    /// number, it goes to the top level alone: pasted outside its folder, but whole and under
    /// its own name.
    private func uniquePath(of name: String, in folder: String?, usedPaths: inout RDPClipboardUsedFileNames) -> String {
        // Names are never given back, so every number below the next one for this name is taken.
        let key = Self.folded((folder ?? "") + "\\" + name)
        var folder = folder
        var number = usedPaths.nextNumbers[key] ?? 1
        while true {
            guard let candidate = candidate(name, numbered: number, in: folder) else {
                // No room left in the folders: the top level.
                folder = nil
                number = 1
                continue
            }
            if usedPaths.paths.insert(Self.folded(candidate)).inserted {
                usedPaths.nextNumbers[key] = number + 1
                return candidate
            }
            number += 1
        }
    }

    /// `path` as a file system that ignores case compares it. APFS folds case as Unicode does,
    /// so "a\u{3C2}" and "A\u{3A3}", or "\u{DF}" and "SS", name one file, which `lowercased()`
    /// keeps apart; String equality already makes canonically equivalent names one.
    private static func folded(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: nil)
    }

    /// `name` in `folder`, from 2 on with "-`number`" before its extension, and shortened to
    /// fit; nil when `folder` leaves no room for that suffix and one code unit before it.
    private func candidate(_ name: String, numbered number: Int, in folder: String?) -> String? {
        let nameText = name as NSString
        let extensionText = nameText.pathExtension.isEmpty ? "" : ".\(nameText.pathExtension)"
        let suffix = number == 1 ? extensionText : "-\(number)\(extensionText)"
        // Check the name as stored: sanitizing again can trim what shortening left.
        guard let folder else {
            return number == 1
                ? name
                : sanitizedFileName(joined(
                    nameText.deletingPathExtension,
                    suffix: suffix,
                    maximumLength: Self.maximumComponentLength
                ))
        }
        let room = min(Self.maximumComponentLength, Self.maximumWindowsPathLength - length(of: folder) - 1)
        guard room > length(of: suffix) else {
            return nil
        }
        let numbered = number == 1 ? name : joined(nameText.deletingPathExtension, suffix: suffix, maximumLength: room)
        return sanitizedComponent(numbered, maximumLength: room).map { folder + "\\" + $0 }
    }

    /// Reduces an untrusted name to a single valid file name component that cannot be "."
    /// or "..". Invalid characters become "_", and a name too long keeps its extension.
    func sanitizedFileName(_ fileName: String) -> String {
        sanitizedComponent(component(of: fileName), maximumLength: Self.maximumComponentLength) ?? fallbackFileName
    }

    /// `component` made valid within `maximumLength`, or nil when that leaves nothing, "."
    /// or "..".
    private func sanitizedComponent(_ component: String, maximumLength: Int) -> String? {
        var sanitizedScalars = String.UnicodeScalarView()
        for scalar in component.unicodeScalars {
            sanitizedScalars.append(isInvalid(scalar) ? "_" : scalar)
        }
        var sanitized = fitted(trimmed(String(sanitizedScalars)), maximumLength: maximumLength)
        if self == .windows, Self.isWindowsDeviceName(sanitized) {
            // A leading "_" survives shortening, which could cut a trailing one back to the device name.
            sanitized = fitted("_" + sanitized, maximumLength: maximumLength)
        }
        guard sanitized.isEmpty == false, sanitized != ".", sanitized != ".." else {
            return nil
        }
        if self == .apple, sanitized.hasPrefix(".") {
            sanitized = "_" + sanitized.dropFirst()
        }
        return sanitized
    }

    /// The components of a Windows path, as given and made valid; those that come to nothing,
    /// "." or ".." are dropped.
    private func windowsComponents(of fileName: String) -> [(given: String, valid: String)] {
        fileName.unicodeScalars
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .compactMap { scalars in
                let given = String(Substring(scalars))
                return sanitizedComponent(given, maximumLength: Self.maximumComponentLength).map { (given, $0) }
            }
    }

    private var fallbackFileName: String {
        switch self {
        case .apple:
            "remote-file"
        case .windows:
            "file"
        }
    }

    private func width(of scalar: Unicode.Scalar) -> Int {
        switch self {
        case .apple:
            UTF8.width(scalar)
        case .windows:
            UTF16.width(scalar)
        }
    }

    private func length(of fileName: String) -> Int {
        switch self {
        case .apple:
            fileName.utf8.count
        case .windows:
            fileName.utf16.count
        }
    }

    /// A remote name can be a path; a local one comes here one component at a time, so a
    /// separator left in it is just an invalid character.
    private func component(of fileName: String) -> String {
        switch self {
        case .apple:
            fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        case .windows:
            fileName
        }
    }

    private func isInvalid(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .apple:
            Self.invalidAppleScalars.contains(scalar)
        case .windows:
            Self.invalidWindowsScalars.contains(scalar)
        }
    }

    private func trimmed(_ fileName: String) -> String {
        guard self == .windows else {
            return fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Path normalization drops a name's trailing dots and spaces (U+0020), so "notes.txt. "
        // would name "notes.txt" (File path formats on Windows systems, "Trim characters"). It
        // drops nothing else: leading spaces, and other whitespace such as U+00A0, U+3000 or
        // U+200B at either end, stay in the name.
        var trimmed = fileName
        while let last = trimmed.unicodeScalars.last, last == "." || last == " " {
            trimmed.unicodeScalars.removeLast()
        }
        return trimmed
    }

    /// `fileName`, or when it is longer than `maximumLength`, its base name shortened to keep
    /// the extension.
    private func fitted(_ fileName: String, maximumLength: Int) -> String {
        guard length(of: fileName) > maximumLength else {
            return fileName
        }
        let name = fileName as NSString
        return trimmed(joined(
            name.deletingPathExtension,
            suffix: name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)",
            maximumLength: maximumLength
        ))
    }

    /// Joins `baseName` and `suffix`, shortening the base name to fit `maximumLength`.
    private func joined(_ baseName: String, suffix: String, maximumLength: Int) -> String {
        let baseName = prefix(baseName, maximumLength: max(1, maximumLength - length(of: suffix)))
        return prefix(baseName + suffix, maximumLength: maximumLength)
    }

    /// Cuts by Unicode scalar, so one oversized grapheme cluster is shortened rather than
    /// dropped, and a UTF-16 surrogate pair is never split.
    private func prefix(_ text: String, maximumLength: Int) -> String {
        var length = 0
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix { scalar in
            length += width(of: scalar)
            return length <= maximumLength
        }))
    }

    /// Whether Windows may open `fileName` as a device. Naming Files, Paths, and Namespaces
    /// reserves a device name with an extension too ("NUL.txt" is NUL), as Windows before 11
    /// does. Windows 11 26200 reserves none inside a folder; as a bare name it takes "CON",
    /// "CON " and "CON:" as the device, but not " CON", " COM1" or "CON.txt"
    /// (RtlIsDosDeviceName_U and GetFullPathNameW, observed 2026-10-29). So whitespace before
    /// the stem makes a name no device name. The extension, and whitespace after the stem,
    /// are still ignored for Windows before 11, whose rule no document gives; Windows 11
    /// ignores only U+0020 there.
    private static func isWindowsDeviceName(_ fileName: String) -> Bool {
        var stem = String(fileName.prefix { $0 != "." })
        while let last = stem.unicodeScalars.last, CharacterSet.whitespaces.contains(last) {
            stem.unicodeScalars.removeLast()
        }
        return windowsDeviceNames.contains(stem.uppercased())
    }
}
