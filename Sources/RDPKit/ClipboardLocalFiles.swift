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
    /// The file is larger than the server takes: see ``RDPClipboardSession/maximumFileByteCount``.
    case fileTooLarge(URL)
    /// The server takes no files, as ``RDPClipboardSession/maximumFileByteCount`` says.
    case filesNotSupported

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
        case let .fileTooLarge(url):
            "\(url.lastPathComponent) is larger than the server takes."
        case .filesNotSupported:
            "The server takes no files."
        }
    }
}

/// How far the server has read a file this client published, as it pastes it: the
/// `fileOffset`th of the `fileCount` entries offered, counted from 0 in the order they were
/// published, folders included, and where the range just sent ends, of the file's
/// `fileByteCount` bytes.
public struct RDPClipboardLocalFilePasteProgress: Equatable, Sendable {
    public var fileOffset: Int
    public var fileCount: Int
    /// The name the server got: the published one made valid on Windows.
    public var fileName: String
    public var sentByteCount: UInt64
    public var fileByteCount: UInt64

    public init(fileOffset: Int, fileCount: Int, fileName: String, sentByteCount: UInt64, fileByteCount: UInt64) {
        self.fileOffset = fileOffset
        self.fileCount = fileCount
        self.fileName = fileName
        self.sentByteCount = sentByteCount
        self.fileByteCount = fileByteCount
    }
}

extension RDPClipboardLocalFile {
    /// The most ``read(contentsOf:maximumTotalByteCount:)`` reads by default, as it holds the
    /// files in memory; ``init(fileURL:maximumByteCount:)`` holds none.
    public static let defaultMaximumTotalByteCount = 32 * 1_024 * 1_024
    /// The bytes read at a time, between which a cancelled read stops.
    static let readChunkByteCount = 1_024 * 1_024

    /// The file at `url`, to publish as a copy of the user's under its own name in no folder,
    /// as ``read(contentsOf:maximumTotalByteCount:)`` names it, with no byte of it held in
    /// memory: the session reads each range the server asks for from the file, off its
    /// thread, and fails the request once the file is gone, replaced or shorter than the size
    /// it had here. Throws an ``RDPClipboardLocalFileReadError``:
    /// ``RDPClipboardLocalFileReadError/fileTooLarge(_:)`` for a file larger than
    /// `maximumByteCount`, such as ``RDPClipboardSession/maximumFileByteCount``, before reading
    /// any of it. Otherwise it reads the file's first byte, so call it off the main thread: a
    /// file iCloud has to download first can take minutes, and it is then on the Mac when the
    /// server asks for it.
    public init(fileURL url: URL, maximumByteCount: UInt64 = .max) throws {
        let (fileURL, fileName) = try Self.publishedName(of: url)
        // O_NONBLOCK keeps a FIFO from blocking the open; the file must be regular to be read.
        let descriptor = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RDPClipboardLocalFileReadError.unreadable(url)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw RDPClipboardLocalFileReadError.unreadable(url)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RDPClipboardLocalFileReadError.notARegularFile(url)
        }
        guard UInt64(status.st_size) <= maximumByteCount else {
            throw RDPClipboardLocalFileReadError.fileTooLarge(url)
        }
        var firstByte: UInt8 = 0
        guard status.st_size == 0 || pread(descriptor, &firstByte, 1, 0) == 1 else {
            throw RDPClipboardLocalFileReadError.unreadable(url)
        }
        self.init(
            descriptor: RDPClipboardFileDescriptorW(
                flags: RDPClipboardFileDescriptorFlags.attributes
                    | RDPClipboardFileDescriptorFlags.fileSize
                    | RDPClipboardFileDescriptorFlags.unicode,
                fileAttributes: RDPClipboardFileAttributes.archive,
                fileSize: UInt64(status.st_size),
                fileName: fileName
            ),
            fileReference: RDPClipboardLocalFileReference(url: fileURL, device: status.st_dev, inode: status.st_ino)
        )
    }

    /// `url` standardized, and the name a file there is published under: its last component,
    /// with a `\`, which ``RDPClipboardSession/publishLocalFiles(_:)`` takes for a folder
    /// separator and a Mac file name can hold, made `_`.
    private static func publishedName(of url: URL) throws -> (URL, String) {
        let fileURL = url.standardizedFileURL
        let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "\\", with: "_")
        guard fileURL.isFileURL, !fileName.isEmpty, fileName != "/" else {
            throw RDPClipboardLocalFileReadError.invalidFileName(url)
        }
        return (fileURL, fileName)
    }

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
            let (fileURL, fileName) = try publishedName(of: url)
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

/// A published file on disk: where it is, and which file it was, so a file put in its place
/// since is not read for it.
struct RDPClipboardLocalFileReference: Equatable, Sendable {
    var url: URL
    var device: dev_t
    var inode: ino_t

    /// `byteCount` bytes of the file from `offset`; throws
    /// ``RDPClipboardLocalFileReadError/unreadable(_:)`` when it cannot read them, is not the
    /// file it was, or holds fewer.
    func read(_ byteCount: Int, at offset: UInt64) throws -> Data {
        let unreadable = RDPClipboardLocalFileReadError.unreadable(url)
        guard let start = off_t(exactly: offset) else {
            throw unreadable
        }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw unreadable
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_dev == device, status.st_ino == inode else {
            throw unreadable
        }
        guard byteCount > 0 else {
            return Data()
        }
        var data = Data(count: byteCount)
        var readCount = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            while readCount < byteCount {
                let result = pread(descriptor, base + readCount, byteCount - readCount, start + off_t(readCount))
                if result < 0 {
                    guard errno == EINTR else {
                        throw unreadable
                    }
                    continue
                }
                guard result > 0 else {
                    break
                }
                readCount += result
            }
        }
        // The file is shorter than its published size.
        guard readCount == byteCount else {
            throw unreadable
        }
        return data
    }
}
