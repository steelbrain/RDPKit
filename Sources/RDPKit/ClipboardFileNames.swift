import Foundation

/// The file names the side a clipboard file is copied to accepts: `apple` for remote files
/// saved on this device, `windows` for local files the server pastes.
enum RDPClipboardFileNameRules {
    /// APFS and HFS+: no "/" or ":", at most 255 UTF-8 bytes.
    case apple
    /// Windows (Naming Files, Paths, and Namespaces), for a path relative to where the server
    /// pastes: cFileName carries a file inside a folder as "folder\file", as the shell's
    /// FILEGROUPDESCRIPTORW does. `\` or `/` separates its components, and each has none of
    /// `: * ? " < > |` or U+0000-U+001F, no device name such as CON or NUL.txt, no trailing
    /// dot or space, and at most the 255 UTF-16 code units NTFS allows. The whole path is at
    /// most the 259 code units cFileName holds before its terminator.
    case windows

    private static let invalidAppleScalars = CharacterSet(charactersIn: ":")
        .union(.controlCharacters)
        .union(.newlines)
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
    func uniqueFileName(_ fileName: String, usedFileNames: inout Set<String>) -> String {
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
        var usedPaths = Set<String>()
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
    private func uniquePath(of name: String, in folder: String?, usedPaths: inout Set<String>) -> String {
        var folder = folder
        var number = 1
        while true {
            guard let candidate = candidate(name, numbered: number, in: folder) else {
                // No room left in the folders: the top level.
                folder = nil
                number = 1
                continue
            }
            if usedPaths.insert(candidate.lowercased()).inserted {
                return candidate
            }
            number += 1
        }
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
        var trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .windows else {
            return trimmed
        }
        // Windows drops trailing dots and spaces, so "notes.txt." would name "notes.txt".
        while trimmed.hasSuffix(".") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Windows also ignores spaces between a device name and its extension: "CON .txt" is CON.
    private static func isWindowsDeviceName(_ fileName: String) -> Bool {
        let stem = fileName.prefix { $0 != "." }
        return windowsDeviceNames.contains(stem.trimmingCharacters(in: .whitespaces).uppercased())
    }
}
