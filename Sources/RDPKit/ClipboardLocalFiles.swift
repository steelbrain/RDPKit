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
    /// The bytes read at a time, between which a cancelled read stops.
    static let readChunkByteCount = 1_024 * 1_024

    /// Reads the files at `urls`, to publish as a copy of the user's, each under its own name in
    /// no folder: a `\`, which ``RDPClipboardSession/publishLocalFiles(_:)`` takes for a folder
    /// separator and a Mac file name can hold, becomes `_`. Each size is checked against
    /// `maximumTotalByteCount` before the file is read, and a file that grew past it since is
    /// read no more than a byte past. Throws an ``RDPClipboardLocalFileReadError``, or
    /// `CancellationError` once the task it runs in is cancelled, checked before it reads each
    /// file and between the MiB it reads at a time. It blocks while it reads, so call it off the main
    /// thread: a file iCloud has to download first can take minutes.
    public static func read(
        contentsOf urls: [URL],
        maximumTotalByteCount: Int = defaultMaximumTotalByteCount
    ) throws -> [RDPClipboardLocalFile] {
        var files: [RDPClipboardLocalFile] = []
        var totalByteCount = 0
        for url in urls {
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
            let read: Data?
            do {
                let fileHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? fileHandle.close() }
                read = try contents(
                    of: fileHandle,
                    upTo: maximumTotalByteCount - totalByteCount,
                    chunkByteCount: readChunkByteCount
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                throw RDPClipboardLocalFileReadError.unreadable(url)
            }
            // The file can have grown since its size was read.
            guard let contents = read else {
                throw RDPClipboardLocalFileReadError.totalByteLimitExceeded
            }
            totalByteCount += contents.count
            files.append(RDPClipboardLocalFile(fileName: fileName, contents: contents))
        }
        return files
    }

    /// What `fileHandle` holds, read `chunkByteCount` bytes at a time, or nil when it holds more
    /// than `maximumByteCount`, of which it reads no more than a byte past. Throws
    /// `CancellationError` between chunks once the task it runs in is cancelled.
    static func contents(of fileHandle: FileHandle, upTo maximumByteCount: Int, chunkByteCount: Int) throws -> Data? {
        var data = Data()
        // A byte past the limit tells a file that grew past it.
        while data.count <= maximumByteCount {
            try Task.checkCancellation()
            let byteCount = min(chunkByteCount, maximumByteCount + 1 - data.count)
            guard let chunk = try fileHandle.read(upToCount: byteCount), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data.count <= maximumByteCount ? data : nil
    }
}
