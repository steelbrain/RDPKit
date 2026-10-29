import Foundation

/// A local folder shared with the server as a drive, which Windows shows as
/// `\\tsclient\<name>` ([MS-RDPEFS] 3.1.1.2). The remote session can read,
/// create, change and delete anything inside the folder, and nothing outside
/// it: paths that leave the folder, through `..` or a symbolic link, are
/// refused. A sandboxed app must hold access to `url` for the session.
public struct RDPSharedDrive: Equatable, Sendable {
    /// Sent to the server as ASCII; other characters become `_`.
    public var name: String
    public var url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// DEVICE_ANNOUNCE DeviceType ([MS-RDPEFS] 2.2.1.3).
enum RDPDeviceType {
    static let filesystem: UInt32 = 0x0000_0008
}

/// The IRP major functions a drive receives ([MS-RDPEFS] 2.2.1.4).
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

/// The NTSTATUS values a drive answers with ([MS-ERREF] 2.3.1).
enum RDPNTStatus {
    static let success: UInt32 = 0x0000_0000
    static let noMoreFiles: UInt32 = 0x8000_0006
    static let unsuccessful: UInt32 = 0xC000_0001
    static let invalidParameter: UInt32 = 0xC000_000D
    static let noSuchFile: UInt32 = 0xC000_000F
    static let invalidDeviceRequest: UInt32 = 0xC000_0010
    static let accessDenied: UInt32 = 0xC000_0022
    static let objectNameInvalid: UInt32 = 0xC000_0033
    static let objectNameNotFound: UInt32 = 0xC000_0034
    static let objectNameCollision: UInt32 = 0xC000_0035
    static let objectPathNotFound: UInt32 = 0xC000_003A
    static let diskFull: UInt32 = 0xC000_007F
    static let mediaWriteProtected: UInt32 = 0xC000_00A2
    static let fileIsADirectory: UInt32 = 0xC000_00BA
    static let notSupported: UInt32 = 0xC000_00BB
    static let directoryNotEmpty: UInt32 = 0xC000_0101
    static let notADirectory: UInt32 = 0xC000_0103
    static let tooManyOpenedFiles: UInt32 = 0xC000_011F
    static let cannotDelete: UInt32 = 0xC000_0121
}

/// CreateDisposition ([MS-SMB2] 2.2.13, as [MS-RDPEFS] 2.2.1.4.1 refers to it).
enum RDPDriveCreateDisposition {
    static let supersede: UInt32 = 0
    static let open: UInt32 = 1
    static let create: UInt32 = 2
    static let openIf: UInt32 = 3
    static let overwrite: UInt32 = 4
    static let overwriteIf: UInt32 = 5
}

enum RDPDriveCreateOptions {
    static let directoryFile: UInt32 = 0x0000_0001
    static let nonDirectoryFile: UInt32 = 0x0000_0040
    static let deleteOnClose: UInt32 = 0x0000_1000
}

/// DesiredAccess bits that need a writable file ([MS-SMB2] 2.2.13.1.1).
enum RDPDriveAccessMask {
    static let write: UInt32 = 0x0000_0002 // FILE_WRITE_DATA
        | 0x0000_0004 // FILE_APPEND_DATA
        | 0x1000_0000 // GENERIC_ALL
        | 0x4000_0000 // GENERIC_WRITE
    static let maximumAllowed: UInt32 = 0x0200_0000
}

/// DR_CREATE_RSP Information ([MS-RDPEFS] 2.2.1.5.1), where FILE_SUPERSEDED
/// also means a new file was created.
enum RDPDriveCreateInformation {
    static let superseded: UInt8 = 0
    static let opened: UInt8 = 1
    static let overwritten: UInt8 = 3
}

/// FsInformationClass values a drive serves ([MS-FSCC] 2.4, 2.5).
enum RDPDriveInformationClass {
    static let fileDirectory: UInt32 = 1
    static let fileFullDirectory: UInt32 = 2
    static let fileBothDirectory: UInt32 = 3
    static let fileBasic: UInt32 = 4
    static let fileStandard: UInt32 = 5
    static let fileRename: UInt32 = 10
    static let fileNames: UInt32 = 12
    static let fileDisposition: UInt32 = 13
    static let fileAllocation: UInt32 = 19
    static let fileEndOfFile: UInt32 = 20
    static let fileAttributeTag: UInt32 = 35
}

enum RDPDriveVolumeInformationClass {
    static let volume: UInt32 = 1
    static let size: UInt32 = 3
    static let device: UInt32 = 4
    static let attribute: UInt32 = 5
    static let fullSize: UInt32 = 7
}

enum RDPDriveFileAttributes {
    static let readOnly: UInt32 = 0x0000_0001
    static let hidden: UInt32 = 0x0000_0002
    static let directory: UInt32 = 0x0000_0010
    static let archive: UInt32 = 0x0000_0020
}

/// DR_DEVICE_IOREQUEST: the header every I/O request starts with, then the
/// function's own fields ([MS-RDPEFS] 2.2.1.4).
struct RDPDeviceIORequest: Equatable, Sendable {
    var deviceID: UInt32
    var fileID: UInt32
    var completionID: UInt32
    var majorFunction: UInt32
    var minorFunction: UInt32
    var body: Data

    static func parse(from pdu: RDPDeviceRedirectionPDU) throws -> RDPDeviceIORequest {
        guard pdu.payload.count >= 20 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        var cursor = ByteCursor(pdu.payload)
        return try RDPDeviceIORequest(
            deviceID: cursor.readLittleEndianUInt32(),
            fileID: cursor.readLittleEndianUInt32(),
            completionID: cursor.readLittleEndianUInt32(),
            majorFunction: cursor.readLittleEndianUInt32(),
            minorFunction: cursor.readLittleEndianUInt32(),
            body: cursor.readRemainingData()
        )
    }

    /// The fields a reply to this request carries even when it fails. A body the
    /// server expects but does not get leaves it reading past the end of the PDU.
    var failureReplyBody: Data {
        switch majorFunction {
        case RDPDriveMajorFunction.create:
            // FileId, Information.
            Data(count: 5)
        case RDPDriveMajorFunction.close, RDPDriveMajorFunction.lockControl:
            // Padding.
            Data(count: 5)
        case RDPDriveMajorFunction.write, RDPDriveMajorFunction.directoryControl:
            // Length, Padding.
            Data(count: 5)
        case RDPDriveMajorFunction.read,
             RDPDriveMajorFunction.queryInformation,
             RDPDriveMajorFunction.setInformation,
             RDPDriveMajorFunction.queryVolumeInformation,
             RDPDriveMajorFunction.setVolumeInformation,
             RDPDriveMajorFunction.deviceControl:
            // Length or OutputBufferLength.
            Data(count: 4)
        default:
            Data()
        }
    }
}

/// A drive I/O request's own fields ([MS-RDPEFS] 2.2.1.4, 2.2.3.3).
enum RDPDriveRequest: Equatable, Sendable {
    case create(desiredAccess: UInt32, disposition: UInt32, options: UInt32, path: String)
    case close
    case read(length: UInt32, offset: UInt64)
    case write(offset: UInt64, data: Data)
    case queryInformation(informationClass: UInt32)
    case setInformation(informationClass: UInt32, length: UInt32, buffer: Data)
    case queryVolumeInformation(informationClass: UInt32)
    case setVolumeInformation(length: UInt32)
    case queryDirectory(informationClass: UInt32, initialQuery: Bool, path: String)
    case notifyChangeDirectory
    case deviceControl
    case lockControl
    case unsupported

    static func parse(_ request: RDPDeviceIORequest) throws -> RDPDriveRequest {
        var cursor = ByteCursor(request.body)
        switch request.majorFunction {
        case RDPDriveMajorFunction.create:
            let desiredAccess = try cursor.readLittleEndianUInt32()
            _ = try cursor.readLittleEndianUInt64() // AllocationSize
            _ = try cursor.readLittleEndianUInt32() // FileAttributes
            _ = try cursor.readLittleEndianUInt32() // SharedAccess
            let disposition = try cursor.readLittleEndianUInt32()
            let options = try cursor.readLittleEndianUInt32()
            let path = try readPath(&cursor)
            return .create(desiredAccess: desiredAccess, disposition: disposition, options: options, path: path)
        case RDPDriveMajorFunction.close:
            return .close
        case RDPDriveMajorFunction.read:
            return try .read(length: cursor.readLittleEndianUInt32(), offset: cursor.readLittleEndianUInt64())
        case RDPDriveMajorFunction.write:
            let length = try Int(cursor.readLittleEndianUInt32())
            let offset = try cursor.readLittleEndianUInt64()
            _ = try cursor.readData(count: 20) // Padding
            return try .write(offset: offset, data: cursor.readData(count: length))
        case RDPDriveMajorFunction.queryInformation:
            return try .queryInformation(informationClass: cursor.readLittleEndianUInt32())
        case RDPDriveMajorFunction.setInformation:
            let informationClass = try cursor.readLittleEndianUInt32()
            let length = try cursor.readLittleEndianUInt32()
            _ = try cursor.readData(count: 24) // Padding
            return try .setInformation(
                informationClass: informationClass,
                length: length,
                buffer: cursor.readData(count: Int(length))
            )
        case RDPDriveMajorFunction.queryVolumeInformation:
            return try .queryVolumeInformation(informationClass: cursor.readLittleEndianUInt32())
        case RDPDriveMajorFunction.setVolumeInformation:
            _ = try cursor.readLittleEndianUInt32() // FsInformationClass
            return try .setVolumeInformation(length: cursor.readLittleEndianUInt32())
        case RDPDriveMajorFunction.directoryControl:
            switch request.minorFunction {
            case RDPDriveMinorFunction.queryDirectory:
                let informationClass = try cursor.readLittleEndianUInt32()
                let initialQuery = try cursor.readUInt8() != 0
                let pathLength = try Int(cursor.readLittleEndianUInt32())
                _ = try cursor.readData(count: 23) // Padding
                let path = try decodePath(cursor.readData(count: pathLength))
                return .queryDirectory(informationClass: informationClass, initialQuery: initialQuery, path: path)
            case RDPDriveMinorFunction.notifyChangeDirectory:
                return .notifyChangeDirectory
            default:
                return .unsupported
            }
        case RDPDriveMajorFunction.deviceControl:
            return .deviceControl
        case RDPDriveMajorFunction.lockControl:
            return .lockControl
        default:
            return .unsupported
        }
    }

    private static func readPath(_ cursor: inout ByteCursor) throws -> String {
        let length = try Int(cursor.readLittleEndianUInt32())
        return try decodePath(cursor.readData(count: length))
    }

    /// Paths are UTF-16LE and normally NUL-terminated.
    private static func decodePath(_ data: Data) throws -> String {
        guard data.count.isMultiple(of: 2) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(data.count / 2)
        for index in stride(from: data.startIndex, to: data.endIndex, by: 2) {
            let codeUnit = UInt16(data[index]) | UInt16(data[index + 1]) << 8
            guard codeUnit != 0 else {
                break
            }
            codeUnits.append(codeUnit)
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }
}

/// DR_DEVICE_IOCOMPLETION: the reply to an I/O request ([MS-RDPEFS] 2.2.1.5).
struct RDPDeviceIOCompletion: Equatable, Sendable {
    var deviceID: UInt32
    var completionID: UInt32
    var status: UInt32
    var body: Data

    func encoded() -> Data {
        var payload = Data()
        payload.reserveCapacity(12 + body.count)
        payload.appendLittleEndianUInt32(deviceID)
        payload.appendLittleEndianUInt32(completionID)
        payload.appendLittleEndianUInt32(status)
        payload.append(body)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.deviceIOCompletion),
            payload: payload
        ).encoded()
    }
}

/// What a drive reports about one file or directory, in the units of [MS-FSCC].
struct RDPDriveFileInformation: Equatable, Sendable {
    /// FILETIMEs: 100-nanosecond intervals since 1601-01-01 UTC.
    var creationTime: UInt64
    var lastAccessTime: UInt64
    var lastWriteTime: UInt64
    var changeTime: UInt64
    var endOfFile: UInt64
    var allocationSize: UInt64
    var attributes: UInt32
    var linkCount: UInt32

    var isDirectory: Bool {
        attributes & RDPDriveFileAttributes.directory != 0
    }

    /// FILE_BASIC_INFORMATION without its trailing Reserved field: 36 bytes on
    /// the wire ([MS-RDPEFS] 2.2.3.4.8), as FreeRDP's drive channel sends it.
    func encodedBasicInformation() -> Data {
        var data = Data()
        appendTimes(to: &data)
        data.appendLittleEndianUInt32(attributes)
        return data
    }

    /// FILE_STANDARD_INFORMATION without its trailing Reserved field: 22 bytes on
    /// the wire ([MS-RDPEFS] 2.2.3.4.8), as FreeRDP's drive channel sends it.
    func encodedStandardInformation(deletePending: Bool) -> Data {
        var data = Data()
        data.appendLittleEndianUInt64(allocationSize)
        data.appendLittleEndianUInt64(endOfFile)
        data.appendLittleEndianUInt32(linkCount)
        data.appendUInt8(deletePending ? 1 : 0)
        data.appendUInt8(isDirectory ? 1 : 0)
        return data
    }

    /// FILE_ATTRIBUTE_TAG_INFORMATION ([MS-FSCC] 2.4.6), with no reparse tag.
    func encodedAttributeTagInformation() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(attributes)
        data.appendLittleEndianUInt32(0)
        return data
    }

    /// One directory entry of `informationClass`, or nil for a class the drive
    /// does not serve ([MS-FSCC] 2.4.8, 2.4.10, 2.4.14, 2.4.28). Each reply
    /// carries one entry, so NextEntryOffset is 0.
    func encodedDirectoryEntry(name: String, informationClass: UInt32) -> Data? {
        let fileName = Data(utf16LittleEndian: name)
        var data = Data()
        data.appendLittleEndianUInt32(0) // NextEntryOffset
        data.appendLittleEndianUInt32(0) // FileIndex
        switch informationClass {
        case RDPDriveInformationClass.fileNames:
            data.appendLittleEndianUInt32(UInt32(fileName.count))
        case RDPDriveInformationClass.fileDirectory,
             RDPDriveInformationClass.fileFullDirectory,
             RDPDriveInformationClass.fileBothDirectory:
            appendTimes(to: &data)
            data.appendLittleEndianUInt64(endOfFile)
            data.appendLittleEndianUInt64(allocationSize)
            data.appendLittleEndianUInt32(attributes)
            data.appendLittleEndianUInt32(UInt32(fileName.count))
            if informationClass != RDPDriveInformationClass.fileDirectory {
                data.appendLittleEndianUInt32(0) // EaSize
            }
            if informationClass == RDPDriveInformationClass.fileBothDirectory {
                // ShortNameLength, then ShortName with no Reserved byte between them:
                // [MS-RDPEFS] 2.2.3.4.10 sends 93 fixed bytes, as FreeRDP does.
                data.appendUInt8(0)
                data.append(Data(count: 24))
            }
        default:
            return nil
        }
        data.append(fileName)
        return data
    }

    private func appendTimes(to data: inout Data) {
        data.appendLittleEndianUInt64(creationTime)
        data.appendLittleEndianUInt64(lastAccessTime)
        data.appendLittleEndianUInt64(lastWriteTime)
        data.appendLittleEndianUInt64(changeTime)
    }
}

/// What a drive reports about the volume it is on ([MS-FSCC] 2.5).
struct RDPDriveVolumeInformation: Equatable, Sendable {
    var label: String
    var serialNumber: UInt32
    var creationTime: UInt64
    var totalAllocationUnits: UInt64
    var availableAllocationUnits: UInt64
    var sectorsPerAllocationUnit: UInt32
    var bytesPerSector: UInt32
    var isCaseSensitive: Bool

    /// FILE_CASE_SENSITIVE_SEARCH, FILE_CASE_PRESERVED_NAMES and FILE_UNICODE_ON_DISK.
    private var fileSystemAttributes: UInt32 {
        (isCaseSensitive ? 0x0000_0001 : 0) | 0x0000_0002 | 0x0000_0004
    }

    /// The buffer for `informationClass`, or nil for a class the drive does not serve.
    func encoded(informationClass: UInt32) -> Data? {
        var data = Data()
        switch informationClass {
        case RDPDriveVolumeInformationClass.volume:
            // FILE_FS_VOLUME_INFORMATION without its Reserved byte, as FreeRDP sends it.
            let volumeLabel = Data(utf16LittleEndian: label)
            data.appendLittleEndianUInt64(creationTime)
            data.appendLittleEndianUInt32(serialNumber)
            data.appendLittleEndianUInt32(UInt32(volumeLabel.count))
            data.appendUInt8(0) // SupportsObjects
            data.append(volumeLabel)
        case RDPDriveVolumeInformationClass.size:
            data.appendLittleEndianUInt64(totalAllocationUnits)
            data.appendLittleEndianUInt64(availableAllocationUnits)
            data.appendLittleEndianUInt32(sectorsPerAllocationUnit)
            data.appendLittleEndianUInt32(bytesPerSector)
        case RDPDriveVolumeInformationClass.fullSize:
            data.appendLittleEndianUInt64(totalAllocationUnits)
            data.appendLittleEndianUInt64(availableAllocationUnits) // CallerAvailableAllocationUnits
            data.appendLittleEndianUInt64(availableAllocationUnits) // ActualAvailableAllocationUnits
            data.appendLittleEndianUInt32(sectorsPerAllocationUnit)
            data.appendLittleEndianUInt32(bytesPerSector)
        case RDPDriveVolumeInformationClass.device:
            data.appendLittleEndianUInt32(0x0000_0007) // FILE_DEVICE_DISK
            data.appendLittleEndianUInt32(0) // Characteristics
        case RDPDriveVolumeInformationClass.attribute:
            // Windows refuses files over 4 GiB on a volume named FAT32, so the
            // drive reports NTFS, as Windows clients do for their local disks.
            let fileSystemName = Data(utf16LittleEndian: "NTFS")
            data.appendLittleEndianUInt32(fileSystemAttributes)
            data.appendLittleEndianUInt32(255) // MaximumComponentNameLength
            data.appendLittleEndianUInt32(UInt32(fileSystemName.count))
            data.append(fileSystemName)
        default:
            return nil
        }
        return data
    }
}
