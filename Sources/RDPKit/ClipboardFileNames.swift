import Foundation

/// The file names the side a clipboard file is copied to accepts: `apple` for remote files
/// saved on this device, `windows` for local files the server pastes.
enum RDPClipboardFileNameRules {
    /// APFS and HFS+: no "/" or ":", at most 255 UTF-8 bytes.
    case apple
    /// Windows (Naming Files, Paths, and Namespaces): none of `\ / : * ? " < > |` or
    /// U+0000-U+001F, no device name such as CON or NUL.txt, no trailing dot or space, and
    /// at most the 259 UTF-16 code units a file descriptor's cFileName holds.
    case windows

    private static let invalidAppleScalars = CharacterSet(charactersIn: ":")
        .union(.controlCharacters)
        .union(.newlines)
    private static let invalidWindowsScalars = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x00) ... Unicode.Scalar(0x1F)))

    /// Names Windows opens as a device whatever follows the first dot: "nul.tar.gz" is NUL.
    private static let windowsDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for digit in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{B9}", "\u{B2}", "\u{B3}"] {
            names.insert("COM" + digit)
            names.insert("LPT" + digit)
        }
        return names
    }()

    /// `fileName` made valid, and different, ignoring case, from every name in
    /// `usedFileNames`, which it joins. A clash gets "-2", "-3" and so on before the extension.
    func uniqueFileName(_ fileName: String, usedFileNames: inout Set<String>) -> String {
        let sanitized = sanitizedFileName(fileName) as NSString
        let extensionText = sanitized.pathExtension.isEmpty ? "" : ".\(sanitized.pathExtension)"
        var candidate = sanitized as String
        var suffix = 2
        while usedFileNames.contains(candidate.lowercased()) {
            // Check the name as stored: sanitizing again can trim what shortening left.
            candidate = sanitizedFileName(
                joined(sanitized.deletingPathExtension, suffix: "-\(suffix)\(extensionText)")
            )
            suffix += 1
        }
        usedFileNames.insert(candidate.lowercased())
        return candidate
    }

    /// Reduces an untrusted name to a single valid file name component that cannot be "."
    /// or "..". Invalid characters become "_", and a name too long keeps its extension.
    func sanitizedFileName(_ fileName: String) -> String {
        var sanitizedScalars = String.UnicodeScalarView()
        for scalar in component(of: fileName).unicodeScalars {
            sanitizedScalars.append(isInvalid(scalar) ? "_" : scalar)
        }
        var sanitized = fitted(trimmed(String(sanitizedScalars)))
        if self == .windows, Self.isWindowsDeviceName(sanitized) {
            // A leading "_" survives shortening, which could cut a trailing one back to the device name.
            sanitized = fitted("_" + sanitized)
        }
        guard sanitized.isEmpty == false, sanitized != ".", sanitized != ".." else {
            return fallbackFileName
        }
        return sanitized
    }

    private var fallbackFileName: String {
        switch self {
        case .apple:
            "remote-file"
        case .windows:
            "file"
        }
    }

    private var maximumLength: Int {
        switch self {
        case .apple:
            255
        case .windows:
            259
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

    /// A remote name can be a path; a local one is a single component already, so a
    /// separator in it is just an invalid character.
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

    /// `fileName`, or when it is too long, its base name shortened to keep the extension.
    private func fitted(_ fileName: String) -> String {
        guard length(of: fileName) > maximumLength else {
            return fileName
        }
        let name = fileName as NSString
        return trimmed(joined(
            name.deletingPathExtension,
            suffix: name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)"
        ))
    }

    /// Joins `baseName` and `suffix`, shortening the base name to fit the length limit.
    private func joined(_ baseName: String, suffix: String) -> String {
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
