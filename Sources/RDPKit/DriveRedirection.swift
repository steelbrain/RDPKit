import Foundation

// MS-RDPEFS file-system (drive) redirection: shares a local folder as a drive in the remote session.
// The server sends DR_DEVICE_IOREQUEST PDUs (major function + a per-function body); we map each to a
// FileManager operation on the shared folder and reply with a DR_DEVICE_IOCOMPLETION (NTSTATUS + a
// per-function body). Byte layouts follow MS-RDPEFS / MS-FSCC. Local fork addition (see FORK.md).

enum RDPDriveMajorFunction {
    static let create: UInt32 = 0x0000_0000
    static let close: UInt32 = 0x0000_0002
    static let read: UInt32 = 0x0000_0003
    static let write: UInt32 = 0x0000_0004
    static let queryInformation: UInt32 = 0x0000_0005
    static let setInformation: UInt32 = 0x0000_0006
    static let queryVolumeInformation: UInt32 = 0x0000_000A
    static let setVolumeInformation: UInt32 = 0x0000_000B
    static let directoryControl: UInt32 = 0x0000_000C
    static let deviceControl: UInt32 = 0x0000_000E
    static let lockControl: UInt32 = 0x0000_0011
}

enum RDPDriveMinorFunction {
    static let queryDirectory: UInt32 = 0x0000_0001
    static let notifyChangeDirectory: UInt32 = 0x0000_0002
}

enum RDPDriveStatus {
    static let success: UInt32 = 0x0000_0000
    static let noMoreFiles: UInt32 = 0x8000_0006
    static let noSuchFile: UInt32 = 0xC000_000F
    static let unsuccessful: UInt32 = 0xC000_0001
    static let notImplemented: UInt32 = 0xC000_0002
    static let endOfFile: UInt32 = 0xC000_0011
    static let accessDenied: UInt32 = 0xC000_0022
    static let objectNameNotFound: UInt32 = 0xC000_0034
    static let objectNameCollision: UInt32 = 0xC000_0035
    static let objectPathNotFound: UInt32 = 0xC000_003A
    static let notSupported: UInt32 = 0xC000_00BB
    static let directoryNotEmpty: UInt32 = 0xC000_0101
    static let notADirectory: UInt32 = 0xC000_0103
    static let fileIsADirectory: UInt32 = 0xC000_00BA
}

enum RDPDriveFileAttribute {
    static let readonly: UInt32 = 0x0000_0001
    static let hidden: UInt32 = 0x0000_0002
    static let directory: UInt32 = 0x0000_0010
    static let archive: UInt32 = 0x0000_0020
    static let normal: UInt32 = 0x0000_0080
}

private enum RDPDriveCreateDisposition {
    static let supersede: UInt32 = 0
    static let open: UInt32 = 1
    static let create: UInt32 = 2
    static let openIf: UInt32 = 3
    static let overwrite: UInt32 = 4
    static let overwriteIf: UInt32 = 5
}

private enum RDPDriveCreateOptions {
    static let directoryFile: UInt32 = 0x0000_0001
    static let nonDirectoryFile: UInt32 = 0x0000_0040
    static let deleteOnClose: UInt32 = 0x0000_1000
}

private enum RDPDriveCreateInformation {
    static let superseded: UInt8 = 0
    static let opened: UInt8 = 1
    static let created: UInt8 = 2
    static let overwritten: UInt8 = 3
}

private enum RDPDriveFsInformationClass {
    static let fileDirectoryInformation: UInt32 = 1
    static let fileFullDirectoryInformation: UInt32 = 2
    static let fileBothDirectoryInformation: UInt32 = 3
    static let fileBasicInformation: UInt32 = 4
    static let fileStandardInformation: UInt32 = 5
    static let fileNamesInformation: UInt32 = 12
    static let fileRenameInformation: UInt32 = 10
    static let fileDispositionInformation: UInt32 = 13
    static let fileAllocationInformation: UInt32 = 19
    static let fileEndOfFileInformation: UInt32 = 20
    static let fileAttributeTagInformation: UInt32 = 35
}

private enum RDPDriveFsVolumeClass {
    static let volumeInformation: UInt32 = 1
    static let sizeInformation: UInt32 = 3
    static let deviceInformation: UInt32 = 4
    static let attributeInformation: UInt32 = 5
    static let fullSizeInformation: UInt32 = 7
}

/// The parsed common header of a Device I/O Request (MS-RDPEFS 2.2.1.4).
struct RDPDriveIORequest: Sendable {
    var deviceID: UInt32
    var fileID: UInt32
    var completionID: UInt32
    var majorFunction: UInt32
    var minorFunction: UInt32

    static func parse(from cursor: inout ByteCursor) throws -> RDPDriveIORequest {
        try RDPDriveIORequest(
            deviceID: cursor.readLittleEndianUInt32(),
            fileID: cursor.readLittleEndianUInt32(),
            completionID: cursor.readLittleEndianUInt32(),
            majorFunction: cursor.readLittleEndianUInt32(),
            minorFunction: cursor.readLittleEndianUInt32()
        )
    }
}

/// Serves one shared folder as a redirected drive. Not thread-safe on its own; the owning
/// device-redirection session serializes calls (`handle`) on the NIO event loop.
final class RDPDriveShare {
    let rootURL: URL
    let label: String
    private let fileManager = FileManager.default

    /// One name in a directory enumeration. The name is carried separately from the URL because the
    /// `.` and `..` entries report a name that is not their target's last path component.
    private struct DirectoryListingEntry {
        var name: String
        var url: URL
    }

    private struct OpenFile {
        var url: URL
        var isDirectory: Bool
        var deleteOnClose: Bool
        var handle: FileHandle?
        /// Whether `handle` was opened for writing. A read-only handle answers a WRITE with
        /// STATUS_ACCESS_DENIED instead of raising.
        var isWritable: Bool
        var enumeration: [DirectoryListingEntry]?   // directory listing, built on the initial query
        var enumIndex: Int
    }

    private var openFiles: [UInt32: OpenFile] = [:]
    private var nextFileID: UInt32 = 1

    init(path: String, label: String) {
        // Symlinks are resolved here as well as in `resolve(_:)`, and both must agree: on macOS the
        // root itself is often behind one (/tmp -> /private/tmp, /var -> /private/var), so comparing
        // a resolved child against an unresolved root would reject perfectly legitimate paths.
        rootURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.label = label.isEmpty ? "Shared" : label
    }

    /// Whether the shared folder still exists and is a directory.
    ///
    /// A share whose folder has been deleted or renamed since it was configured is worse than no
    /// share at all: the device is announced, the server accepts it, `\\tsclient\<label>` appears -
    /// and then every single I/O request, including the open of the share root itself, is answered
    /// STATUS_OBJECT_NAME_NOT_FOUND. The user sees a share that exists but cannot be opened, with
    /// nothing to indicate which end is at fault.
    var rootExists: Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Handle one request; returns the IoStatus + the per-function completion body (after IoStatus),
    /// or `nil` when the request must be left pending and not answered at all.
    func handle(_ request: RDPDriveIORequest, body: inout ByteCursor) -> (status: UInt32, payload: Data)? {
        switch request.majorFunction {
        case RDPDriveMajorFunction.create: return create(&body)
        case RDPDriveMajorFunction.close: return close(request.fileID)
        case RDPDriveMajorFunction.read: return read(request.fileID, &body)
        case RDPDriveMajorFunction.write: return write(request.fileID, &body)
        case RDPDriveMajorFunction.queryInformation: return queryInformation(request.fileID, &body)
        case RDPDriveMajorFunction.setInformation: return setInformation(request.fileID, &body)
        case RDPDriveMajorFunction.queryVolumeInformation: return queryVolume(&body)
        case RDPDriveMajorFunction.directoryControl:
            switch request.minorFunction {
            case RDPDriveMinorFunction.queryDirectory:
                return queryDirectory(request.fileID, &body)
            case RDPDriveMinorFunction.notifyChangeDirectory:
                // A change-notification IRP is meant to stay outstanding until the directory
                // actually changes; it is not a request that gets answered now. Completing it -
                // with any status, success or error - tells Windows the directory handle is
                // finished, and Explorer abandons the listing before it ever sends a single
                // QUERY_DIRECTORY. Leaving it pending is what a working client does, and costs
                // nothing: there is no live refresh to deliver, so the IRP simply never completes.
                return nil
            default:
                return (RDPDriveStatus.notSupported, lengthPrefixed(Data()))
            }
        case RDPDriveMajorFunction.lockControl:
            // DR_DRIVE_LOCK_CONTROL_RSP is DeviceIoReply followed by 5 bytes of padding.
            return (RDPDriveStatus.success, Data(repeating: 0, count: 5))
        default: return (RDPDriveStatus.notImplemented, lengthPrefixed(Data()))
        }
    }

    /// Close all handles (on channel teardown).
    func reset() {
        for file in openFiles.values { try? file.handle?.close() }
        openFiles.removeAll()
    }

    // MARK: - Path mapping

    /// Map a remote (backslash) path under the share to a local URL, rejecting escapes ("..").
    private func resolve(_ remotePath: String) -> URL? {
        let components = remotePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        guard components.contains("..") == false, components.contains(".") == false else { return nil }
        var url = rootURL
        for component in components { url.appendPathComponent(component) }
        // `standardizedFileURL` only normalises the path lexically - it does not follow symbolic
        // links, and FileHandle/FileManager do. Without `resolvingSymlinksInPath()` a link placed
        // inside the shared folder (deliberately, or simply because the user shared a directory that
        // already contains one) lets the remote read and write anywhere that link points.
        url = url.standardizedFileURL.resolvingSymlinksInPath()
        // Must remain within the share root.
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path == rootURL.path || url.path.hasPrefix(rootPath) else { return nil }
        return url
    }

    /// Test seam: the path guard is the security boundary of a redirected drive, and every input to
    /// it comes from the remote, so it is exercised directly rather than through an I/O request.
    func resolveForTesting(_ remotePath: String) -> URL? { resolve(remotePath) }

    // MARK: - CREATE

    private func create(_ body: inout ByteCursor) -> (UInt32, Data) {
        guard
            let _ = try? body.readLittleEndianUInt32(),          // DesiredAccess
            let _ = try? body.readLittleEndianUInt64(),          // AllocationSize
            let _ = try? body.readLittleEndianUInt32(),          // FileAttributes
            let _ = try? body.readLittleEndianUInt32(),          // SharedAccess
            let disposition = try? body.readLittleEndianUInt32(),
            let options = try? body.readLittleEndianUInt32(),
            let pathLength = try? body.readLittleEndianUInt32(),
            let pathData = try? body.readData(count: Int(pathLength))
        else { return (RDPDriveStatus.unsuccessful, createBody(fileID: 0, information: 0)) }

        let remotePath = decodeUTF16(pathData)
        guard let url = resolve(remotePath) else {
            return (RDPDriveStatus.accessDenied, createBody(fileID: 0, information: 0))
        }

        let existed = fileManager.fileExists(atPath: url.path)
        var isDir = existsDirectory(url)
        let wantsDirectory = options & RDPDriveCreateOptions.directoryFile != 0
        let wantsFile = options & RDPDriveCreateOptions.nonDirectoryFile != 0

        // Honour the caller's assertion about what it is opening. Explorer decides whether an item
        // is a folder by opening it with FILE_DIRECTORY_FILE and seeing whether that succeeds:
        // answering STATUS_SUCCESS for a regular file makes it treat the file as a folder, which
        // shows up as a document with "0 bytes, 0 files, 0 folders" in its properties and an
        // IRP_MN_QUERY_DIRECTORY we can only fail. These are the NT semantics the probe relies on.
        if existed {
            if wantsDirectory, isDir == false {
                return (RDPDriveStatus.notADirectory, createBody(fileID: 0, information: 0))
            }
            if wantsFile, isDir {
                return (RDPDriveStatus.fileIsADirectory, createBody(fileID: 0, information: 0))
            }
        }

        switch disposition {
        case RDPDriveCreateDisposition.open:
            guard existed else { return (RDPDriveStatus.objectNameNotFound, createBody(fileID: 0, information: 0)) }
        case RDPDriveCreateDisposition.create:
            guard existed == false else { return (RDPDriveStatus.objectNameCollision, createBody(fileID: 0, information: 0)) }
            guard makeItem(at: url, directory: wantsDirectory) else { return (RDPDriveStatus.unsuccessful, createBody(fileID: 0, information: 0)) }
            isDir = wantsDirectory
        case RDPDriveCreateDisposition.openIf:
            if existed == false {
                guard makeItem(at: url, directory: wantsDirectory) else { return (RDPDriveStatus.unsuccessful, createBody(fileID: 0, information: 0)) }
                isDir = wantsDirectory
            }
        case RDPDriveCreateDisposition.overwrite:
            guard existed, isDir == false else { return (RDPDriveStatus.objectNameNotFound, createBody(fileID: 0, information: 0)) }
            fileManager.createFile(atPath: url.path, contents: Data())
        case RDPDriveCreateDisposition.overwriteIf, RDPDriveCreateDisposition.supersede:
            if isDir == false { fileManager.createFile(atPath: url.path, contents: Data()) }
        default:
            return (RDPDriveStatus.unsuccessful, createBody(fileID: 0, information: 0))
        }

        var handle: FileHandle?
        var writable = false
        if isDir == false {
            handle = try? FileHandle(forUpdating: url)
            writable = handle != nil
            // A read-only file still opens, so it can be read - but the handle is remembered as
            // read-only, and a WRITE against it is refused rather than attempted. Attempting it
            // raises an Objective-C exception from the legacy FileHandle API, which no Swift `catch`
            // can intercept: the process aborts, so a remote server could kill the app outright.
            if handle == nil { handle = try? FileHandle(forReadingFrom: url) }
        }
        let fileID = allocateFileID()
        openFiles[fileID] = OpenFile(
            url: url, isDirectory: isDir,
            deleteOnClose: options & RDPDriveCreateOptions.deleteOnClose != 0,
            handle: handle, isWritable: writable, enumeration: nil, enumIndex: 0
        )
        let information: UInt8 = existed ? RDPDriveCreateInformation.opened : RDPDriveCreateInformation.created
        return (RDPDriveStatus.success, createBody(fileID: fileID, information: information))
    }

    private func createBody(fileID: UInt32, information: UInt8) -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(fileID)
        data.appendUInt8(information)
        return data
    }

    // MARK: - CLOSE

    private func close(_ fileID: UInt32) -> (UInt32, Data) {
        if let file = openFiles.removeValue(forKey: fileID) {
            try? file.handle?.close()
            if file.deleteOnClose { deleteOnClose(file) }
        }
        return (RDPDriveStatus.success, Data(count: 5))   // Padding (5 bytes)
    }

    /// Delete an item whose handle carried FILE_DELETE_ON_CLOSE, with rmdir(2) semantics.
    ///
    /// `removeItem` is recursive, which is not what a delete-on-close means: a directory is deleted
    /// only if it is empty, and the share root is never deleted at all. Without both guards a single
    /// CREATE with an empty path and the delete-on-close flag destroys the whole shared folder.
    private func deleteOnClose(_ file: OpenFile) {
        guard file.url.path != rootURL.path else { return }
        if file.isDirectory, directoryIsEmpty(file.url) == false { return }
        try? fileManager.removeItem(at: file.url)
    }

    /// Whether two paths name the same item. Path text is not enough: macOS volumes are usually
    /// case-insensitive, so "a.txt" and "A.txt" are one file with two spellings.
    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        guard let left = try? lhs.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return lhs.standardizedFileURL == rhs.standardizedFileURL }
        return left.isEqual(right)
    }

    private func directoryIsEmpty(_ url: URL) -> Bool {
        let children = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []
        )
        return (children ?? []).isEmpty
    }

    // MARK: - READ / WRITE

    /// Largest single read this client will service, regardless of what the server asks for.
    ///
    /// `Length` in DR_DRIVE_READ_REQ is chosen entirely by the remote and may be up to 4 GiB. It is
    /// the one field that sizes an allocation from a local file rather than from the bytes actually
    /// received, so without a ceiling a hostile - or merely confused - server can make the client
    /// allocate far more than it sent. Windows reads a redirected drive in 64 KiB requests, and
    /// answering with fewer bytes than were asked for is legal: the reply carries its own Length and
    /// the server simply issues another read. 8 MiB leaves two orders of magnitude of headroom over
    /// anything observed while keeping a single request bounded.
    static let maximumReadByteCount = 8 * 1_024 * 1_024

    private func read(_ fileID: UInt32, _ body: inout ByteCursor) -> (UInt32, Data) {
        guard let length = try? body.readLittleEndianUInt32(),
              let offset = try? body.readLittleEndianUInt64(),
              let file = openFiles[fileID], let handle = file.handle
        else { return (RDPDriveStatus.unsuccessful, lengthPrefixed(Data())) }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: min(Int(length), Self.maximumReadByteCount)) ?? Data()
            var payload = Data()
            payload.appendLittleEndianUInt32(UInt32(data.count))
            payload.append(data)
            return (RDPDriveStatus.success, payload)
        } catch {
            return (RDPDriveStatus.unsuccessful, lengthPrefixed(Data()))
        }
    }

    private func write(_ fileID: UInt32, _ body: inout ByteCursor) -> (UInt32, Data) {
        guard let length = try? body.readLittleEndianUInt32(),
              let offset = try? body.readLittleEndianUInt64(),
              let _ = try? body.readData(count: 20),                 // Padding
              let data = try? body.readData(count: Int(length)),
              let file = openFiles[fileID], let handle = file.handle
        else { return writeFailure() }
        // Refuse rather than attempt: writing through a read-only handle raises an Objective-C
        // exception that no Swift `catch` can intercept, and the process aborts.
        guard file.isWritable else {
            return (RDPDriveStatus.accessDenied, writeBody(written: 0))
        }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            return (RDPDriveStatus.success, writeBody(written: data.count))
        } catch {
            return writeFailure()
        }
    }

    /// DR_DRIVE_WRITE_RSP: Length plus one padding byte, required on every reply including a
    /// failure - a body-less completion leaves the server parsing Length off the end of the PDU.
    private func writeBody(written: Int) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(UInt32(written))
        payload.appendUInt8(0)
        return payload
    }

    private func writeFailure() -> (UInt32, Data) {
        (RDPDriveStatus.unsuccessful, writeBody(written: 0))
    }

    // MARK: - QUERY / SET INFORMATION

    private func queryInformation(_ fileID: UInt32, _ body: inout ByteCursor) -> (UInt32, Data) {
        guard let infoClass = try? body.readLittleEndianUInt32(),
              let file = openFiles[fileID]
        else { return (RDPDriveStatus.unsuccessful, lengthPrefixed(Data())) }
        let attributes = try? fileManager.attributesOfItem(atPath: file.url.path)
        let size = (attributes?[.size] as? UInt64) ?? 0
        let created = attributes?[.creationDate] as? Date
        let modified = attributes?[.modificationDate] as? Date

        var buffer = Data()
        switch infoClass {
        case RDPDriveFsInformationClass.fileBasicInformation:
            buffer.appendLittleEndianUInt64(fileTime(created))
            buffer.appendLittleEndianUInt64(fileTime(modified))
            buffer.appendLittleEndianUInt64(fileTime(modified))
            buffer.appendLittleEndianUInt64(fileTime(modified))
            buffer.appendLittleEndianUInt32(fileAttributes(file.url, isDirectory: file.isDirectory))
            // No trailing Reserved: MS-RDPEFS 2.2.3.3.8 sends FILE_BASIC_INFORMATION without the
            // NT struct's padding, so the buffer is 36 bytes. FreeRDP encodes the same 36.
        case RDPDriveFsInformationClass.fileStandardInformation:
            // Report zero length for a directory: macOS gives a directory inode a real byte size
            // (e.g. 1088), and NTFS reports zero. Matching NTFS is the conservative choice, though
            // it is not known to be required - FreeRDP passes st_size through here and works.
            let reportedSize = file.isDirectory ? 0 : size
            buffer.appendLittleEndianUInt64(reportedSize)           // AllocationSize
            buffer.appendLittleEndianUInt64(reportedSize)           // EndOfFile
            buffer.appendLittleEndianUInt32(1)                      // NumberOfLinks
            buffer.appendUInt8(0)                                   // DeletePending
            buffer.appendUInt8(file.isDirectory ? 1 : 0)           // Directory
            // No trailing Reserved: 2.2.3.3.8 sends 22 bytes, not sizeof(FILE_STANDARD_INFORMATION).
        case RDPDriveFsInformationClass.fileAttributeTagInformation:
            buffer.appendLittleEndianUInt32(fileAttributes(file.url, isDirectory: file.isDirectory))
            buffer.appendLittleEndianUInt32(0)                     // ReparseTag
        default:
            return (RDPDriveStatus.notSupported, lengthPrefixed(Data()))
        }
        return (RDPDriveStatus.success, lengthPrefixed(buffer))
    }

    private func setInformation(_ fileID: UInt32, _ body: inout ByteCursor) -> (UInt32, Data) {
        guard let infoClass = try? body.readLittleEndianUInt32(),
              let length = try? body.readLittleEndianUInt32(),
              let _ = try? body.readData(count: 24),                 // Padding
              let payload = try? body.readData(count: Int(length)),
              let file = openFiles[fileID] else { return (RDPDriveStatus.unsuccessful, Data()) }

        switch infoClass {
        case RDPDriveFsInformationClass.fileDispositionInformation:
            // Any non-empty request marks delete-on-close (DeletePending flag).
            let pending = payload.first.map { $0 != 0 } ?? true
            if pending {
                // NTFS refuses here rather than at close, and so must this: RemoveDirectory over a
                // redirected drive is a disposition set, and answering success for a directory with
                // contents is what turns `rmdir` into a recursive delete of the user's files.
                if file.url.path == rootURL.path {
                    return (RDPDriveStatus.accessDenied, echoedLength(length))
                }
                if file.isDirectory, directoryIsEmpty(file.url) == false {
                    return (RDPDriveStatus.directoryNotEmpty, echoedLength(length))
                }
            }
            openFiles[fileID]?.deleteOnClose = pending
        case RDPDriveFsInformationClass.fileEndOfFileInformation,
             RDPDriveFsInformationClass.fileAllocationInformation:
            var cursor = ByteCursor(payload)
            if let newSize = try? cursor.readLittleEndianUInt64() {
                try? file.handle?.truncate(atOffset: newSize)
            }
        case RDPDriveFsInformationClass.fileRenameInformation:
            guard rename(file: file, fileID: fileID, request: payload) else { return (RDPDriveStatus.unsuccessful, echoedLength(length)) }
        case RDPDriveFsInformationClass.fileBasicInformation:
            break   // times/attributes: accept but don't apply
        default:
            return (RDPDriveStatus.notSupported, echoedLength(length))
        }
        return (RDPDriveStatus.success, echoedLength(length))
    }

    /// DR_DRIVE_SET_INFORMATION_RSP carries the *request's* Length, not the response body's
    /// (MS-RDPEFS 2.2.3.4.9: "MUST be equal to the Length field in the Server Drive Set Information
    /// Request"). Answering 0 makes Windows treat the set as having done nothing, so renaming a
    /// newly created file or folder silently fails.
    private func echoedLength(_ length: UInt32) -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(length)
        return data
    }

    private func rename(file: OpenFile, fileID: UInt32, request: Data) -> Bool {
        var cursor = ByteCursor(request)
        // RDP_FILE_RENAME_INFORMATION (MS-RDPEFS 2.2.3.3.9): ReplaceIfExists(1), RootDirectory(1),
        // FileNameLength(4), FileName[]. RootDirectory is ONE byte here - the NT
        // FILE_RENAME_INFORMATION's 8-byte HANDLE is not what goes on the wire. Skipping 8 reads
        // FileNameLength from the wrong offset, so every rename fails; Explorer creates a folder as
        // "New folder" and then renames it, which made creating one look impossible.
        guard let replace = try? cursor.readUInt8(),
              let _ = try? cursor.readUInt8(),
              let nameLength = try? cursor.readLittleEndianUInt32(),
              let nameData = try? cursor.readData(count: Int(nameLength)),
              let target = resolve(decodeUTF16(nameData)) else { return false }
        // A case-only rename on a case-insensitive volume names the SAME file, so `fileExists` is
        // true and removing "the existing target" unlinks the very file about to be moved. Compare
        // identity, not path text, and move straight through when they are the same item.
        let isSameItem = fileManager.fileExists(atPath: target.path) && sameFile(file.url, target)
        if fileManager.fileExists(atPath: target.path), isSameItem == false {
            guard replace != 0 else { return false }
            // Move the existing target aside rather than deleting it: if the rename then fails, the
            // destination still exists. Deleting first makes every failure destructive.
            let backup = target.appendingPathExtension("rdpkit-replacing")
            try? fileManager.removeItem(at: backup)
            guard (try? fileManager.moveItem(at: target, to: backup)) != nil else { return false }
            do {
                try fileManager.moveItem(at: file.url, to: target)
                try? fileManager.removeItem(at: backup)
                openFiles[fileID]?.url = target
                return true
            } catch {
                try? fileManager.moveItem(at: backup, to: target)   // put it back
                return false
            }
        }
        do {
            try fileManager.moveItem(at: file.url, to: target)
            openFiles[fileID]?.url = target
            return true
        } catch {
            return false
        }
    }

    // MARK: - QUERY VOLUME INFORMATION

    private func queryVolume(_ body: inout ByteCursor) -> (UInt32, Data) {
        guard let infoClass = try? body.readLittleEndianUInt32() else {
            return (RDPDriveStatus.unsuccessful, lengthPrefixed(Data()))
        }
        var buffer = Data()
        switch infoClass {
        case RDPDriveFsVolumeClass.volumeInformation:
            let name = utf16LE(label)
            buffer.appendLittleEndianUInt64(0)                     // VolumeCreationTime
            buffer.appendLittleEndianUInt32(0x1234_5678)          // VolumeSerialNumber
            buffer.appendLittleEndianUInt32(UInt32(name.count))   // VolumeLabelLength
            buffer.appendUInt8(0)                                  // SupportsObjects
            buffer.appendUInt8(0)                                  // Reserved
            buffer.append(name)
        case RDPDriveFsVolumeClass.sizeInformation:
            let (total, available) = volumeCapacity()
            buffer.appendLittleEndianUInt64(total)                // TotalAllocationUnits
            buffer.appendLittleEndianUInt64(available)            // AvailableAllocationUnits
            buffer.appendLittleEndianUInt32(1)                    // SectorsPerAllocationUnit
            buffer.appendLittleEndianUInt32(512)                  // BytesPerSector
        case RDPDriveFsVolumeClass.fullSizeInformation:
            let (total, available) = volumeCapacity()
            buffer.appendLittleEndianUInt64(total)                // TotalAllocationUnits
            buffer.appendLittleEndianUInt64(available)            // CallerAvailableAllocationUnits
            buffer.appendLittleEndianUInt64(available)            // ActualAvailableAllocationUnits
            buffer.appendLittleEndianUInt32(1)                    // SectorsPerAllocationUnit
            buffer.appendLittleEndianUInt32(512)                  // BytesPerSector
        case RDPDriveFsVolumeClass.deviceInformation:
            buffer.appendLittleEndianUInt32(0x0000_0007)          // FILE_DEVICE_DISK
            buffer.appendLittleEndianUInt32(0)                    // Characteristics
        case RDPDriveFsVolumeClass.attributeInformation:
            let name = utf16LE("RDPKitFS")
            buffer.appendLittleEndianUInt32(0x0000_0002)          // FILE_CASE_PRESERVED_NAMES
            buffer.appendLittleEndianUInt32(255)                  // MaximumComponentNameLength
            buffer.appendLittleEndianUInt32(UInt32(name.count))   // FileSystemNameLength
            buffer.append(name)
        default:
            return (RDPDriveStatus.notSupported, lengthPrefixed(Data()))
        }
        return (RDPDriveStatus.success, lengthPrefixed(buffer))
    }

    private func volumeCapacity() -> (total: UInt64, available: UInt64) {
        let values = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let bytesPerUnit: UInt64 = 512
        let total = UInt64(values?.volumeTotalCapacity ?? 0) / bytesPerUnit
        let available = UInt64(values?.volumeAvailableCapacity ?? 0) / bytesPerUnit
        return (max(total, 1), available)
    }

    // MARK: - DIRECTORY_CONTROL / QUERY_DIRECTORY

    private func queryDirectory(_ fileID: UInt32, _ body: inout ByteCursor) -> (UInt32, Data) {
        guard let infoClass = try? body.readLittleEndianUInt32(),
              let initialQuery = try? body.readUInt8(),
              let pathLength = try? body.readLittleEndianUInt32(),
              let _ = try? body.readData(count: 23),                 // Padding
              let pathData = try? body.readData(count: Int(pathLength)),
              var file = openFiles[fileID], file.isDirectory
        else { return (RDPDriveStatus.unsuccessful, lengthPrefixed(Data()) + Data(count: 1)) }
        // The search pattern selects which names this enumeration returns. Discarding it is not a
        // harmless simplification: Windows serves a by-name attribute lookup by enumerating the
        // parent with the file's own name as the pattern, so answering with the whole listing hands
        // it entry zero - "." - and it concludes the file is a directory of zero bytes. That is what
        // put a folder property sheet on a .docx. The wildcard case hid it, since returning
        // everything for "*" is the right answer.
        // The Path is share-root-relative and may carry a directory prefix; the handle already
        // identifies the directory, so only the last component is the pattern. It is NOT routed
        // through resolve(), which rejects a component equal to "." - a legal single-name pattern.
        let requestedPath = decodeUTF16(pathData)
        let pattern = requestedPath.split(separator: "\\").last.map(String.init) ?? ""

        if initialQuery != 0 || file.enumeration == nil {
            let children = (try? fileManager.contentsOfDirectory(
                at: file.url, includingPropertiesForKeys: nil, options: []
            )) ?? []
            // `.` and `..` must lead the enumeration. `contentsOfDirectory` omits them, but every
            // filesystem Windows knows reports them, and its redirector needs them to establish the
            // directory node: hand it a listing that starts at the first real file and Explorer
            // abandons the enumeration and tears the redirection down. `..` on the share root is
            // clamped to the root itself rather than escaping the share.
            let parent = file.url.path == rootURL.path
                ? file.url
                : file.url.deletingLastPathComponent()
            let candidates = [
                DirectoryListingEntry(name: ".", url: file.url),
                DirectoryListingEntry(name: "..", url: parent),
            ] + children
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { DirectoryListingEntry(name: $0.lastPathComponent, url: $0) }
            // Filtering the whole candidate list, "." and ".." included, needs no special cases:
            // "*" keeps them, a literal name drops them.
            file.enumeration = candidates.filter { matchesSearchPattern($0.name, pattern: pattern) }
            file.enumIndex = 0
        }
        guard let entries = file.enumeration, file.enumIndex < entries.count else {
            openFiles[fileID] = file
            // MS-RDPEFS 2.2.3.4.10: a first query that matches nothing is STATUS_NO_SUCH_FILE;
            // running off the end of a continuation is STATUS_NO_MORE_FILES.
            let status = initialQuery != 0 && (file.enumeration?.isEmpty ?? true)
                ? RDPDriveStatus.noSuchFile
                : RDPDriveStatus.noMoreFiles
            return (status, lengthPrefixed(Data()) + Data(count: 1))
        }

        // One entry per response keeps the encoding simple and avoids NextEntryOffset alignment bugs.
        let listed = entries[file.enumIndex]
        file.enumIndex += 1
        openFiles[fileID] = file
        let entry = directoryEntry(name: listed.name, url: listed.url, infoClass: infoClass)
        return (RDPDriveStatus.success, lengthPrefixed(entry))
    }

    /// Match one name against a Windows directory search pattern (`*` and `?`).
    ///
    /// Comparison is case-insensitive and canonically precomposed: macOS stores decomposed Unicode,
    /// so a literal pattern for an accented name would otherwise never match its own file.
    private func matchesSearchPattern(_ name: String, pattern: String) -> Bool {
        // "*.*" is the DOS spelling of "everything", including names with no dot at all.
        if pattern.isEmpty || pattern == "*" || pattern == "*.*" { return true }
        let subject = Array(name.precomposedStringWithCanonicalMapping.lowercased())
        let glob = Array(pattern.precomposedStringWithCanonicalMapping.lowercased())

        var subjectIndex = 0, globIndex = 0
        var starIndex = -1, resumeIndex = 0
        while subjectIndex < subject.count {
            if globIndex < glob.count,
               glob[globIndex] == "?" || glob[globIndex] == subject[subjectIndex] {
                subjectIndex += 1
                globIndex += 1
            } else if globIndex < glob.count, glob[globIndex] == "*" {
                starIndex = globIndex
                globIndex += 1
                resumeIndex = subjectIndex
            } else if starIndex >= 0 {
                globIndex = starIndex + 1
                resumeIndex += 1
                subjectIndex = resumeIndex
            } else {
                return false
            }
        }
        while globIndex < glob.count, glob[globIndex] == "*" { globIndex += 1 }
        return globIndex == glob.count
    }

    private func directoryEntry(name reportedName: String, url: URL, infoClass: UInt32) -> Data {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let isDir = (attributes?[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes?[.size] as? UInt64) ?? 0
        let created = attributes?[.creationDate] as? Date
        let modified = attributes?[.modificationDate] as? Date
        let name = utf16LE(reportedName)   // no null terminator in directory entries
        // Attributes come from the target, not the reported name: `.` and `..` are ordinary
        // directories and must not pick up the hidden bit their leading dot would imply.
        let attrs = fileAttributes(url, isDirectory: isDir)

        var data = Data()
        data.appendLittleEndianUInt32(0)                           // NextEntryOffset (single entry)
        data.appendLittleEndianUInt32(0)                           // FileIndex
        if infoClass == RDPDriveFsInformationClass.fileNamesInformation {
            data.appendLittleEndianUInt32(UInt32(name.count))     // FileNameLength
            data.append(name)
            return data
        }
        data.appendLittleEndianUInt64(fileTime(created))
        data.appendLittleEndianUInt64(fileTime(modified))
        data.appendLittleEndianUInt64(fileTime(modified))
        data.appendLittleEndianUInt64(fileTime(modified))
        let reportedSize = isDir ? 0 : size
        data.appendLittleEndianUInt64(reportedSize)               // EndOfFile
        data.appendLittleEndianUInt64(reportedSize)               // AllocationSize
        data.appendLittleEndianUInt32(attrs)
        data.appendLittleEndianUInt32(UInt32(name.count))         // FileNameLength
        if infoClass == RDPDriveFsInformationClass.fileFullDirectoryInformation
            || infoClass == RDPDriveFsInformationClass.fileBothDirectoryInformation {
            data.appendLittleEndianUInt32(0)                      // EaSize
        }
        if infoClass == RDPDriveFsInformationClass.fileBothDirectoryInformation {
            data.appendUInt8(0)                                   // ShortNameLength
            // No Reserved byte here. MS-FSCC's FILE_BOTH_DIR_INFORMATION has one after
            // ShortNameLength, but MS-RDPEFS 2.2.3.4.10 puts 93 bytes on the wire, not the struct's
            // 94: sending it shifts ShortName and FileName one byte late, Windows reads a garbage
            // name, and Explorer abandons the enumeration. FreeRDP marks the same spot
            // "Reserved(1), MUST NOT be added!".
            data.append(Data(count: 24))                          // ShortName[12] UTF-16
        }
        data.append(name)
        return data
    }

    // MARK: - Helpers

    private func allocateFileID() -> UInt32 {
        let id = nextFileID
        nextFileID = nextFileID == UInt32.max ? 1 : nextFileID + 1
        return id
    }

    private func existsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func makeItem(at url: URL, directory: Bool) -> Bool {
        if directory {
            return (try? fileManager.createDirectory(at: url, withIntermediateDirectories: false)) != nil
        }
        return fileManager.createFile(atPath: url.path, contents: Data())
    }

    private func fileAttributes(_ url: URL, isDirectory: Bool) -> UInt32 {
        var attrs: UInt32 = 0
        if isDirectory { attrs |= RDPDriveFileAttribute.directory }
        if url.lastPathComponent.hasPrefix(".") { attrs |= RDPDriveFileAttribute.hidden }
        if fileManager.isWritableFile(atPath: url.path) == false { attrs |= RDPDriveFileAttribute.readonly }
        if isDirectory == false, attrs == 0 { attrs = RDPDriveFileAttribute.archive }
        return attrs
    }

    private func lengthPrefixed(_ buffer: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(UInt32(buffer.count))
        data.append(buffer)
        return data
    }

    private func fileTime(_ date: Date?) -> UInt64 {
        guard let date else { return 0 }
        let secondsSince1601 = date.timeIntervalSince1970 + 11_644_473_600
        guard secondsSince1601 > 0 else { return 0 }
        return UInt64(secondsSince1601 * 10_000_000)
    }

    private func utf16LE(_ value: String) -> Data {
        var data = Data()
        for unit in value.utf16 { data.appendLittleEndianUInt16(unit) }
        return data
    }

    private func decodeUTF16(_ data: Data) -> String {
        var cursor = ByteCursor(data)
        var units: [UInt16] = []
        while let unit = try? cursor.readLittleEndianUInt16(), unit != 0 { units.append(unit) }
        return String(decoding: units, as: UTF16.self)
    }
}
