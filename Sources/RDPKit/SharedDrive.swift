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
/// symbolic link is followed only to a target inside it. Only the device
/// redirection session's I/O queue uses a device.
final class RDPSharedDriveDevice: @unchecked Sendable {
    /// A larger read is answered with fewer bytes, which [MS-RDPEFS] 2.2.1.5.3 allows;
    /// the server sizes reads, and this bounds what one request makes the client hold.
    static let maximumReadByteCount = 16 * 1024 * 1024
    static let maximumOpenFileCount = 4096

    let deviceID: UInt32
    let drive: RDPSharedDrive
    /// The shared folder with symbolic links resolved, nil while it does not exist.
    private(set) var rootPath: String?
    private var openFiles: [UInt32: RDPSharedDriveOpenFile] = [:]
    private var nextFileID: UInt32 = 1

    init(deviceID: UInt32, drive: RDPSharedDrive) {
        self.deviceID = deviceID
        self.drive = drive
    }

    deinit {
        for file in openFiles.values {
            if let descriptor = file.descriptor {
                Darwin.close(descriptor)
            }
        }
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
            guard let reply = try reply(to: RDPDriveRequest.parse(request), fileID: request.fileID) else {
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
    private func reply(to request: RDPDriveRequest, fileID: UInt32) throws -> Data? {
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
        case .notifyChangeDirectory:
            // Completing a change notification tells Windows the directory changed or
            // the handle is gone; it stays pending, as in FreeRDP's drive channel,
            // until the server closes the handle.
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
            file = RDPSharedDriveOpenFile(path: entryPath, targetPath: existing.path, isDirectory: isDirectory)
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
            file = RDPSharedDriveOpenFile(path: entryPath, targetPath: entryPath, isDirectory: wantsDirectory)
            if wantsDirectory {
                guard mkdir(entryPath, 0o777) == 0 else {
                    throw RDPDriveFailure.posix()
                }
            } else {
                // O_EXCL: the name is created here, never followed somewhere else.
                let descriptor = Darwin.open(entryPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
                guard descriptor >= 0 else {
                    throw RDPDriveFailure.posix()
                }
                file.descriptor = descriptor
                file.isWritable = true
            }
            // FILE_SUPERSEDED also reports a new file ([MS-RDPEFS] 2.2.1.5.1).
            information = RDPDriveCreateInformation.superseded
        }
        file.deletePending = deleteOnClose

        let fileID = allocateFileID()
        openFiles[fileID] = file
        var body = Data()
        body.appendLittleEndianUInt32(fileID)
        body.appendUInt8(information)
        return body
    }

    private func open(_ file: inout RDPSharedDriveOpenFile, write: Bool, truncate: Bool, readOnlyFallback: Bool) throws {
        var descriptor = Darwin.open(
            file.targetPath,
            (write ? O_RDWR : O_RDONLY) | (truncate ? O_TRUNC : 0) | O_CLOEXEC | O_NOFOLLOW
        )
        file.isWritable = write
        if descriptor < 0, write, readOnlyFallback, errno == EACCES {
            descriptor = Darwin.open(file.targetPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            file.isWritable = false
        }
        guard descriptor >= 0 else {
            throw RDPDriveFailure.posix()
        }
        file.descriptor = descriptor
    }

    private func close(_ fileID: UInt32) throws {
        guard let file = openFiles.removeValue(forKey: fileID) else {
            throw RDPDriveFailure.invalidHandle
        }
        if let descriptor = file.descriptor {
            Darwin.close(descriptor)
        }
        guard file.deletePending else {
            return
        }
        // rmdir never removes a directory with anything in it, and a link is removed,
        // not what it points to.
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
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
        let result = file.descriptor.map { fstat($0, &info) } ?? stat(file.targetPath, &info)
        guard result == 0 else {
            throw RDPDriveFailure.posix()
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
                if file.isDirectory, try !isEmptyDirectory(file.targetPath) {
                    throw RDPDriveFailure(status: RDPNTStatus.directoryNotEmpty)
                }
            }
            openFiles[fileID]?.deletePending = deletePending
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
        var sourceInfo = stat()
        var destinationInfo = stat()
        guard lstat(file.path, &sourceInfo) == 0 else {
            throw RDPDriveFailure.posix()
        }
        if lstat(destination, &destinationInfo) == 0 {
            // On a case-insensitive volume "a.txt" and "A.txt" are one file: a case-only
            // rename finds itself, and rename(2) changes the case.
            let isSameItem = sourceInfo.st_dev == destinationInfo.st_dev && sourceInfo.st_ino == destinationInfo.st_ino
            if !isSameItem {
                guard replaceIfExists else {
                    throw RDPDriveFailure(status: RDPNTStatus.objectNameCollision)
                }
                // NTFS never replaces a directory with a rename ([MS-FSA] 2.1.5.15.12).
                guard !destinationInfo.isDirectory else {
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
        if initialQuery || file.listing == nil {
            // The path names the directory and ends in the search pattern.
            let pattern = path.split(separator: "\\").last.map(String.init) ?? "*"
            let names = try (FileManager.default.contentsOfDirectory(atPath: file.targetPath))
                .map(\.precomposedStringWithCanonicalMapping)
                .filter(Self.isValidName)
                .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            file.listing = ([".", ".."] + names).filter { Self.matches($0, pattern: pattern) }
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
        // [MS-FSA] 2.1.5.6.3: no match at all is STATUS_NO_SUCH_FILE, the end of one is
        // STATUS_NO_MORE_FILES. Either reply is Length 0 and Padding.
        throw RDPDriveFailure(status: initialQuery && listing.isEmpty ? RDPNTStatus.noSuchFile : RDPNTStatus.noMoreFiles)
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
    /// which must be inside the drive. Nil when no entry has that name.
    private func target(of entryPath: String) throws -> (path: String, info: stat)? {
        var info = stat()
        guard lstat(entryPath, &info) == 0 else {
            guard errno == ENOENT else {
                throw RDPDriveFailure.posix()
            }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFLNK else {
            return (entryPath, info)
        }
        guard let resolved = realPath(entryPath), isInsideDrive(resolved), stat(resolved, &info) == 0 else {
            throw RDPDriveFailure(status: RDPNTStatus.accessDenied)
        }
        return (resolved, info)
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
    /// What the entry names: itself, or a link's target inside the drive.
    var targetPath: String
    var isDirectory: Bool
    /// Files only.
    var descriptor: Int32?
    var isWritable = false
    var deletePending = false
    /// The names of the current directory query, from its first request on.
    var listing: [String]?
    var listingIndex = 0

    init(path: String, targetPath: String, isDirectory: Bool) {
        self.path = path
        self.targetPath = targetPath
        self.isDirectory = isDirectory
    }
}

private extension stat {
    var isDirectory: Bool {
        st_mode & S_IFMT == S_IFDIR
    }
}
