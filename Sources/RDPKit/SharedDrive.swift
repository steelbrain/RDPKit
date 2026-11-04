import Darwin
import Foundation

/// A failed drive operation and the NTSTATUS it answers with.
struct RDPDriveFailure: Error, Equatable {
    var status: UInt32

    static let invalidHandle = RDPDriveFailure(status: 0xC000_0008)

    /// The NTSTATUS for a POSIX error, as Windows reports the same failure.
    static func posix(_ code: Int32 = errno) -> RDPDriveFailure {
        let status = switch code {
        case ENOENT: RDPNTStatus.objectNameNotFound
        case EEXIST: RDPNTStatus.objectNameCollision
        case EACCES, EPERM, EBADF, EBUSY: RDPNTStatus.accessDenied
        case ENOTDIR: RDPNTStatus.objectPathNotFound
        case EISDIR: RDPNTStatus.fileIsADirectory
        case ENOTEMPTY: RDPNTStatus.directoryNotEmpty
        case ENOSPC, EDQUOT: RDPNTStatus.diskFull
        case EROFS: RDPNTStatus.mediaWriteProtected
        case ENAMETOOLONG, EILSEQ: RDPNTStatus.objectNameInvalid
        case EMFILE, ENFILE: RDPNTStatus.tooManyOpenedFiles
        default: RDPNTStatus.unsuccessful
        }
        return RDPDriveFailure(status: status)
    }
}

/// One shared folder serving the server's I/O requests ([MS-RDPEFS] 3.2.5.2).
///
/// Every path stays inside the folder: a request names a path relative to it,
/// `.`, `..` and characters Windows never sends are refused, the parent of
/// each entry is resolved with `realpath` and must be inside the folder, and a
/// symbolic link is followed only to a target inside it. A handle's paths are
/// checked again before each use, so a rename that moves a link into their place
/// cannot take them outside. Only regular files and directories are served. Only
/// the device redirection session's I/O queue uses a device.
///
/// A change notification waits until a change in the directory, or under it when the
/// server watches the tree, is reported. It completes with STATUS_NOTIFY_ENUM_DIR and no
/// entries, which has the server list the directory again, as an SMB2 server answers a
/// notification whose changes do not fit ([MS-FSA] 2.1.5.11.1). On macOS and Mac Catalyst
/// one FSEvents stream per drive reports changes while a handle watches. Elsewhere a kqueue
/// watch on each watched directory reports entries added, removed or renamed in it, but not
/// writes to its files, nor changes in its subdirectories to a handle that watches the
/// tree. A directory that cannot be watched, as when the watches' descriptors run out, is
/// watched once one of the drive's watches stops.
final class RDPSharedDriveDevice: @unchecked Sendable {
    /// A larger read is answered with fewer bytes, which [MS-RDPEFS] 2.2.1.5.3 allows;
    /// the server sizes reads, and this bounds what one request makes the client hold.
    static let maximumReadByteCount = 16 * 1024 * 1024
    static let maximumOpenFileCount = 4096
    /// No file name is longer ([MS-FSCC] 2.1.5.2), so neither is a search pattern that names one.
    static let maximumSearchPatternLength = 255
    /// What the directory listings of a drive's handles may hold together, counted as
    /// `listingByteCount(of:)` does. A handle keeps the listing of its directory query until
    /// the query ends, so without a bound a server could make the client hold a copy of a
    /// large directory for each of the handles it may open.
    static let maximumListingByteCount = 64 * 1024 * 1024
    /// The change notifications a drive's handles may have waiting together: a server holds
    /// one for each handle it watches, and each that waits costs the client memory.
    static let maximumWaitingNotificationCount = 4096
    /// Length 0 and the optional Padding: a change notification's reply, which says nothing
    /// of what changed ([MS-RDPEFS] 2.2.3.4.11).
    static let notificationReplyBody = Data(count: 5)

    let deviceID: UInt32
    let drive: RDPSharedDrive
    /// The shared folder with symbolic links resolved, nil while it does not exist.
    private(set) var rootPath: String?
    private var openFiles: [UInt32: RDPSharedDriveOpenFile] = [:]
    private var nextFileID: UInt32 = 1
    private let descriptorBudget: RDPSharedDriveDescriptorBudget
    private let listingByteLimit: Int
    /// What the listings of `openFiles` hold, in `listingByteCount(of:)` bytes.
    private var listingByteCount = 0
    /// The queue the device is used on, where changes are reported.
    private let queue: DispatchQueue
    private let changeSource: RDPSharedDriveChangeSource
    private let watchDescriptorBudget: RDPSharedDriveDescriptorBudget
    /// The change notifications waiting on `openFiles`.
    private var waitingNotificationCount = 0
    /// With `.directoryWatches`, one for each directory a handle watches, by its identity.
    private var directoryWatches: [RDPFileIdentity: RDPSharedDriveDirectoryWatch] = [:]
    #if os(macOS) || targetEnvironment(macCatalyst)
    /// With `.fsEvents`, runs while a handle watches.
    private var changeStream: RDPSharedDriveChangeStream?
    #endif
    /// Gets the replies to change notifications, which come after their requests, from the
    /// I/O queue: once a change comes, or the handle closes. Set before the device is used.
    var notificationCompletionHandler: (RDPDeviceIOCompletion) -> Void = { _ in }

    init(
        deviceID: UInt32,
        drive: RDPSharedDrive,
        queue: DispatchQueue,
        descriptorBudget: RDPSharedDriveDescriptorBudget = .shared,
        listingByteLimit: Int = maximumListingByteCount,
        changeSource: RDPSharedDriveChangeSource = .platformDefault,
        watchDescriptorBudget: RDPSharedDriveDescriptorBudget = .directoryWatches
    ) {
        self.deviceID = deviceID
        self.drive = drive
        self.queue = queue
        self.descriptorBudget = descriptorBudget
        self.listingByteLimit = listingByteLimit
        self.changeSource = changeSource
        self.watchDescriptorBudget = watchDescriptorBudget
    }

    /// The session's end closes the server's handles, deleting what they had pending, as
    /// closing each would.
    deinit {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // Stopped on its queue, which it reports on; deinit can run on any thread.
        if let changeStream {
            self.changeStream = nil
            queue.async {
                changeStream.stop()
            }
        }
        #endif
        closeAllFiles()
    }

    /// Closes every handle, as the session's end does: for a server starting device
    /// redirection over, which has forgotten them, and their change notifications.
    func closeAllFiles() {
        for file in openFiles.values {
            release(file)
        }
        openFiles = [:]
        stopWatchingIfUnwatched()
    }

    /// Whether FSEvents reports the folder's changes, for tests.
    var isWatchingFolder: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        changeStream != nil
        #else
        false
        #endif
    }

    /// The directories watched one by one, for tests.
    var watchedDirectoryCount: Int {
        directoryWatches.count
    }

    /// Resolves the shared folder, so a drive is announced only while it exists.
    @discardableResult
    func resolveRoot() -> Bool {
        var info = stat()
        guard let path = realPath(drive.url.path), stat(path, &info) == 0, info.isDirectory else {
            rootPath = nil
            return false
        }
        rootPath = path
        return true
    }

    /// The completion for `request`, or nil while it stays pending.
    func completion(for request: RDPDeviceIORequest) -> RDPDeviceIOCompletion? {
        let body: Data
        do {
            guard let reply = try reply(
                to: RDPDriveRequest.parse(request),
                fileID: request.fileID,
                completionID: request.completionID
            ) else {
                return nil
            }
            body = reply
        } catch let failure as RDPDriveFailure {
            return RDPDeviceIOCompletion(
                deviceID: deviceID,
                completionID: request.completionID,
                status: failure.status,
                body: request.failureReplyBody
            )
        } catch {
            return RDPDeviceIOCompletion(
                deviceID: deviceID,
                completionID: request.completionID,
                status: RDPNTStatus.invalidParameter,
                body: request.failureReplyBody
            )
        }
        return RDPDeviceIOCompletion(
            deviceID: deviceID,
            completionID: request.completionID,
            status: RDPNTStatus.success,
            body: body
        )
    }

    /// The success body, nil for a request left pending, or a thrown `RDPDriveFailure`.
    private func reply(to request: RDPDriveRequest, fileID: UInt32, completionID: UInt32) throws -> Data? {
        switch request {
        case let .create(desiredAccess, disposition, options, path):
            return try create(desiredAccess: desiredAccess, disposition: disposition, options: options, path: path)
        case .close:
            try close(fileID)
            return Data(count: 5)
        case let .read(length, offset):
            return try read(fileID, length: length, offset: offset)
        case let .write(offset, data):
            return try write(fileID, offset: offset, data: data)
        case let .queryInformation(informationClass):
            return try lengthPrefixed(queryInformation(fileID, informationClass: informationClass))
        case let .setInformation(informationClass, length, buffer):
            try setInformation(fileID, informationClass: informationClass, buffer: buffer)
            // DR_DRIVE_SET_INFORMATION_RSP echoes the request's Length ([MS-RDPEFS] 2.2.3.4.9).
            var body = Data()
            body.appendLittleEndianUInt32(length)
            return body
        case let .queryVolumeInformation(informationClass):
            guard let buffer = try volumeInformation().encoded(informationClass: informationClass) else {
                throw RDPDriveFailure(status: RDPNTStatus.notSupported)
            }
            return lengthPrefixed(buffer)
        case .setVolumeInformation:
            throw RDPDriveFailure(status: RDPNTStatus.notSupported)
        case let .queryDirectory(informationClass, initialQuery, path):
            return try queryDirectory(fileID, informationClass: informationClass, initialQuery: initialQuery, path: path)
        case let .notifyChangeDirectory(watchTree):
            try waitForChange(fileID, watchTree: watchTree, completionID: completionID)
            return nil
        case .deviceControl:
            // OutputBufferLength 0, as FreeRDP's drive channel answers every IOCTL.
            return Data(count: 4)
        case .lockControl:
            // Locks are not enforced across the redirection; the reply is Padding.
            return Data(count: 5)
        case .unsupported:
            throw RDPDriveFailure(status: RDPNTStatus.notSupported)
        }
    }

    // MARK: Create and close

    private func create(desiredAccess: UInt32, disposition: UInt32, options: UInt32, path: String) throws -> Data {
        guard openFiles.count < Self.maximumOpenFileCount else {
            throw RDPDriveFailure(status: RDPNTStatus.tooManyOpenedFiles)
        }
        guard disposition <= RDPDriveCreateDisposition.overwriteIf else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        let components = try Self.components(of: path)
        let entryPath = try entry(for: components)
        let deleteOnClose = options & RDPDriveCreateOptions.deleteOnClose != 0
        if deleteOnClose, components.isEmpty {
            throw RDPDriveFailure(status: RDPNTStatus.cannotDelete)
        }
        let wantsDirectory = options & RDPDriveCreateOptions.directoryFile != 0
        let wantsFile = options & RDPDriveCreateOptions.nonDirectoryFile != 0
        let wantsWrite = desiredAccess & RDPDriveAccessMask.write != 0
        // MAXIMUM_ALLOWED asks for what the caller may have: writing where allowed.
        let mayWrite = desiredAccess & RDPDriveAccessMask.maximumAllowed != 0

        var file: RDPSharedDriveOpenFile
        let information: UInt8
        if let existing = try target(of: entryPath) {
            let isDirectory = existing.info.isDirectory
            guard disposition != RDPDriveCreateDisposition.create else {
                throw RDPDriveFailure(status: RDPNTStatus.objectNameCollision)
            }
            if wantsDirectory, !isDirectory {
                throw RDPDriveFailure(status: RDPNTStatus.notADirectory)
            }
            if wantsFile || [
                RDPDriveCreateDisposition.supersede,
                RDPDriveCreateDisposition.overwrite,
                RDPDriveCreateDisposition.overwriteIf,
            ].contains(disposition), isDirectory {
                throw RDPDriveFailure(status: RDPNTStatus.fileIsADirectory)
            }
            file = RDPSharedDriveOpenFile(
                path: entryPath,
                entryIdentity: RDPFileIdentity(existing.entryInfo),
                targetPath: existing.path,
                targetIdentity: RDPFileIdentity(existing.info),
                isDirectory: isDirectory
            )
            switch disposition {
            case RDPDriveCreateDisposition.open, RDPDriveCreateDisposition.openIf:
                information = RDPDriveCreateInformation.opened
            case RDPDriveCreateDisposition.supersede:
                information = RDPDriveCreateInformation.superseded
            default:
                information = RDPDriveCreateInformation.overwritten
            }
            if !isDirectory {
                let truncates = information != RDPDriveCreateInformation.opened
                try open(
                    &file,
                    write: wantsWrite || mayWrite || truncates,
                    truncate: truncates,
                    readOnlyFallback: mayWrite && !wantsWrite && !truncates
                )
            }
        } else {
            guard [
                RDPDriveCreateDisposition.create,
                RDPDriveCreateDisposition.openIf,
                RDPDriveCreateDisposition.overwriteIf,
                RDPDriveCreateDisposition.supersede,
            ].contains(disposition) else {
                throw RDPDriveFailure(status: RDPNTStatus.objectNameNotFound)
            }
            guard !components.isEmpty else {
                throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
            }
            var info = stat()
            if wantsDirectory {
                guard mkdir(entryPath, 0o777) == 0, lstat(entryPath, &info) == 0 else {
                    throw RDPDriveFailure.posix()
                }
                file = RDPSharedDriveOpenFile(created: entryPath, identity: RDPFileIdentity(info), isDirectory: true)
            } else {
                guard descriptorBudget.reserve() else {
                    throw RDPDriveFailure(status: RDPNTStatus.tooManyOpenedFiles)
                }
                // O_EXCL: the name is created here, never followed somewhere else.
                let descriptor = Darwin.open(entryPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
                guard descriptor >= 0, fstat(descriptor, &info) == 0 else {
                    let failure = RDPDriveFailure.posix()
                    if descriptor >= 0 {
                        Darwin.close(descriptor)
                    }
                    descriptorBudget.release()
                    throw failure
                }
                file = RDPSharedDriveOpenFile(created: entryPath, identity: RDPFileIdentity(info), isDirectory: false)
                file.descriptor = descriptor
                file.isWritable = true
            }
            // FILE_SUPERSEDED also reports a new file ([MS-RDPEFS] 2.2.1.5.1).
            information = RDPDriveCreateInformation.superseded
        }
        file.deletePending = deleteOnClose
        // [MS-FSA] 2.1.5.1.1, 2.1.5.1.2: a directory opened to be deleted takes no change notification.
        file.isMarkedDeleted = deleteOnClose && file.isDirectory

        let fileID = allocateFileID()
        openFiles[fileID] = file
        var body = Data()
        body.appendLittleEndianUInt32(fileID)
        body.appendUInt8(information)
        return body
    }

    /// Opens a regular file. O_NONBLOCK keeps a FIFO put in its place from blocking the open.
    private func open(_ file: inout RDPSharedDriveOpenFile, write: Bool, truncate: Bool, readOnlyFallback: Bool) throws {
        guard descriptorBudget.reserve() else {
            throw RDPDriveFailure(status: RDPNTStatus.tooManyOpenedFiles)
        }
        let flags = O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = Darwin.open(file.targetPath, (write ? O_RDWR : O_RDONLY) | (truncate ? O_TRUNC : 0) | flags)
        // Saved at once, from the retry when there is one, as later calls may change errno.
        var openError = errno
        file.isWritable = write
        // The errors that refuse writing only: the file's permissions (EACCES), a locked file
        // (UF_IMMUTABLE) or a read-only sandbox grant (EPERM), a read-only volume (EROFS),
        // and a program that is running (ETXTBSY).
        if descriptor < 0, write, readOnlyFallback, [EACCES, EPERM, EROFS, ETXTBSY].contains(openError) {
            descriptor = Darwin.open(file.targetPath, O_RDONLY | flags)
            openError = errno
            file.isWritable = false
        }
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, info.isRegularFile else {
            let failure = descriptor >= 0 ? RDPDriveFailure(status: RDPNTStatus.accessDenied) : RDPDriveFailure.posix(openError)
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            descriptorBudget.release()
            throw failure
        }
        file.descriptor = descriptor
    }

    private func close(_ fileID: UInt32) throws {
        guard let file = openFiles.removeValue(forKey: fileID) else {
            throw RDPDriveFailure.invalidHandle
        }
        // The change notifications still waiting complete first, with STATUS_NOTIFY_CLEANUP and
        // no entries ([MS-FSA] "Server Requests Closing an Open", [MS-RDPEFS] 3.2.5.2.24),
        // which frees their CompletionIds on the server ([MS-RDPEFS] 2.2.1.4).
        for completionID in file.changeNotification?.waitingCompletionIDs ?? [] {
            completeNotification(completionID, status: RDPNTStatus.notifyCleanup)
        }
        release(file)
        stopWatchingIfUnwatched()
    }

    /// Closes a handle's descriptor and deletes its entry if a delete is pending.
    private func release(_ file: RDPSharedDriveOpenFile) {
        listingByteCount -= file.listingByteCount
        waitingNotificationCount -= file.changeNotification?.waitingCompletionIDs.count ?? 0
        if let descriptor = file.descriptor {
            Darwin.close(descriptor)
            descriptorBudget.release()
        }
        // An entry that is no longer the one opened is left alone. rmdir never removes a
        // directory with anything in it, and a link is removed, not what it points to.
        guard file.deletePending, let info = try? verifiedEntry(of: file) else {
            return
        }
        _ = info.isDirectory ? rmdir(file.path) : unlink(file.path)
    }

    // MARK: Read and write

    private func read(_ fileID: UInt32, length: UInt32, offset: UInt64) throws -> Data {
        let descriptor = try descriptor(of: fileID)
        guard let position = off_t(exactly: offset) else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        let count = min(Int(length), Self.maximumReadByteCount)
        var data = Data(count: count)
        var readCount = 0
        if count > 0 {
            readCount = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                pread(descriptor, buffer.baseAddress, count, position)
            }
            guard readCount >= 0 else {
                throw RDPDriveFailure.posix()
            }
        }
        var body = Data()
        body.reserveCapacity(4 + readCount)
        body.appendLittleEndianUInt32(UInt32(readCount))
        body.append(data.prefix(readCount))
        return body
    }

    private func write(_ fileID: UInt32, offset: UInt64, data: Data) throws -> Data {
        let descriptor = try descriptor(of: fileID)
        guard openFiles[fileID]?.isWritable == true else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        var position: off_t
        if offset == UInt64.max {
            // FILE_WRITE_TO_END_OF_FILE ([MS-FSA] 2.1.5.3).
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw RDPDriveFailure.posix()
            }
            position = info.st_size
        } else if let exact = off_t(exactly: offset) {
            position = exact
        } else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                pwrite(descriptor, buffer.baseAddress?.advanced(by: written), data.count - written, position)
            }
            guard result > 0 else {
                throw RDPDriveFailure.posix()
            }
            written += result
            position += off_t(result)
        }
        var body = Data()
        body.appendLittleEndianUInt32(UInt32(written))
        body.appendUInt8(0) // Padding
        return body
    }

    private func descriptor(of fileID: UInt32) throws -> Int32 {
        guard let file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        guard let descriptor = file.descriptor else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidDeviceRequest)
        }
        return descriptor
    }

    // MARK: Information

    private func queryInformation(_ fileID: UInt32, informationClass: UInt32) throws -> Data {
        guard let file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        var info = stat()
        if let descriptor = file.descriptor {
            guard fstat(descriptor, &info) == 0 else {
                throw RDPDriveFailure.posix()
            }
        } else {
            info = try verifiedTarget(of: file)
        }
        let information = Self.information(from: info, name: Self.lastComponent(of: file.path))
        switch informationClass {
        case RDPDriveInformationClass.fileBasic:
            return information.encodedBasicInformation()
        case RDPDriveInformationClass.fileStandard:
            return information.encodedStandardInformation(deletePending: file.deletePending)
        case RDPDriveInformationClass.fileAttributeTag:
            return information.encodedAttributeTagInformation()
        default:
            throw RDPDriveFailure(status: RDPNTStatus.notSupported)
        }
    }

    private func setInformation(_ fileID: UInt32, informationClass: UInt32, buffer: Data) throws {
        guard let file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        var cursor = ByteCursor(buffer)
        switch informationClass {
        case RDPDriveInformationClass.fileBasic:
            let creationTime = try cursor.readLittleEndianUInt64()
            _ = try cursor.readLittleEndianUInt64() // LastAccessTime
            let lastWriteTime = try cursor.readLittleEndianUInt64()
            // ChangeTime and FileAttributes are not applied: the change time is the
            // system's, and the attributes have no exact match in POSIX permissions.
            _ = try verifiedTarget(of: file)
            try setTimes(of: file.targetPath, creationTime: creationTime, lastWriteTime: lastWriteTime)
        case RDPDriveInformationClass.fileEndOfFile:
            try truncate(fileID, to: cursor.readLittleEndianUInt64(), onlyShrinking: false)
        case RDPDriveInformationClass.fileAllocation:
            try truncate(fileID, to: cursor.readLittleEndianUInt64(), onlyShrinking: true)
        case RDPDriveInformationClass.fileDisposition:
            // An empty buffer also sets DeletePending, as Windows sends it ([MS-RDPEFS] 2.2.3.3.9).
            let deletePending = try buffer.isEmpty || cursor.readUInt8() != 0
            if deletePending {
                guard file.path != rootPath else {
                    throw RDPDriveFailure(status: RDPNTStatus.cannotDelete)
                }
                // Refused now, as NTFS does, so the remote never thinks a directory with
                // contents was deleted.
                _ = try verifiedTarget(of: file)
                if file.isDirectory, try !isEmptyDirectory(file.targetPath) {
                    throw RDPDriveFailure(status: RDPNTStatus.directoryNotEmpty)
                }
            }
            openFiles[fileID]?.deletePending = deletePending
            if deletePending, file.isDirectory {
                markDeleted(fileID)
            }
        case RDPDriveInformationClass.fileRename:
            // RDP_FILE_RENAME_INFORMATION: ReplaceIfExists, RootDirectory (one byte each),
            // FileNameLength, FileName ([MS-RDPEFS] 2.2.3.3.9.1).
            let replaceIfExists = try cursor.readUInt8() != 0
            _ = try cursor.readUInt8()
            let nameLength = try Int(cursor.readLittleEndianUInt32())
            let nameData = try cursor.readData(count: nameLength)
            guard nameData.count.isMultiple(of: 2) else {
                throw RDPDriveFailure(status: RDPNTStatus.objectNameInvalid)
            }
            var nameCursor = ByteCursor(nameData)
            var codeUnits: [UInt16] = []
            while nameCursor.remaining > 0 {
                let codeUnit = try nameCursor.readLittleEndianUInt16()
                guard codeUnit != 0 else {
                    break
                }
                codeUnits.append(codeUnit)
            }
            try rename(fileID, to: String(decoding: codeUnits, as: UTF16.self), replaceIfExists: replaceIfExists)
        default:
            throw RDPDriveFailure(status: RDPNTStatus.notSupported)
        }
    }

    private func setTimes(of path: String, creationTime: UInt64, lastWriteTime: UInt64) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        attributes[.creationDate] = Self.date(fromFileTime: creationTime)
        attributes[.modificationDate] = Self.date(fromFileTime: lastWriteTime)
        guard !attributes.isEmpty else {
            return
        }
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw underlying?.domain == NSPOSIXErrorDomain
                ? RDPDriveFailure.posix(Int32(underlying?.code ?? 0))
                : RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
    }

    private func truncate(_ fileID: UInt32, to size: UInt64, onlyShrinking: Bool) throws {
        let descriptor = try descriptor(of: fileID)
        guard openFiles[fileID]?.isWritable == true else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        guard let length = off_t(exactly: size) else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        if onlyShrinking {
            // An allocation size only cuts a file shorter than it ([MS-FSA] 2.1.5.15.1).
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw RDPDriveFailure.posix()
            }
            guard length < info.st_size else {
                return
            }
        }
        guard ftruncate(descriptor, length) == 0 else {
            throw RDPDriveFailure.posix()
        }
    }

    /// Renames the entry the handle names, not what a link in its place points to.
    /// rename(2) replaces an existing target atomically, so a failed rename never
    /// loses either file.
    private func rename(_ fileID: UInt32, to newPath: String, replaceIfExists: Bool) throws {
        guard let file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        let components = try Self.components(of: newPath)
        guard !components.isEmpty, file.path != rootPath else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        let destination = try entry(for: components)
        let sourceInfo = try verifiedEntry(of: file)
        var destinationInfo = stat()
        if lstat(destination, &destinationInfo) == 0 {
            // On a case-insensitive volume "a.txt" and "A.txt" are one file: a case-only
            // rename finds itself, and rename(2) changes the case.
            let destinationIdentity = RDPFileIdentity(destinationInfo)
            if RDPFileIdentity(sourceInfo) != destinationIdentity {
                guard replaceIfExists else {
                    throw RDPDriveFailure(status: RDPNTStatus.objectNameCollision)
                }
                // NTFS never replaces a directory with a rename, nor a file that is open
                // ([MS-FSA] 2.1.5.15.12): its handle would go on naming the replacement.
                guard !destinationInfo.isDirectory, !openFiles.values.contains(where: {
                    $0.entryIdentity == destinationIdentity || $0.targetIdentity == destinationIdentity
                }) else {
                    throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
                }
            }
            guard Darwin.rename(file.path, destination) == 0 else {
                throw RDPDriveFailure.posix()
            }
        } else {
            guard errno == ENOENT else {
                throw RDPDriveFailure.posix()
            }
            guard renamex_np(file.path, destination, UInt32(RENAME_EXCL)) == 0 else {
                throw RDPDriveFailure.posix()
            }
        }
        // Handles inside a renamed directory keep naming the same items.
        let oldPrefix = file.path + "/"
        for (openFileID, openFile) in openFiles {
            var moved = openFile
            moved.path = Self.path(openFile.path, movingFrom: file.path, prefix: oldPrefix, to: destination)
            moved.targetPath = Self.path(openFile.targetPath, movingFrom: file.path, prefix: oldPrefix, to: destination)
            openFiles[openFileID] = moved
        }
    }

    private static func path(_ path: String, movingFrom source: String, prefix: String, to destination: String) -> String {
        if path == source {
            return destination
        }
        guard path.hasPrefix(prefix) else {
            return path
        }
        return destination + "/" + path.dropFirst(prefix.count)
    }

    private func volumeInformation() throws -> RDPDriveVolumeInformation {
        guard let rootPath else {
            throw RDPDriveFailure(status: RDPNTStatus.unsuccessful)
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: rootPath)
        let values = try? URL(fileURLWithPath: rootPath).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        var info = stat()
        let creationTime = stat(rootPath, &info) == 0 ? Self.fileTime(info.st_birthtimespec) : 0
        let bytesPerAllocationUnit: UInt64 = 4096
        let name = RDPDeviceAnnounce.deviceName(drive.name)
        return RDPDriveVolumeInformation(
            label: name,
            serialNumber: Self.serialNumber(for: name),
            creationTime: creationTime,
            totalAllocationUnits: ((attributes?[.systemSize] as? NSNumber)?.uint64Value ?? 0) / bytesPerAllocationUnit,
            availableAllocationUnits: ((attributes?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0)
                / bytesPerAllocationUnit,
            sectorsPerAllocationUnit: UInt32(bytesPerAllocationUnit / 512),
            bytesPerSector: 512,
            isCaseSensitive: values?.volumeSupportsCaseSensitiveNames == true
        )
    }

    /// A stable FNV-1a hash of the drive name, so the volume keeps its serial number.
    private static func serialNumber(for name: String) -> UInt32 {
        name.utf8.reduce(UInt32(2_166_136_261)) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
    }

    // MARK: Directories

    private func queryDirectory(_ fileID: UInt32, informationClass: UInt32, initialQuery: Bool, path: String) throws -> Data {
        guard var file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        guard file.isDirectory else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        _ = try verifiedTarget(of: file)
        if initialQuery || file.listing == nil {
            // The path names the directory and ends in the search pattern.
            let pattern = path.split(separator: "\\").last.map(String.init) ?? "*"
            guard pattern.utf16.count <= Self.maximumSearchPatternLength else {
                throw RDPDriveFailure(status: RDPNTStatus.objectNameInvalid)
            }
            let names = try (FileManager.default.contentsOfDirectory(atPath: file.targetPath))
                .map(\.precomposedStringWithCanonicalMapping)
                .filter(Self.isValidName)
                .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            let listing = ([".", ".."] + names).filter { Self.matches($0, pattern: pattern) }
            // Counted in place of the handle's own listing, which it replaces.
            let byteCount = Self.listingByteCount(of: listing)
            guard listingByteCount - file.listingByteCount + byteCount <= listingByteLimit else {
                throw RDPDriveFailure(status: RDPNTStatus.insufficientResources)
            }
            listingByteCount += byteCount - file.listingByteCount
            file.listing = listing
            file.listingByteCount = byteCount
            file.listingIndex = 0
        }
        defer {
            openFiles[fileID] = file
        }
        let listing = file.listing ?? []
        while file.listingIndex < listing.count {
            let name = listing[file.listingIndex]
            file.listingIndex += 1
            // Entries removed since the listing, or links that leave the drive, are skipped.
            guard let information = directoryEntryInformation(name, in: file.targetPath) else {
                continue
            }
            guard let entry = information.encodedDirectoryEntry(name: name, informationClass: informationClass) else {
                throw RDPDriveFailure(status: RDPNTStatus.notSupported)
            }
            return lengthPrefixed(entry)
        }
        // The names are let go at the end; an empty listing still answers the queries after it.
        listingByteCount -= file.listingByteCount
        file.listing = []
        file.listingByteCount = 0
        // [MS-FSA] 2.1.5.6.3: no match at all is STATUS_NO_SUCH_FILE, the end of one is
        // STATUS_NO_MORE_FILES. Either reply is Length 0 and Padding.
        throw RDPDriveFailure(status: initialQuery && listing.isEmpty ? RDPNTStatus.noSuchFile : RDPNTStatus.noMoreFiles)
    }

    /// What `listing` holds against `listingByteLimit`: each name's UTF-8 bytes and the
    /// array slot that holds it.
    private static func listingByteCount(of listing: [String]) -> Int {
        listing.reduce(0) { $0 + $1.utf8.count + MemoryLayout<String>.stride }
    }

    private func directoryEntryInformation(_ name: String, in directory: String) -> RDPDriveFileInformation? {
        let path = switch name {
        case ".": directory
        case "..": directory == rootPath ? directory : (directory as NSString).deletingLastPathComponent
        default: directory + "/" + name
        }
        guard let target = try? target(of: path) else {
            return nil
        }
        return Self.information(from: target.info, name: name)
    }

    private func isEmptyDirectory(_ path: String) throws -> Bool {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).isEmpty
        } catch {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
    }

    // MARK: Change notifications

    /// Has the request wait for a change in the handle's directory, or with `watchTree` under
    /// it; one that came since the handle's last request completes it at once. The handle's
    /// first request sets what it watches until it closes ([MS-FSA] 2.1.5.11).
    private func waitForChange(_ fileID: UInt32, watchTree: Bool, completionID: UInt32) throws {
        guard var file = openFiles[fileID] else {
            throw RDPDriveFailure.invalidHandle
        }
        guard file.isDirectory else {
            throw RDPDriveFailure(status: RDPNTStatus.invalidParameter)
        }
        guard !file.isMarkedDeleted else {
            throw RDPDriveFailure(status: RDPNTStatus.deletePending)
        }
        guard waitingNotificationCount < Self.maximumWaitingNotificationCount else {
            throw RDPDriveFailure(status: RDPNTStatus.insufficientResources)
        }
        var notification = file.changeNotification ?? RDPSharedDriveChangeNotification(watchTree: watchTree)
        notification.waitingCompletionIDs.append(completionID)
        waitingNotificationCount += 1
        file.changeNotification = notification
        openFiles[fileID] = file
        startWatching(file)
        if notification.hasUnreportedChange {
            reportChange(to: fileID)
        }
    }

    /// A directory's delete is pending through `fileID`: that handle takes no change
    /// notification any more, and those waiting on the directory, through any handle, end
    /// with STATUS_DELETE_PENDING ([MS-FSA] 2.1.5.15.3).
    private func markDeleted(_ fileID: UInt32) {
        guard let identity = openFiles[fileID]?.targetIdentity else {
            return
        }
        openFiles[fileID]?.isMarkedDeleted = true
        for openFileID in openFiles.keys.sorted() {
            guard let file = openFiles[openFileID], file.isDirectory, file.targetIdentity == identity,
                  let notification = file.changeNotification
            else {
                continue
            }
            openFiles[openFileID]?.changeNotification = nil
            waitingNotificationCount -= notification.waitingCompletionIDs.count
            for completionID in notification.waitingCompletionIDs {
                completeNotification(completionID, status: RDPNTStatus.deletePending)
            }
        }
        stopWatchingIfUnwatched()
    }

    /// Reports `changes` to the handles they concern. FSEvents calls it on the I/O queue.
    func receive(_ changes: [RDPSharedDriveChange]) {
        reportChange { file, notification in
            // Compared as FSEvents reports paths: with links resolved, in the case on disk.
            let directory = file.targetPath == rootPath ? rootPath : realPath(file.targetPath)
            return changes.contains { $0.concerns(directory, watchTree: notification.watchTree) }
        }
    }

    /// A directory watch saw what the directory `identity` holds change, or the directory
    /// go away, which stopped the watch.
    private func receiveChange(inDirectory identity: RDPFileIdentity, isGone: Bool) {
        reportChange { file, _ in
            file.targetIdentity == identity
        }
        if isGone {
            directoryWatches[identity] = nil
            watchUnwatchedDirectories()
        }
    }

    /// Reports a change to the handles that `concerns` picks: each completes its oldest
    /// waiting notification, as a notification takes every change since the last ([MS-FSA]
    /// 2.1.5.11.1), or keeps the change for its next.
    private func reportChange(
        where concerns: (RDPSharedDriveOpenFile, RDPSharedDriveChangeNotification) -> Bool
    ) {
        for fileID in openFiles.keys.sorted() {
            guard let file = openFiles[fileID], let notification = file.changeNotification,
                  !notification.hasUnreportedChange, concerns(file, notification)
            else {
                continue
            }
            openFiles[fileID]?.changeNotification?.hasUnreportedChange = true
            reportChange(to: fileID)
        }
    }

    /// Completes the handle's oldest waiting notification with its unreported change, if one waits.
    private func reportChange(to fileID: UInt32) {
        guard var notification = openFiles[fileID]?.changeNotification,
              notification.hasUnreportedChange,
              !notification.waitingCompletionIDs.isEmpty
        else {
            return
        }
        let completionID = notification.waitingCompletionIDs.removeFirst()
        notification.hasUnreportedChange = false
        openFiles[fileID]?.changeNotification = notification
        waitingNotificationCount -= 1
        completeNotification(completionID, status: RDPNTStatus.notifyEnumDir)
    }

    private func completeNotification(_ completionID: UInt32, status: UInt32) {
        notificationCompletionHandler(RDPDeviceIOCompletion(
            deviceID: deviceID,
            completionID: completionID,
            status: status,
            body: Self.notificationReplyBody
        ))
    }

    /// Has changes reported for `file`, a directory with a notification. A directory that
    /// cannot be watched now is tried again by its handle's next notification, and once one
    /// of the drive's directory watches stops.
    private func startWatching(_ file: RDPSharedDriveOpenFile) {
        switch changeSource {
        case .none:
            return
        case .directoryWatches:
            let identity = file.targetIdentity
            guard directoryWatches[identity] == nil else {
                return
            }
            directoryWatches[identity] = RDPSharedDriveDirectoryWatch(
                path: file.targetPath,
                identity: identity,
                queue: queue,
                descriptorBudget: watchDescriptorBudget
            ) { [weak self] isGone in
                self?.receiveChange(inDirectory: identity, isGone: isGone)
            }
        #if os(macOS) || targetEnvironment(macCatalyst)
        case .fsEvents:
            guard changeStream == nil, let rootPath else {
                return
            }
            changeStream = RDPSharedDriveChangeStream(path: rootPath, queue: queue) { [weak self] changes in
                self?.receive(changes)
            }
        #endif
        }
    }

    /// Stops the watches of directories no handle watches any more, and FSEvents once none does.
    private func stopWatchingIfUnwatched() {
        if !directoryWatches.isEmpty {
            let watched = Set(openFiles.values.lazy.filter { $0.changeNotification != nil }.map(\.targetIdentity))
            let unwatched = directoryWatches.keys.filter { !watched.contains($0) }
            for identity in unwatched {
                directoryWatches.removeValue(forKey: identity)?.stop()
            }
            if !unwatched.isEmpty {
                watchUnwatchedDirectories()
            }
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let changeStream, !openFiles.values.contains(where: { $0.changeNotification != nil }) else {
            return
        }
        changeStream.stop()
        self.changeStream = nil
        #endif
    }

    /// Watches, as far as the descriptors allow, the directories that handles watch but no
    /// directory watch reports on.
    private func watchUnwatchedDirectories() {
        for fileID in openFiles.keys.sorted() {
            guard let file = openFiles[fileID], file.changeNotification != nil,
                  directoryWatches[file.targetIdentity] == nil
            else {
                continue
            }
            startWatching(file)
        }
    }

    // MARK: Paths

    /// The names in a drive path, such as `\docs\a.txt`; the drive root has none.
    static func components(of path: String) throws -> [String] {
        let components = path.split(separator: "\\").map(String.init)
        guard components.allSatisfy(isValidName) else {
            throw RDPDriveFailure(status: RDPNTStatus.objectNameInvalid)
        }
        return components
    }

    /// Windows never sends these in a name, and `/` would leave the directory on this side.
    static func isValidName(_ name: String) -> Bool {
        name != "." && name != ".." && !name.unicodeScalars.contains {
            $0.value < 0x20 || "/\\:*?\"<>|".unicodeScalars.contains($0)
        }
    }

    /// The local path of the directory entry the components name. Its parent is resolved
    /// and must be inside the drive; the entry itself is not resolved.
    private func entry(for components: [String]) throws -> String {
        guard let rootPath else {
            throw RDPDriveFailure(status: RDPNTStatus.unsuccessful)
        }
        guard let name = components.last else {
            return rootPath
        }
        let parent = ([rootPath] + components.dropLast()).joined(separator: "/")
        guard let resolvedParent = realPath(parent) else {
            throw RDPDriveFailure(status: errno == ENOENT || errno == ENOTDIR
                ? RDPNTStatus.objectPathNotFound
                : RDPDriveFailure.posix().status)
        }
        var info = stat()
        guard isInsideDrive(resolvedParent), stat(resolvedParent, &info) == 0 else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        guard info.isDirectory else {
            throw RDPDriveFailure(status: RDPNTStatus.objectPathNotFound)
        }
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
    }

    /// The item an entry names and its status: the entry itself, or a link's target,
    /// which must be inside the drive. Nil when no entry has that name. Only regular
    /// files and directories are served: opening a FIFO or a device could block or do more.
    private func target(of entryPath: String) throws -> (path: String, info: stat, entryInfo: stat)? {
        var entryInfo = stat()
        guard lstat(entryPath, &entryInfo) == 0 else {
            guard errno == ENOENT else {
                throw RDPDriveFailure.posix()
            }
            return nil
        }
        var path = entryPath
        var info = entryInfo
        if entryInfo.st_mode & S_IFMT == S_IFLNK {
            guard let resolved = realPath(entryPath), isInsideDrive(resolved), stat(resolved, &info) == 0 else {
                throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
            }
            path = resolved
        }
        guard info.isDirectory || info.isRegularFile else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        return (path, info, entryInfo)
    }

    /// The status of a handle's entry, after checking the path still names what the handle
    /// opened through no link. A rename elsewhere can leave the path stale: on a
    /// case-insensitive volume a directory renamed under another case than the handle's path
    /// spells it, then a directory with a link to outside the drive moved into its place.
    private func verifiedEntry(of file: RDPSharedDriveOpenFile) throws -> stat {
        var info = stat()
        guard isResolvedParent(of: file.path),
              lstat(file.path, &info) == 0,
              RDPFileIdentity(info) == file.entryIdentity
        else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        return info
    }

    /// The status of what a handle's entry names, checked as `verifiedEntry` checks the entry.
    private func verifiedTarget(of file: RDPSharedDriveOpenFile) throws -> stat {
        let entryInfo = try verifiedEntry(of: file)
        guard file.targetPath != file.path else {
            return entryInfo
        }
        var info = stat()
        guard realPath(file.targetPath) == file.targetPath,
              isInsideDrive(file.targetPath),
              stat(file.targetPath, &info) == 0,
              RDPFileIdentity(info) == file.targetIdentity
        else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        return info
    }

    /// Whether the directory holding `path` is inside the drive and reached through no link.
    private func isResolvedParent(of path: String) -> Bool {
        guard path != rootPath else {
            return realPath(path) == path
        }
        let parent = (path as NSString).deletingLastPathComponent
        return realPath(parent) == parent && isInsideDrive(parent)
    }

    private func isInsideDrive(_ path: String) -> Bool {
        guard let rootPath else {
            return false
        }
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            return nil
        }
        defer {
            free(resolved)
        }
        return String(cString: resolved)
    }

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Matches a name against a Windows search pattern, ignoring case. `*` and `?` are
    /// wildcards, and so are the DOS forms `<`, `>` and `"` ([MS-FSA] 2.1.4.4), taken
    /// here as `*`, `?` and `.`.
    static func matches(_ name: String, pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern != "*", pattern != "*.*" else {
            return true
        }
        let name = Array(name.precomposedStringWithCanonicalMapping.uppercased())
        let pattern: [Character] = pattern.precomposedStringWithCanonicalMapping.uppercased().map {
            switch $0 {
            case "<": "*"
            case ">": "?"
            case "\"": "."
            default: $0
            }
        }
        var nameIndex = 0
        var patternIndex = 0
        var starIndex: Int?
        var starMatchEnd = 0
        while nameIndex < name.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "?" || pattern[patternIndex] == name[nameIndex] {
                nameIndex += 1
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starMatchEnd = nameIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starMatchEnd += 1
                nameIndex = starMatchEnd
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    // MARK: Encoding

    private func allocateFileID() -> UInt32 {
        while nextFileID == 0 || openFiles[nextFileID] != nil {
            nextFileID &+= 1
        }
        defer {
            nextFileID &+= 1
        }
        return nextFileID
    }

    private func lengthPrefixed(_ buffer: Data) -> Data {
        var body = Data()
        body.reserveCapacity(4 + buffer.count)
        body.appendLittleEndianUInt32(UInt32(buffer.count))
        body.append(buffer)
        return body
    }

    static func information(from info: stat, name: String) -> RDPDriveFileInformation {
        let isDirectory = info.isDirectory
        var attributes = isDirectory ? RDPDriveFileAttributes.directory : RDPDriveFileAttributes.archive
        if info.st_mode & S_IWUSR == 0 {
            attributes |= RDPDriveFileAttributes.readOnly
        }
        if (name.hasPrefix(".") && name != "." && name != "..") || info.st_flags & UInt32(UF_HIDDEN) != 0 {
            attributes |= RDPDriveFileAttributes.hidden
        }
        return RDPDriveFileInformation(
            creationTime: fileTime(info.st_birthtimespec),
            lastAccessTime: fileTime(info.st_atimespec),
            lastWriteTime: fileTime(info.st_mtimespec),
            changeTime: fileTime(info.st_ctimespec),
            endOfFile: isDirectory ? 0 : UInt64(max(0, info.st_size)),
            allocationSize: isDirectory ? 0 : UInt64(max(0, info.st_blocks)) * 512,
            attributes: attributes,
            linkCount: UInt32(info.st_nlink)
        )
    }

    /// Seconds between 1601-01-01, where FILETIME starts, and 1970-01-01.
    private static let fileTimeUnixEpochOffset: Int = 11_644_473_600

    static func fileTime(_ time: timespec) -> UInt64 {
        let seconds = time.tv_sec + fileTimeUnixEpochOffset
        guard seconds >= 0 else {
            return 0
        }
        return UInt64(seconds) * 10_000_000 + UInt64(max(0, time.tv_nsec) / 100)
    }

    /// Nil for 0, which leaves a time unchanged, and for negative values, such as the
    /// -1 and -2 that stop and resume its automatic updates ([MS-FSCC] 2.4.7).
    static func date(fromFileTime fileTime: UInt64) -> Date? {
        guard Int64(bitPattern: fileTime) > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(fileTime) / 10_000_000 - Double(fileTimeUnixEpochOffset))
    }
}

/// A file or directory the server opened ([MS-RDPEFS] 3.2.1.1).
struct RDPSharedDriveOpenFile {
    /// The directory entry, which rename and delete act on.
    var path: String
    /// The entry when it was opened, so a path that names something else since is caught.
    var entryIdentity: RDPFileIdentity
    /// What the entry names: itself, or a link's target inside the drive.
    var targetPath: String
    var targetIdentity: RDPFileIdentity
    var isDirectory: Bool
    /// Files only.
    var descriptor: Int32?
    var isWritable = false
    var deletePending = false
    /// The names of the current directory query, from its first request on.
    var listing: [String]?
    var listingIndex = 0
    /// What `listing` counts in its device's `listingByteCount`.
    var listingByteCount = 0
    /// Set by the handle's first change notification.
    var changeNotification: RDPSharedDriveChangeNotification?
    /// A directory's delete was pending through this handle, which then takes no change
    /// notification, even once the delete is taken back ([MS-FSA] 2.1.1.6).
    var isMarkedDeleted = false

    init(path: String, entryIdentity: RDPFileIdentity, targetPath: String, targetIdentity: RDPFileIdentity, isDirectory: Bool) {
        self.path = path
        self.entryIdentity = entryIdentity
        self.targetPath = targetPath
        self.targetIdentity = targetIdentity
        self.isDirectory = isDirectory
    }

    /// An entry this client created, which is its own target.
    init(created path: String, identity: RDPFileIdentity, isDirectory: Bool) {
        self.init(path: path, entryIdentity: identity, targetPath: path, targetIdentity: identity, isDirectory: isDirectory)
    }
}

/// What a directory handle watches, and the server's requests that wait for a change
/// ([MS-FSA] 2.1.5.11).
struct RDPSharedDriveChangeNotification {
    var watchTree: Bool
    /// Oldest first: they complete in the order they came ([MS-FSA] 2.1.5.11.1).
    var waitingCompletionIDs: [UInt32] = []
    /// A change came that no notification has reported yet.
    var hasUnreportedChange = false
}

/// The device and inode of a file system item, which a rename keeps.
struct RDPFileIdentity: Hashable {
    var device: dev_t
    var inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

/// The descriptors every shared drive holds together. The two budgets, 96 descriptors, stay
/// well below the 256 an app may have open by default (launchd's soft limit), so a server
/// cannot take the descriptors the session and the app need.
final class RDPSharedDriveDescriptorBudget: @unchecked Sendable {
    /// For the files the server opens.
    static let shared = RDPSharedDriveDescriptorBudget(maximumCount: 64)
    /// For directory watches, apart so that watching does not take the descriptors files
    /// need.
    static let directoryWatches = RDPSharedDriveDescriptorBudget(maximumCount: 32)

    private let maximumCount: Int
    private let lock = NSLock()
    private var count = 0

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    /// Takes one descriptor from the budget, or returns false when none is left.
    func reserve() -> Bool {
        lock.withLock {
            guard count < maximumCount else {
                return false
            }
            count += 1
            return true
        }
    }

    func release() {
        lock.withLock {
            count -= 1
        }
    }
}

private extension stat {
    var isDirectory: Bool {
        st_mode & S_IFMT == S_IFDIR
    }

    var isRegularFile: Bool {
        st_mode & S_IFMT == S_IFREG
    }
}
