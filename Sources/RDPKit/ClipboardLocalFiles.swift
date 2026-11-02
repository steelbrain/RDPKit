import Foundation

public enum RDPClipboardLocalFileReadError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The item at the URL is not a file, such as a folder, or not on this device.
    case notARegularFile(URL)
    /// The URL names no file.
    case invalidFileName(URL)
    /// The file, or its size, could not be read.
    case unreadable(URL)
    /// The files hold more than the limit together.
    case totalByteLimitExceeded

    public var description: String {
        switch self {
        case let .notARegularFile(url):
            "\(url.lastPathComponent) is not a file."
        case let .invalidFileName(url):
            "\(url) names no file."
        case let .unreadable(url):
            "\(url.lastPathComponent) could not be read."
        case .totalByteLimitExceeded:
            "The files exceed the configured byte limit."
        }
    }
}

extension RDPClipboardLocalFile {
    /// The most ``read(contentsOf:maximumTotalByteCount:)`` reads by default: as much as
    /// ``RDPClipboardDownloadLimits`` downloads.
    public static let defaultMaximumTotalByteCount = 32 * 1_024 * 1_024

    /// Reads the files at `urls`, to publish as a copy of the user's, each under its own name in
    /// no folder: a `\`, which ``RDPClipboardSession/publishLocalFiles(_:)`` takes for a folder
    /// separator and a Mac file name can hold, becomes `_`. Each size is checked against
    /// `maximumTotalByteCount` before the file is read, and what was read after. Throws an
    /// ``RDPClipboardLocalFileReadError``, or `CancellationError` once the task it runs in is
    /// cancelled, checked before each file. It blocks while it reads, so call it off the main
    /// thread: a file iCloud has to download first can take minutes.
    public static func read(
        contentsOf urls: [URL],
        maximumTotalByteCount: Int = defaultMaximumTotalByteCount
    ) throws -> [RDPClipboardLocalFile] {
        var files: [RDPClipboardLocalFile] = []
        var totalByteCount = 0
        for url in urls {
            try Task.checkCancellation()
            let fileURL = url.standardizedFileURL
            let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "\\", with: "_")
            guard fileURL.isFileURL, !fileName.isEmpty, fileName != "/" else {
                throw RDPClipboardLocalFileReadError.invalidFileName(url)
            }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw RDPClipboardLocalFileReadError.unreadable(url)
            }
            guard values.isRegularFile == true else {
                throw RDPClipboardLocalFileReadError.notARegularFile(url)
            }
            guard let byteCount = values.fileSize, byteCount >= 0 else {
                throw RDPClipboardLocalFileReadError.unreadable(url)
            }
            guard byteCount <= maximumTotalByteCount - totalByteCount else {
                throw RDPClipboardLocalFileReadError.totalByteLimitExceeded
            }
            let contents: Data
            do {
                contents = try Data(contentsOf: fileURL)
            } catch {
                throw RDPClipboardLocalFileReadError.unreadable(url)
            }
            // The file can have grown since its size was read.
            guard contents.count <= maximumTotalByteCount - totalByteCount else {
                throw RDPClipboardLocalFileReadError.totalByteLimitExceeded
            }
            totalByteCount += contents.count
            files.append(RDPClipboardLocalFile(fileName: fileName, contents: contents))
        }
        return files
    }
}
