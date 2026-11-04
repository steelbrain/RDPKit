import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
@testable import RDPKit
import Testing

// MARK: Wire format

@Test func driveAnnounceSendsASCIINameAsDeviceData() {
    let announce = RDPDeviceRedirectionDeviceListAnnounce(devices: [
        .drive(deviceID: 1, name: "Café Docs"),
    ]).encoded()

    // DeviceCount, DeviceType FILESYSTEM, DeviceId, PreferredDosName, DeviceDataLength,
    // then the name as NUL-terminated ASCII with the space and é replaced.
    #expect(announce.rdpHexString == """
    72 44 41 44 01 00 00 00 08 00 00 00 01 00 00 00 \
    43 61 66 5f 5f 44 6f 63 0a 00 00 00 43 61 66 5f \
    5f 44 6f 63 73 00
    """)
}

@Test func driveNamesAvoidCharactersDeviceAnnounceForbids() {
    #expect(RDPDeviceAnnounce.deviceName("a:b<c>d|e") == "a_b_c_d_e")
    #expect(RDPDeviceAnnounce.deviceName("") == "_")
    #expect(RDPDeviceAnnounce.drive(deviceID: 2, name: "LongDriveName").preferredDOSName == "LongDriv")
}

@Test func clientCapabilitiesAdvertiseDrivesWhenSharing() {
    let encoded = RDPDeviceRedirectionClientCapabilities(
        minorVersion: RDPDeviceRedirectionVersion.minorRDP6,
        sharesDrives: true
    ).encoded()

    #expect(encoded.littleEndianUInt16(at: 4) == 2)
    // DRIVE_CAPS_SET: CAP_DRIVE_TYPE, length 8, DRIVE_CAPABILITY_VERSION_02.
    #expect(encoded.suffix(8).rdpHexString == "04 00 08 00 02 00 00 00")
}

@Test func driveRequestsParseTheirFields() throws {
    let create = try RDPDriveRequest.parse(driveRequest(
        major: RDPDriveMajorFunction.create,
        body: createBody(path: "\\docs\\a.txt", disposition: RDPDriveCreateDisposition.openIf, options: 0x40, attributes: 0x21)
    ))
    #expect(create == .create(desiredAccess: 0x0012_019F, disposition: 3, options: 0x40, attributes: 0x21, path: "\\docs\\a.txt"))

    let write = try RDPDriveRequest.parse(driveRequest(major: RDPDriveMajorFunction.write, body: writeBody(
        offset: 7,
        data: Data([1, 2, 3])
    )))
    #expect(write == .write(offset: 7, data: Data([1, 2, 3])))

    let query = try RDPDriveRequest.parse(driveRequest(
        major: RDPDriveMajorFunction.directoryControl,
        minor: RDPDriveMinorFunction.queryDirectory,
        body: queryDirectoryBody(informationClass: 3, initialQuery: true, path: "\\docs\\*")
    ))
    #expect(query == .queryDirectory(informationClass: 3, initialQuery: true, path: "\\docs\\*"))

    for watchTree in [false, true] {
        let notify = try RDPDriveRequest.parse(driveRequest(
            major: RDPDriveMajorFunction.directoryControl,
            minor: RDPDriveMinorFunction.notifyChangeDirectory,
            body: notifyBody(watchTree: watchTree)
        ))
        #expect(notify == .notifyChangeDirectory(watchTree: watchTree))
    }

    #expect(throws: RDPDecodeError.self) {
        try RDPDriveRequest.parse(driveRequest(major: RDPDriveMajorFunction.read, body: Data([1, 2])))
    }
}

@Test func failedRepliesCarryTheirFixedFields() {
    let completion = RDPDeviceIOCompletion(
        deviceID: 1,
        completionID: 9,
        status: RDPNTStatus.accessDenied,
        body: driveRequest(major: RDPDriveMajorFunction.create, body: Data()).failureReplyBody
    )

    #expect(completion.encoded().rdpHexString == """
    72 44 43 49 01 00 00 00 09 00 00 00 22 00 00 c0 00 00 00 00 00
    """)
    #expect(driveRequest(major: RDPDriveMajorFunction.read, body: Data()).failureReplyBody.count == 4)
    #expect(driveRequest(major: RDPDriveMajorFunction.directoryControl, body: Data()).failureReplyBody.count == 5)
}

/// [MS-RDPEFS] sends several [MS-FSCC] structures without their trailing or inner
/// Reserved fields; each of these sizes moves every field after it if wrong.
@Test func fileInformationHasTheWireSizesOfMSRDPEFS() throws {
    let information = RDPDriveFileInformation(
        creationTime: 1,
        lastAccessTime: 2,
        lastWriteTime: 3,
        changeTime: 4,
        endOfFile: 5,
        allocationSize: 4096,
        attributes: RDPDriveFileAttributes.archive,
        linkCount: 1
    )
    let name = "a.txt"

    #expect(information.encodedBasicInformation().count == 36)
    #expect(information.encodedStandardInformation(deletePending: true).count == 22)
    #expect(information.encodedAttributeTagInformation().count == 8)
    #expect(try #require(information.encodedDirectoryEntry(name: name, informationClass: 1)).count == 64 + 10)
    #expect(try #require(information.encodedDirectoryEntry(name: name, informationClass: 2)).count == 68 + 10)
    #expect(try #require(information.encodedDirectoryEntry(name: name, informationClass: 3)).count == 93 + 10)
    #expect(try #require(information.encodedDirectoryEntry(name: name, informationClass: 12)).count == 12 + 10)
    #expect(information.encodedDirectoryEntry(name: name, informationClass: 99) == nil)
}

@Test func volumeInformationReportsNTFSAndItsLabel() throws {
    let volume = RDPDriveVolumeInformation(
        label: "Docs",
        serialNumber: 7,
        creationTime: 0,
        totalAllocationUnits: 100,
        availableAllocationUnits: 40,
        sectorsPerAllocationUnit: 8,
        bytesPerSector: 512,
        isCaseSensitive: false
    )

    let label = try #require(volume.encoded(informationClass: RDPDriveVolumeInformationClass.volume))
    #expect(label.count == 17 + 8)
    #expect(label.littleEndianUInt32(at: 12) == 8)
    let attribute = try #require(volume.encoded(informationClass: RDPDriveVolumeInformationClass.attribute))
    #expect(attribute.littleEndianUInt32(at: 0) == 0x0000_0006)
    #expect(attribute.suffix(8) == Data(utf16LittleEndian: "NTFS"))
    #expect(try #require(volume.encoded(informationClass: RDPDriveVolumeInformationClass.fullSize)).count == 32)
    #expect(volume.encoded(informationClass: 2) == nil)
}

@Test func searchPatternsMatchLikeWindows() {
    #expect(RDPSharedDriveDevice.matches("Report.DOCX", pattern: "*.docx"))
    #expect(RDPSharedDriveDevice.matches("a.txt", pattern: "A.TXT"))
    #expect(RDPSharedDriveDevice.matches("notes", pattern: "*.*"))
    #expect(RDPSharedDriveDevice.matches("ab1.txt", pattern: "ab?.txt"))
    #expect(RDPSharedDriveDevice.matches("a.txt", pattern: "<.txt"))
    #expect(RDPSharedDriveDevice.matches("cafe\u{301}", pattern: "caf\u{E9}"))
    #expect(!RDPSharedDriveDevice.matches("a.txt", pattern: "b*"))
    #expect(!RDPSharedDriveDevice.matches("a.txt", pattern: "a.txt?x"))
}

@Test func drivePathsRefuseNamesThatLeaveTheDirectory() throws {
    #expect(try RDPSharedDriveDevice.components(of: "\\docs\\a.txt") == ["docs", "a.txt"])
    #expect(try RDPSharedDriveDevice.components(of: "") == [])
    for path in ["\\..\\secret", "\\docs\\.", "\\a/b", "\\a:stream", "\\*.txt"] {
        #expect(throws: RDPDriveFailure(status: RDPNTStatus.objectNameInvalid)) {
            try RDPSharedDriveDevice.components(of: path)
        }
    }
}

// MARK: Shared folder

@Test func driveCreatesWritesReadsAndClosesAFile() throws {
    let drive = try TemporaryDrive()

    let created = drive.create("\\notes.txt", disposition: RDPDriveCreateDisposition.create)
    #expect(created.status == RDPNTStatus.success)
    #expect(created.information == RDPDriveCreateInformation.superseded)
    #expect(drive.write(created.fileID, offset: 0, Data("hello world".utf8)).status == RDPNTStatus.success)

    let read = drive.read(created.fileID, length: 5, offset: 6)
    #expect(read.status == RDPNTStatus.success)
    #expect(read.body == lengthPrefixed(Data("world".utf8)))
    #expect(drive.close(created.fileID).body == Data(count: 5))
    #expect(try String(contentsOf: drive.root.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello world")

    let reopened = drive.create("\\NOTES.TXT", disposition: RDPDriveCreateDisposition.open)
    #expect(reopened.information == RDPDriveCreateInformation.opened)
    #expect(drive.create("\\notes.txt", disposition: RDPDriveCreateDisposition.create).status
        == RDPNTStatus.objectNameCollision)
    #expect(drive.create("\\missing.txt", disposition: RDPDriveCreateDisposition.open).status
        == RDPNTStatus.objectNameNotFound)
    #expect(drive.create("\\missing\\a.txt", disposition: RDPDriveCreateDisposition.openIf).status
        == RDPNTStatus.objectPathNotFound)
}

@Test func driveOpensForWritingOnlyWhenWriteAccessIsAsked() throws {
    let drive = try TemporaryDrive()
    try Data("abc".utf8).write(to: drive.root.appendingPathComponent("a.txt"))

    let readOnly = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open, access: 0x0012_0089)
    #expect(drive.write(readOnly.fileID, offset: 0, Data("x".utf8)).status == RDPNTStatus.accessDenied)
    #expect(drive.write(readOnly.fileID, offset: 0, Data("x".utf8)).body == Data(count: 5))

    // MAXIMUM_ALLOWED gets write access where the file allows it, and read access where not.
    let maximum = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open, access: 0x0200_0000)
    #expect(drive.write(maximum.fileID, offset: 3, Data("d".utf8)).status == RDPNTStatus.success)
    #expect(try String(contentsOf: drive.root.appendingPathComponent("a.txt"), encoding: .utf8) == "abcd")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: drive.root.appendingPathComponent("a.txt").path)
    let maximumReadOnly = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open, access: 0x0200_0000)
    #expect(maximumReadOnly.status == RDPNTStatus.success)
    #expect(drive.read(maximumReadOnly.fileID, length: 4, offset: 0).body.dropFirst(4) == Data("abcd".utf8))
    #expect(drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: drive.root.appendingPathComponent("a.txt").path)

    let overwritten = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.overwriteIf)
    #expect(overwritten.information == RDPDriveCreateInformation.overwritten)
    #expect(try Data(contentsOf: drive.root.appendingPathComponent("a.txt")).isEmpty)
}

/// A file locked in the Finder (UF_IMMUTABLE) refuses writing with EPERM, not EACCES; a
/// MAXIMUM_ALLOWED open still gets read access, as on a read-only volume (EROFS).
@Test func driveOpensALockedFileReadOnlyForMaximumAllowed() throws {
    let drive = try TemporaryDrive()
    let locked = drive.root.appendingPathComponent("locked.txt")
    try Data("abc".utf8).write(to: locked)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    // Unlocked while the drive lives, so its folder can be removed.
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: drive.root.appendingPathComponent("locked.txt").path) }

    let maximum = drive.create("\\locked.txt", disposition: RDPDriveCreateDisposition.open, access: 0x0200_0000)
    #expect(maximum.status == RDPNTStatus.success)
    #expect(drive.read(maximum.fileID, length: 3, offset: 0).body.dropFirst(4) == Data("abc".utf8))
    #expect(drive.write(maximum.fileID, offset: 0, Data("x".utf8)).status == RDPNTStatus.accessDenied)
    // Asked for write access, the open fails as before.
    #expect(drive.create("\\locked.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)
}

@Test func driveAnswersDirectoryAndFileTypeChecksLikeNTFS() throws {
    let drive = try TemporaryDrive()
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("dir"), withIntermediateDirectories: false)
    try Data().write(to: drive.root.appendingPathComponent("file"))

    #expect(drive.create("\\file", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.directoryFile)
        .status == RDPNTStatus.notADirectory)
    #expect(drive.create("\\dir", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.nonDirectoryFile)
        .status == RDPNTStatus.fileIsADirectory)
    let made = drive.create("\\made", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.directoryFile)
    #expect(made.status == RDPNTStatus.success)
    #expect(drive.read(made.fileID, length: 1, offset: 0).status == RDPNTStatus.invalidDeviceRequest)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("made").path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func driveListsADirectoryWithItsDotEntriesAndPattern() throws {
    let drive = try TemporaryDrive()
    for name in ["b.txt", "A.txt", "c.log", ".hidden"] {
        try Data("x".utf8).write(to: drive.root.appendingPathComponent(name))
    }
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)

    #expect(drive.listing(root.fileID, pattern: "\\*") == [".", "..", ".hidden", "A.txt", "b.txt", "c.log"])
    #expect(drive.listing(root.fileID, pattern: "\\*.txt") == ["A.txt", "b.txt"])
    // A by-name lookup that finds nothing, then the end of a listing.
    #expect(drive.queryDirectory(root.fileID, initialQuery: true, path: "\\missing").status == RDPNTStatus.noSuchFile)
    #expect(drive.queryDirectory(root.fileID, initialQuery: false, path: "").status == RDPNTStatus.noMoreFiles)
    #expect(drive.queryDirectory(root.fileID, initialQuery: false, path: "").body == Data(count: 5))
}

/// Each handle keeps its query's listing, so the listings count together against a bound: a
/// server that opens many handles on a large directory cannot make the client hold a copy
/// per handle.
@Test func driveBoundsTheDirectoryListingsItsHandlesHold() throws {
    // `.`, `..` and ten 11-byte names, each counted with its 16-byte array slot: 305 bytes.
    let drive = try TemporaryDrive(listingByteLimit: 700)
    for index in 0 ..< 10 {
        try Data().write(to: drive.root.appendingPathComponent("name-\(index)0.txt"))
    }
    let handles = (0 ..< 3).map { _ in drive.create("", disposition: RDPDriveCreateDisposition.open).fileID }

    #expect(drive.queryDirectory(handles[0], initialQuery: true, path: "\\*").status == RDPNTStatus.success)
    #expect(drive.queryDirectory(handles[1], initialQuery: true, path: "\\*").status == RDPNTStatus.success)
    #expect(drive.queryDirectory(handles[2], initialQuery: true, path: "\\*").status == RDPNTStatus.insufficientResources)
    // A new query replaces the handle's own listing.
    #expect(drive.queryDirectory(handles[1], initialQuery: true, path: "\\*").status == RDPNTStatus.success)
    // A listing read to its end is let go, and a closed handle's.
    #expect(drive.listing(handles[1], pattern: "\\*").count == 12)
    #expect(drive.queryDirectory(handles[1], initialQuery: false, path: "").status == RDPNTStatus.noMoreFiles)
    #expect(drive.queryDirectory(handles[2], initialQuery: true, path: "\\*").status == RDPNTStatus.success)
    #expect(drive.queryDirectory(handles[1], initialQuery: true, path: "\\*").status == RDPNTStatus.insufficientResources)
    #expect(drive.close(handles[0]).status == RDPNTStatus.success)
    #expect(drive.queryDirectory(handles[1], initialQuery: true, path: "\\*").status == RDPNTStatus.success)
}

@Test func driveReportsFileAttributesAndSizes() throws {
    let drive = try TemporaryDrive()
    try Data(count: 10).write(to: drive.root.appendingPathComponent(".dotfile"))
    let file = drive.create("\\.dotfile", disposition: RDPDriveCreateDisposition.open)

    let standard = drive.queryInformation(file.fileID, informationClass: RDPDriveInformationClass.fileStandard)
    #expect(standard.status == RDPNTStatus.success)
    #expect(standard.body.littleEndianUInt32(at: 0) == 22)
    #expect(standard.body.littleEndianUInt64(at: 12) == 10)
    let basic = drive.queryInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic)
    #expect(basic.body.littleEndianUInt32(at: 36) == RDPDriveFileAttributes.archive | RDPDriveFileAttributes.hidden)
    #expect(drive.queryInformation(file.fileID, informationClass: 6).status == RDPNTStatus.notSupported)
}

@Test func driveTruncatesAndSetsTimes() throws {
    let drive = try TemporaryDrive()
    let file = drive.create("\\a.bin", disposition: RDPDriveCreateDisposition.create)
    _ = drive.write(file.fileID, offset: 0, Data(count: 100))

    var endOfFile = Data()
    endOfFile.appendLittleEndianUInt64(40)
    #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileEndOfFile, endOfFile)
        .body.littleEndianUInt32(at: 0) == 8)
    var allocation = Data()
    allocation.appendLittleEndianUInt64(4096)
    _ = drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileAllocation, allocation)
    let path = drive.root.appendingPathComponent("a.bin").path
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue == 40)

    // 2001-09-09 01:46:40 UTC as a FILETIME.
    let fileTime = UInt64(1_000_000_000 + 11_644_473_600) * 10_000_000
    var basic = Data()
    basic.appendLittleEndianUInt64(0)
    basic.appendLittleEndianUInt64(0)
    basic.appendLittleEndianUInt64(fileTime)
    basic.appendLittleEndianUInt64(0)
    basic.appendLittleEndianUInt32(0)
    #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic, basic).status
        == RDPNTStatus.success)
    let modified = try #require(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
    #expect(modified.timeIntervalSince1970 == 1_000_000_000)

    // -1 and -2 stop and resume automatic time updates; neither is a time to set.
    for marker in [UInt64.max, UInt64.max - 1] {
        var unchanged = Data()
        unchanged.appendLittleEndianUInt64(marker)
        unchanged.appendLittleEndianUInt64(marker)
        unchanged.appendLittleEndianUInt64(marker)
        unchanged.appendLittleEndianUInt64(marker)
        unchanged.appendLittleEndianUInt32(0)
        #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic, unchanged).status
            == RDPNTStatus.success)
    }
    #expect((try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970
        == 1_000_000_000)
}

/// FILE_ATTRIBUTE_READONLY sets a file's write permissions, which the drive reports it from;
/// attributes 0 leave them, and a directory keeps its own.
@Test func driveSetsTheReadOnlyAttributeAsWritePermissions() throws {
    let drive = try TemporaryDrive()
    let file = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.create)
    let path = drive.root.appendingPathComponent("a.txt").path
    try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: path)
    func setAttributes(_ fileID: UInt32, _ attributes: UInt32) -> UInt32 {
        var basic = Data(count: 32) // CreationTime, LastAccessTime, LastWriteTime, ChangeTime: unchanged
        basic.appendLittleEndianUInt32(attributes)
        return drive.setInformation(fileID, informationClass: RDPDriveInformationClass.fileBasic, basic).status
    }
    func permissions(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
    func reportedAttributes(_ fileID: UInt32) -> UInt32 {
        drive.queryInformation(fileID, informationClass: RDPDriveInformationClass.fileBasic).body.littleEndianUInt32(at: 36)
    }

    #expect(setAttributes(file.fileID, RDPDriveFileAttributes.readOnly | RDPDriveFileAttributes.archive) == RDPNTStatus.success)
    #expect(try permissions(path) == 0o444)
    #expect(reportedAttributes(file.fileID) == RDPDriveFileAttributes.readOnly | RDPDriveFileAttributes.archive)
    #expect(setAttributes(file.fileID, 0) == RDPNTStatus.success)
    #expect(try permissions(path) == 0o444)
    // The handle opened for writing still writes, as on Windows.
    #expect(drive.write(file.fileID, offset: 0, Data("a".utf8)).status == RDPNTStatus.success)
    // FILE_ATTRIBUTE_NORMAL, or any attributes without READONLY, let the owner write again.
    #expect(setAttributes(file.fileID, 0x0000_0080) == RDPNTStatus.success)
    #expect(try permissions(path) == 0o644)
    #expect(reportedAttributes(file.fileID) == RDPDriveFileAttributes.archive)

    let folder = drive.root.appendingPathComponent("folder").path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let directory = drive.create("\\folder", disposition: RDPDriveCreateDisposition.open)
    #expect(setAttributes(directory.fileID, RDPDriveFileAttributes.readOnly | RDPDriveFileAttributes.directory) == RDPNTStatus.success)
    #expect(try permissions(folder) == 0o755)

    // FILE_BASIC_INFORMATION without its FileAttributes, and what [MS-FSA] 2.1.5.15.2 refuses.
    #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic, Data(count: 32)).status
        == RDPNTStatus.infoLengthMismatch)
    #expect(setAttributes(file.fileID, RDPDriveFileAttributes.directory) == RDPNTStatus.invalidParameter)
    #expect(setAttributes(directory.fileID, RDPDriveFileAttributes.temporary) == RDPNTStatus.invalidParameter)
    var tooEarly = Data()
    tooEarly.appendLittleEndianUInt64(UInt64(bitPattern: -3))
    tooEarly.append(Data(count: 28))
    #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic, tooEarly).status
        == RDPNTStatus.invalidParameter)
    #expect(try permissions(path) == 0o644)
}

/// FILE_ATTRIBUTE_READONLY in a create request makes the file it creates, overwrites or
/// supersedes read-only, as SetInformation does, while the handle that made it still writes; a
/// folder, a file only opened, and a new read-only file to delete on close are not.
@Test func driveCreatesReadOnlyFilesAsAsked() throws {
    let drive = try TemporaryDrive()
    let readOnly = RDPDriveFileAttributes.readOnly | RDPDriveFileAttributes.archive
    func permissions(_ name: String) throws -> Int? {
        let path = drive.root.appendingPathComponent(name).path
        return (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    let created = drive.create("\\new.txt", disposition: RDPDriveCreateDisposition.create, attributes: readOnly)
    #expect(created.status == RDPNTStatus.success)
    #expect(try permissions("new.txt").map { $0 & 0o222 } == 0)
    #expect(drive.write(created.fileID, offset: 0, Data("new".utf8)).status == RDPNTStatus.success)
    #expect(drive.queryInformation(created.fileID, informationClass: RDPDriveInformationClass.fileBasic).body.littleEndianUInt32(at: 36)
        == readOnly)
    _ = drive.close(created.fileID)
    #expect(try Data(contentsOf: drive.root.appendingPathComponent("new.txt")) == Data("new".utf8))
    // Read-only now, it opens to be written no more.
    #expect(drive.create("\\new.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)

    for disposition in [RDPDriveCreateDisposition.overwriteIf, RDPDriveCreateDisposition.supersede] {
        try Data("old".utf8).write(to: drive.root.appendingPathComponent("old.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: drive.root.appendingPathComponent("old.txt").path)
        let overwritten = drive.create("\\old.txt", disposition: disposition, attributes: readOnly)
        #expect(overwritten.status == RDPNTStatus.success)
        #expect(try permissions("old.txt") == 0o444)
        #expect(drive.write(overwritten.fileID, offset: 0, Data("x".utf8)).status == RDPNTStatus.success)
        _ = drive.close(overwritten.fileID)
        try FileManager.default.removeItem(at: drive.root.appendingPathComponent("old.txt"))
    }

    // Opened, not overwritten, a file keeps its permissions.
    try Data("kept".utf8).write(to: drive.root.appendingPathComponent("kept.txt"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: drive.root.appendingPathComponent("kept.txt").path)
    _ = drive.close(drive.create("\\kept.txt", disposition: RDPDriveCreateDisposition.openIf, attributes: readOnly).fileID)
    #expect(try permissions("kept.txt") == 0o644)

    let folder = drive.create("\\folder", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.directoryFile, attributes: readOnly)
    #expect(folder.status == RDPNTStatus.success)
    #expect(try permissions("folder").map { $0 & 0o200 } == 0o200)

    let deleted = drive.create("\\gone.txt", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.deleteOnClose, attributes: readOnly)
    #expect(deleted.status == RDPNTStatus.cannotDelete)
    #expect(!FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("gone.txt").path))
}

/// A read-only file is not deleted, on close or by SetInformation, until its attribute is
/// cleared, as NTFS does ([MS-FSA] 2.1.5.1.2, 2.1.5.15.3). A folder's read-only is not
/// honored, and a new folder may not be temporary ([MS-FSA] 2.1.5.1.1).
@Test func driveDeletesNoReadOnlyFile() throws {
    let drive = try TemporaryDrive()
    let locked = drive.root.appendingPathComponent("locked.txt")
    try Data("keep".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
    let deleteAccess: UInt32 = 0x0011_0080 // DELETE, SYNCHRONIZE, FILE_READ_ATTRIBUTES

    #expect(drive.create(
        "\\locked.txt",
        disposition: RDPDriveCreateDisposition.open,
        options: RDPDriveCreateOptions.deleteOnClose,
        access: deleteAccess
    ).status == RDPNTStatus.cannotDelete)
    let file = drive.create("\\locked.txt", disposition: RDPDriveCreateDisposition.open, access: deleteAccess)
    #expect(file.status == RDPNTStatus.success)
    #expect(drive.setDisposition(file.fileID).status == RDPNTStatus.cannotDelete)
    #expect(FileManager.default.fileExists(atPath: locked.path))

    // Cleared first, as Remove-Item -Force does, it is deleted.
    var normal = Data(count: 32) // CreationTime, LastAccessTime, LastWriteTime, ChangeTime: unchanged
    normal.appendLittleEndianUInt32(0x0000_0080)
    #expect(drive.setInformation(file.fileID, informationClass: RDPDriveInformationClass.fileBasic, normal).status == RDPNTStatus.success)
    #expect(drive.setDisposition(file.fileID).status == RDPNTStatus.success)
    _ = drive.close(file.fileID)
    #expect(!FileManager.default.fileExists(atPath: locked.path))

    let folder = drive.root.appendingPathComponent("folder").path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o555])
    let directory = drive.create("\\folder", disposition: RDPDriveCreateDisposition.open, access: deleteAccess)
    #expect(drive.queryInformation(directory.fileID, informationClass: RDPDriveInformationClass.fileBasic).body.littleEndianUInt32(at: 36)
        == RDPDriveFileAttributes.directory | RDPDriveFileAttributes.readOnly)
    #expect(drive.setDisposition(directory.fileID).status == RDPNTStatus.success)
    _ = drive.close(directory.fileID)
    #expect(!FileManager.default.fileExists(atPath: folder))

    let temporary = drive.create(
        "\\temporary",
        disposition: RDPDriveCreateDisposition.create,
        options: RDPDriveCreateOptions.directoryFile,
        attributes: RDPDriveFileAttributes.temporary
    )
    #expect(temporary.status == RDPNTStatus.invalidParameter)
    #expect(!FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("temporary").path))
    let temporaryFile = drive.create("\\temporary.txt", disposition: RDPDriveCreateDisposition.create, attributes: RDPDriveFileAttributes.temporary)
    #expect(temporaryFile.status == RDPNTStatus.success)
}

@Test func driveDeletesOnCloseOnlyWhatNTFSWould() throws {
    let drive = try TemporaryDrive()
    let full = drive.root.appendingPathComponent("full")
    try FileManager.default.createDirectory(at: full, withIntermediateDirectories: false)
    try Data("keep".utf8).write(to: full.appendingPathComponent("keep.txt"))

    let directory = drive.create("\\full", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.setDisposition(directory.fileID).status == RDPNTStatus.directoryNotEmpty)
    _ = drive.close(directory.fileID)
    #expect(FileManager.default.fileExists(atPath: full.appendingPathComponent("keep.txt").path))

    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.setDisposition(root.fileID).status == RDPNTStatus.cannotDelete)
    #expect(drive.create("", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.deleteOnClose)
        .status == RDPNTStatus.cannotDelete)

    // A directory opened with delete-on-close that still has contents survives the close.
    let deleteOnClose = drive.create("\\full", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.deleteOnClose)
    _ = drive.close(deleteOnClose.fileID)
    #expect(FileManager.default.fileExists(atPath: full.appendingPathComponent("keep.txt").path))

    let file = drive.create("\\full\\keep.txt", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.setDisposition(file.fileID).status == RDPNTStatus.success)
    _ = drive.close(file.fileID)
    #expect(!FileManager.default.fileExists(atPath: full.appendingPathComponent("keep.txt").path))
    let empty = drive.create("\\full", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.setDisposition(empty.fileID).status == RDPNTStatus.success)
    _ = drive.close(empty.fileID)
    #expect(!FileManager.default.fileExists(atPath: full.path))
}

@Test func driveRenamesWithoutLosingEitherFile() throws {
    let drive = try TemporaryDrive()
    try Data("a".utf8).write(to: drive.root.appendingPathComponent("a.txt"))
    try Data("b".utf8).write(to: drive.root.appendingPathComponent("b.txt"))

    let file = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.rename(file.fileID, to: "\\b.txt", replace: false).status == RDPNTStatus.objectNameCollision)
    #expect(try String(contentsOf: drive.root.appendingPathComponent("b.txt"), encoding: .utf8) == "b")

    // A case-only rename names the same file on a case-insensitive volume.
    #expect(drive.rename(file.fileID, to: "\\A.txt", replace: false).status == RDPNTStatus.success)
    #expect(try FileManager.default.contentsOfDirectory(atPath: drive.root.path).sorted() == ["A.txt", "b.txt"])

    #expect(drive.rename(file.fileID, to: "\\b.txt", replace: true).status == RDPNTStatus.success)
    #expect(try FileManager.default.contentsOfDirectory(atPath: drive.root.path) == ["b.txt"])
    #expect(try String(contentsOf: drive.root.appendingPathComponent("b.txt"), encoding: .utf8) == "a")
    // The handle follows the file to its new name.
    #expect(drive.queryInformation(file.fileID, informationClass: RDPDriveInformationClass.fileStandard).status
        == RDPNTStatus.success)

    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.rename(root.fileID, to: "\\moved", replace: true).status == RDPNTStatus.accessDenied)
    #expect(drive.rename(file.fileID, to: "\\", replace: true).status == RDPNTStatus.accessDenied)
}

@Test func driveRenamesADirectoryWithOpenFilesInside() throws {
    let drive = try TemporaryDrive()
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("old"), withIntermediateDirectories: false)
    let directory = drive.create("\\old", disposition: RDPDriveCreateDisposition.open)
    let inner = drive.create("\\old\\a.txt", disposition: RDPDriveCreateDisposition.create)

    #expect(drive.rename(directory.fileID, to: "\\new", replace: false).status == RDPNTStatus.success)
    #expect(drive.setDisposition(inner.fileID).status == RDPNTStatus.success)
    _ = drive.close(inner.fileID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: drive.root.appendingPathComponent("new").path).isEmpty)
}

/// The drive is a boundary: nothing the server sends may reach outside the folder.
@Test func driveNeverLeavesTheSharedFolderThroughALink() throws {
    let drive = try TemporaryDrive()
    let outside = drive.base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(at: drive.root.appendingPathComponent("escape"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
        at: drive.root.appendingPathComponent("secret-link"),
        withDestinationURL: outside.appendingPathComponent("secret.txt")
    )

    // A new file through a linked directory: its parent resolves outside the drive.
    #expect(drive.create("\\escape\\new.txt", disposition: RDPDriveCreateDisposition.create).status == RDPNTStatus.accessDenied)
    #expect(drive.create("\\escape\\secret.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)
    #expect(drive.create("\\escape", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)
    #expect(drive.create("\\secret-link", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.accessDenied)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["secret.txt"])

    // Renaming into the linked directory is refused the same way.
    let file = drive.create("\\inside.txt", disposition: RDPDriveCreateDisposition.create)
    #expect(drive.rename(file.fileID, to: "\\escape\\moved.txt", replace: true).status == RDPNTStatus.accessDenied)

    // Links that leave the drive are not listed; deleting one removes the link only.
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.listing(root.fileID, pattern: "\\*") == [".", "..", "inside.txt"])
    let linkEntry = drive.create("\\secret-link", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.deleteOnClose)
    #expect(linkEntry.status == RDPNTStatus.accessDenied)
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.txt").path))
}

@Test func driveFollowsLinksThatStayInsideTheFolder() throws {
    let drive = try TemporaryDrive()
    let real = drive.root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: drive.root.appendingPathComponent("alias"), withDestinationURL: real)

    let created = drive.create("\\alias\\through-link.txt", disposition: RDPDriveCreateDisposition.create)
    #expect(created.status == RDPNTStatus.success)
    #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("through-link.txt").path))
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.listing(root.fileID, pattern: "\\a*") == ["alias"])
}

/// A rename can leave a handle's path naming something else: on a case-insensitive volume, a
/// directory renamed under another case than the handle's path spells it, then a directory
/// with a link to outside the drive moved into its place. The handle's path is checked again
/// before each use, so it never reaches through the link.
@Test func driveChecksAHandlesPathAgainBeforeUsingIt() throws {
    let drive = try TemporaryDrive()
    let outside = drive.base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try Data("victim".utf8).write(to: outside.appendingPathComponent("victim.txt"))

    #expect(drive.create("\\A", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.directoryFile)
        .status == RDPNTStatus.success)
    #expect(drive.create("\\A\\L", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.directoryFile)
        .status == RDPNTStatus.success)
    let directory = drive.create("\\A\\L", disposition: RDPDriveCreateDisposition.open)
    let secret = drive.create("\\A\\L\\secret.txt", disposition: RDPDriveCreateDisposition.create)
    let victim = drive.create(
        "\\A\\L\\victim.txt",
        disposition: RDPDriveCreateDisposition.create,
        options: RDPDriveCreateOptions.deleteOnClose
    )

    // What the renames leave: the handles' paths now run through a link to outside the drive.
    try FileManager.default.moveItem(at: drive.root.appendingPathComponent("A"), to: drive.root.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("A"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: drive.root.appendingPathComponent("A/L"), withDestinationURL: outside)

    #expect(drive.queryDirectory(directory.fileID, initialQuery: true, path: "\\A\\L\\*").status == RDPNTStatus.accessDenied)
    #expect(drive.queryInformation(directory.fileID, informationClass: RDPDriveInformationClass.fileBasic).status
        == RDPNTStatus.accessDenied)
    #expect(drive.rename(secret.fileID, to: "\\loot.txt", replace: false).status == RDPNTStatus.accessDenied)
    #expect(drive.setInformation(secret.fileID, informationClass: RDPDriveInformationClass.fileBasic, Data(count: 36)).status
        == RDPNTStatus.accessDenied)
    _ = drive.close(victim.fileID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == ["secret.txt", "victim.txt"])
    #expect(!FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("loot.txt").path))
    // The files the handles opened are still theirs.
    #expect(drive.write(secret.fileID, offset: 0, Data("kept".utf8)).status == RDPNTStatus.success)
    #expect(try String(contentsOf: drive.root.appendingPathComponent("moved/L/secret.txt"), encoding: .utf8) == "kept")
}

/// NTFS never replaces a file that is open: the handle would go on naming the replacement,
/// and its pending delete would remove the file renamed over it.
@Test func driveRefusesToRenameOverAnOpenFile() throws {
    let drive = try TemporaryDrive()
    try Data("a".utf8).write(to: drive.root.appendingPathComponent("a.txt"))
    try Data("b".utf8).write(to: drive.root.appendingPathComponent("b.txt"))
    let open = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open)
    let other = drive.create("\\b.txt", disposition: RDPDriveCreateDisposition.open)

    #expect(drive.rename(other.fileID, to: "\\a.txt", replace: true).status == RDPNTStatus.accessDenied)
    #expect(drive.setDisposition(open.fileID).status == RDPNTStatus.success)
    _ = drive.close(open.fileID)
    #expect(try FileManager.default.contentsOfDirectory(atPath: drive.root.path) == ["b.txt"])
    #expect(drive.rename(other.fileID, to: "\\a.txt", replace: true).status == RDPNTStatus.success)
    #expect(try String(contentsOf: drive.root.appendingPathComponent("a.txt"), encoding: .utf8) == "b")
}

/// Opening a FIFO would block the drive's I/O queue until something writes to it.
@Test func driveServesOnlyRegularFilesAndDirectories() throws {
    let drive = try TemporaryDrive()
    try Data("a".utf8).write(to: drive.root.appendingPathComponent("a.txt"))
    #expect(mkfifo(drive.root.appendingPathComponent("pipe").path, 0o600) == 0)

    #expect(drive.create("\\pipe", disposition: RDPDriveCreateDisposition.open, access: 0x0012_0089).status
        == RDPNTStatus.accessDenied)
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.listing(root.fileID, pattern: "\\*") == [".", "..", "a.txt"])
}

@Test func driveRejectsCreateDispositionsMSRDPEFSDoesNotDefine() throws {
    let drive = try TemporaryDrive()
    try Data("keep".utf8).write(to: drive.root.appendingPathComponent("a.txt"))

    #expect(drive.create("\\a.txt", disposition: 0x77, access: 0x0012_0089).status == RDPNTStatus.invalidParameter)
    #expect(try String(contentsOf: drive.root.appendingPathComponent("a.txt"), encoding: .utf8) == "keep")
}

/// The session's end closes the server's handles, so a file it opened with delete-on-close
/// does not stay behind in the shared folder.
@Test func driveDeletesPendingEntriesWhenTheSessionEnds() throws {
    let drive = try TemporaryDrive()
    do {
        let device = RDPSharedDriveDevice(
            deviceID: 2,
            drive: RDPSharedDrive(name: "Shared", url: drive.root),
            queue: DispatchQueue(label: "driveDeletesPendingEntriesWhenTheSessionEnds"),
            descriptorBudget: RDPSharedDriveDescriptorBudget(maximumCount: 4)
        )
        device.resolveRoot()
        let completion = device.completion(for: driveRequest(
            deviceID: 2,
            major: RDPDriveMajorFunction.create,
            body: createBody(path: "\\temp.txt", disposition: RDPDriveCreateDisposition.create, options: RDPDriveCreateOptions.deleteOnClose)
        ))
        #expect(completion?.status == RDPNTStatus.success)
        #expect(FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("temp.txt").path))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: drive.root.path).isEmpty)
}

/// Every drive shares one budget of descriptors, well below what the app may have open.
@Test func driveKeepsItsOpenDescriptorsWithinTheBudget() throws {
    let drive = try TemporaryDrive(descriptorBudget: RDPSharedDriveDescriptorBudget(maximumCount: 2))
    try Data("a".utf8).write(to: drive.root.appendingPathComponent("a.txt"))

    let first = drive.create("\\new.txt", disposition: RDPDriveCreateDisposition.create)
    let second = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.create("\\b.txt", disposition: RDPDriveCreateDisposition.create).status == RDPNTStatus.tooManyOpenedFiles)
    #expect(drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.tooManyOpenedFiles)
    // Directories hold no descriptor.
    #expect(drive.create("", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.success)
    _ = drive.close(first.fileID)
    #expect(drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.open).status == RDPNTStatus.success)
    _ = drive.close(second.fileID)
}

@Test func driveRefusesASearchPatternLongerThanAFileName() throws {
    let drive = try TemporaryDrive()
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.queryDirectory(root.fileID, initialQuery: true, path: "\\" + String(repeating: "?", count: 256)).status
        == RDPNTStatus.objectNameInvalid)
    #expect(drive.queryDirectory(root.fileID, initialQuery: true, path: "\\" + String(repeating: "?", count: 255)).status
        == RDPNTStatus.noSuchFile)
}

@Test func driveAnswersDeviceControlAndVolumeQueries() throws {
    let drive = try TemporaryDrive()
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)

    let control = try #require(drive.completion(for: driveRequest(
        fileID: root.fileID,
        major: RDPDriveMajorFunction.deviceControl,
        body: Data(count: 32)
    )))
    #expect(control.status == RDPNTStatus.success)
    #expect(control.body == Data(count: 4))
    let volume = try #require(drive.completion(for: driveRequest(
        major: RDPDriveMajorFunction.queryVolumeInformation,
        body: volumeQueryBody(informationClass: RDPDriveVolumeInformationClass.size)
    )))
    #expect(volume.status == RDPNTStatus.success)
    #expect(volume.body.littleEndianUInt32(at: 0) == 24)
    #expect(drive.close(999).status == RDPDriveFailure.invalidHandle.status)
}

// MARK: Change notifications

/// A change notification waits for a change in its directory and completes with
/// STATUS_NOTIFY_ENUM_DIR and no entries. A handle's notifications complete one per change,
/// oldest first, and a change no notification waits for completes the next at once.
@Test func driveCompletesAChangeNotificationOnceItsDirectoryChanges() throws {
    let drive = try TemporaryDrive()
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("docs"), withIntermediateDirectories: false)
    let rootPath = try #require(drive.device.rootPath)
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    let docs = drive.create("\\docs", disposition: RDPDriveCreateDisposition.open, options: RDPDriveCreateOptions.directoryFile)

    #expect(drive.notify(root.fileID, completionID: 11).status == TemporaryDrive.pending)
    #expect(drive.notify(root.fileID, completionID: 12).status == TemporaryDrive.pending)
    #expect(drive.notify(docs.fileID, completionID: 21).status == TemporaryDrive.pending)
    #expect(drive.notificationReplies.value.isEmpty)

    // A change inside docs changes nothing the root holds.
    drive.receive([.directory(rootPath + "/docs")])
    #expect(drive.notificationReplies.value == [enumerateDirectory(21)])
    drive.receive([.directory(rootPath)])
    #expect(drive.notificationReplies.value == [enumerateDirectory(21), enumerateDirectory(11)])
    drive.receive([.directory(rootPath)])
    #expect(drive.notificationReplies.value == [enumerateDirectory(21), enumerateDirectory(11), enumerateDirectory(12)])

    // No notification waits on the root: its next one gets the change.
    drive.receive([.directory(rootPath), .directory(rootPath)])
    #expect(drive.notificationReplies.value.count == 3)
    #expect(drive.notify(root.fileID, completionID: 13).status == TemporaryDrive.pending)
    #expect(drive.notificationReplies.value.last == enumerateDirectory(13))
    #expect(drive.notify(root.fileID, completionID: 14).status == TemporaryDrive.pending)
    #expect(drive.notificationReplies.value.count == 4)
}

/// WatchTree has a notification hear of changes anywhere under its directory; the handle's
/// first notification sets it until the handle closes.
@Test func driveChangeNotificationsWatchTheTreeWhenAsked() throws {
    let drive = try TemporaryDrive()
    try FileManager.default.createDirectory(
        at: drive.root.appendingPathComponent("docs/inner"),
        withIntermediateDirectories: true
    )
    let rootPath = try #require(drive.device.rootPath)
    let tree = drive.create("", disposition: RDPDriveCreateDisposition.open)
    let docs = drive.create("\\docs", disposition: RDPDriveCreateDisposition.open)
    _ = drive.notify(tree.fileID, watchTree: true, completionID: 1)
    _ = drive.notify(docs.fileID, completionID: 2)

    drive.receive([.directory(rootPath + "/docs/inner")])
    #expect(drive.notificationReplies.value == [enumerateDirectory(1)])
    // FSEvents could not tell what changed under the root, which holds docs.
    drive.receive([.tree(rootPath)])
    #expect(drive.notificationReplies.value == [enumerateDirectory(1), enumerateDirectory(2)])

    // The root's change waited for its next notification. Asking for no tree then changes
    // nothing: the first notification's WatchTree holds.
    _ = drive.notify(tree.fileID, watchTree: false, completionID: 3)
    #expect(drive.notificationReplies.value.last == enumerateDirectory(3))
    _ = drive.notify(tree.fileID, watchTree: false, completionID: 4)
    _ = drive.notify(docs.fileID, completionID: 5)
    drive.receive([.directory(rootPath + "/docs/inner"), .directory(rootPath + "/elsewhere")])
    #expect(drive.notificationReplies.value.count == 4)
    #expect(drive.notificationReplies.value.last == enumerateDirectory(4))
    drive.receive([.everything])
    #expect(drive.notificationReplies.value.count == 5)
    #expect(drive.notificationReplies.value.last == enumerateDirectory(5))
}

/// Closing a handle completes the notifications still waiting on it with
/// STATUS_NOTIFY_CLEANUP, before the close's own reply. A server that starts over has
/// forgotten them, so their handles close without a reply.
@Test func driveCompletesWaitingChangeNotificationsWhenItsHandleCloses() throws {
    let drive = try TemporaryDrive()
    let rootPath = try #require(drive.device.rootPath)
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    let other = drive.create("", disposition: RDPDriveCreateDisposition.open)
    _ = drive.notify(root.fileID, completionID: 31)
    _ = drive.notify(root.fileID, completionID: 32)
    _ = drive.notify(other.fileID, completionID: 41)

    #expect(drive.close(root.fileID).status == RDPNTStatus.success)
    let cleanup = { (completionID: UInt32) in
        RDPDeviceIOCompletion(deviceID: 1, completionID: completionID, status: RDPNTStatus.notifyCleanup, body: Data(count: 5))
    }
    #expect(drive.notificationReplies.value == [cleanup(31), cleanup(32)])
    drive.receive([.directory(rootPath)])
    #expect(drive.notificationReplies.value == [cleanup(31), cleanup(32), enumerateDirectory(41)])

    _ = drive.notify(other.fileID, completionID: 42)
    drive.queue.sync { drive.device.closeAllFiles() }
    drive.receive([.everything])
    #expect(drive.notificationReplies.value.count == 3)
}

/// A directory whose delete is pending ends the notifications waiting on it with
/// STATUS_DELETE_PENDING, and the handle it is pending through takes no more.
@Test func driveEndsChangeNotificationsOnADirectoryBeingDeleted() throws {
    let drive = try TemporaryDrive()
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("gone"), withIntermediateDirectories: false)
    let watching = drive.create("\\gone", disposition: RDPDriveCreateDisposition.open)
    let deleting = drive.create("\\gone", disposition: RDPDriveCreateDisposition.open)
    _ = drive.notify(watching.fileID, completionID: 1)
    _ = drive.notify(deleting.fileID, completionID: 2)

    #expect(drive.setDisposition(deleting.fileID).status == RDPNTStatus.success)
    let deletePending = { (completionID: UInt32) in
        RDPDeviceIOCompletion(deviceID: 1, completionID: completionID, status: RDPNTStatus.deletePending, body: Data(count: 5))
    }
    #expect(drive.notificationReplies.value == [deletePending(1), deletePending(2)])
    #expect(drive.notify(deleting.fileID, completionID: 3).status == RDPNTStatus.deletePending)
    #expect(drive.notify(watching.fileID, completionID: 4).status == TemporaryDrive.pending)

    let opened = drive.create(
        "\\gone",
        disposition: RDPDriveCreateDisposition.open,
        options: RDPDriveCreateOptions.deleteOnClose
    )
    #expect(drive.notify(opened.fileID, completionID: 5).status == RDPNTStatus.deletePending)
}

@Test func driveRefusesChangeNotificationsItCannotWaitFor() throws {
    let drive = try TemporaryDrive()
    let file = drive.create("\\a.txt", disposition: RDPDriveCreateDisposition.create)
    #expect(drive.notify(file.fileID, completionID: 1) == TemporaryDrive.Reply(status: RDPNTStatus.invalidParameter, body: Data(count: 5)))
    #expect(drive.notify(999, completionID: 2).status == RDPDriveFailure.invalidHandle.status)

    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    for completionID in 0 ..< UInt32(RDPSharedDriveDevice.maximumWaitingNotificationCount) {
        _ = drive.notify(root.fileID, completionID: completionID)
    }
    #expect(drive.notify(root.fileID, completionID: 99_999).status == RDPNTStatus.insufficientResources)
    // Closing the handle frees room for more.
    _ = drive.close(root.fileID)
    #expect(drive.notificationReplies.value.count == RDPSharedDriveDevice.maximumWaitingNotificationCount)
    let again = drive.create("", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.notify(again.fileID, completionID: 1).status == TemporaryDrive.pending)
}

#if os(macOS) || targetEnvironment(macCatalyst)
/// FSEvents reports a change made on the Mac while a handle watches, to a notification on a
/// directory the server named in another case, and stops once no handle watches.
@Test(.timeLimit(.minutes(1)))
func driveReportsAChangeFSEventsSees() throws {
    let drive = try TemporaryDrive(changeSource: .fsEvents)
    try FileManager.default.createDirectory(at: drive.root.appendingPathComponent("docs"), withIntermediateDirectories: false)
    let isCaseSensitive = try drive.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames == true
    let docs = drive.create(isCaseSensitive ? "\\docs" : "\\DOCS", disposition: RDPDriveCreateDisposition.open)
    #expect(docs.status == RDPNTStatus.success)
    #expect(!drive.queue.sync { drive.device.isWatchingFolder })

    _ = drive.notify(docs.fileID, completionID: 5)
    #expect(drive.queue.sync { drive.device.isWatchingFolder })
    try Data("new".utf8).write(to: drive.root.appendingPathComponent("docs/new.txt"))
    let deadline = Date() + 30
    while drive.notificationReplies.value.isEmpty, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(drive.notificationReplies.value == [enumerateDirectory(5)])

    _ = drive.close(docs.fileID)
    #expect(!drive.queue.sync { drive.device.isWatchingFolder })
}
#endif

/// Where there is no FSEvents, a kqueue watch on each watched directory, shared by its
/// handles, reports entries added to it, removed or renamed, to the handles on it only: a
/// handle that watches the tree hears nothing from its subdirectories. Watches stop with
/// their handles or once their directory is gone, and a directory past the descriptor budget
/// is watched once one stops.
@Test(.timeLimit(.minutes(1)))
func driveReportsChangesItsDirectoryWatchesSee() throws {
    let watchBudget = RDPSharedDriveDescriptorBudget(maximumCount: 2)
    let drive = try TemporaryDrive(changeSource: .directoryWatches, watchDescriptorBudget: watchBudget)
    for name in ["docs/inner", "other", "gone"] {
        try FileManager.default.createDirectory(at: drive.root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let replies = { drive.notificationReplies.value.map(\.completionID) }
    func waitForReplies(_ count: Int) {
        let deadline = Date() + 30
        while replies().count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    func write(_ path: String) throws {
        try Data("new".utf8).write(to: drive.root.appendingPathComponent(path))
    }

    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)
    let docs = drive.create("\\docs", disposition: RDPDriveCreateDisposition.open)
    let docsAgain = drive.create("\\docs", disposition: RDPDriveCreateDisposition.open)
    let other = drive.create("\\other", disposition: RDPDriveCreateDisposition.open)
    #expect(drive.notify(root.fileID, watchTree: true, completionID: 1).status == TemporaryDrive.pending)
    _ = drive.notify(docs.fileID, completionID: 2)
    _ = drive.notify(docsAgain.fileID, completionID: 3)
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 2)
    // The budget is spent: other's notification waits unwatched.
    _ = drive.notify(other.fileID, completionID: 4)
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 2)

    // A file added in docs/inner changes what docs holds no more than what the root does.
    try write("docs/inner/new.txt")
    try write("docs/new.txt")
    waitForReplies(2)
    #expect(replies() == [2, 3])
    try write("new.txt")
    waitForReplies(3)
    #expect(replies() == [2, 3, 1])
    try write("other/new.txt")

    // Closing docs' last handle stops its watch, and other is watched in its place.
    _ = drive.close(docs.fileID)
    _ = drive.close(docsAgain.fileID)
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 2)
    try FileManager.default.moveItem(
        at: drive.root.appendingPathComponent("other/new.txt"),
        to: drive.root.appendingPathComponent("other/renamed.txt")
    )
    waitForReplies(4)
    #expect(replies() == [2, 3, 1, 4])

    // A watched directory deleted on the Mac reports the change and stops its watch.
    let gone = drive.create("\\gone", disposition: RDPDriveCreateDisposition.open)
    _ = drive.notify(gone.fileID, completionID: 6)
    _ = drive.close(root.fileID)
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 2)
    try FileManager.default.removeItem(at: drive.root.appendingPathComponent("gone"))
    waitForReplies(5)
    #expect(replies() == [2, 3, 1, 4, 6])
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 1)

    drive.queue.sync { drive.device.closeAllFiles() }
    #expect(drive.queue.sync { drive.device.watchedDirectoryCount } == 0)
}

private func enumerateDirectory(_ completionID: UInt32) -> RDPDeviceIOCompletion {
    RDPDeviceIOCompletion(deviceID: 1, completionID: completionID, status: RDPNTStatus.notifyEnumDir, body: Data(count: 5))
}

// MARK: Session

@Test func deviceRedirectionSessionAnnouncesDrivesAfterLogonAndServesThem() throws {
    let drive = try TemporaryDrive()
    let pendingEventCount = Locked(0)
    // The handler runs on the I/O queue, which it holds until `resume`, so the requests below
    // queue behind it whatever the scheduling.
    let held = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    defer { resume.signal() }
    let loopback = try LoopbackDriveSession(
        drives: [RDPSharedDrive(name: "Docs", url: drive.root), RDPSharedDrive(name: "Gone", url: drive.base.appendingPathComponent("gone"))],
        pendingEventHandler: {
            pendingEventCount.withLock { $0 += 1 }
            held.signal()
            resume.wait()
        }
    )
    defer { loopback.close() }
    let session = loopback.session

    for packet: [UInt8] in [
        [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x50, 0x53],
        [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x4C, 0x55],
    ] {
        #expect(try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet))).isEmpty)
    }
    // The drives are announced from the I/O queue, which reports the missing folder.
    #expect(held.wait(timeout: .now() + 10) == .success)
    #expect(session.takePendingEvents() == [.driveUnavailable(name: "Gone")])
    #expect(session.takePendingEvents().isEmpty)

    var create = Data([0x72, 0x44, 0x52, 0x49])
    create.append(driveRequest(major: RDPDriveMajorFunction.create, body: createBody(
        path: "\\hello.txt",
        disposition: RDPDriveCreateDisposition.create
    )).encodedHeaderAndBody)
    try session.receive(RDPDeviceRedirectionPDU.parse(from: create))
    var unknownDevice = Data([0x72, 0x44, 0x52, 0x49])
    unknownDevice.append(driveRequest(deviceID: 2, major: RDPDriveMajorFunction.read, body: Data(count: 32)).encodedHeaderAndBody)
    try session.receive(RDPDeviceRedirectionPDU.parse(from: unknownDevice))
    resume.signal()

    let sent = try loopback.sentPDUs()
    #expect(pendingEventCount.value == 1)
    #expect(sent.map(\.typeName) == [
        "rdpdr-client-id-confirm",
        "rdpdr-client-name",
        "rdpdr-client-capability",
        "rdpdr-device-list-announce",
        "rdpdr-device-list-announce",
        "rdpdr-device-io-completion",
        "rdpdr-device-io-completion",
    ])
    #expect(sent[3].payload == Data([0, 0, 0, 0]))
    #expect(sent[4] == RDPDeviceRedirectionPDU.parse(fromEncoded: RDPDeviceRedirectionDeviceListAnnounce(devices: [
        .drive(deviceID: 1, name: "Docs"),
    ]).encoded()))
    // The unknown device is answered on the connection thread, while the create waits in the
    // I/O queue.
    #expect(sent[5].payload.littleEndianUInt32(at: 8) == RDPNTStatus.unsuccessful)
    #expect(sent[6].payload.littleEndianUInt32(at: 8) == RDPNTStatus.success)
    #expect(FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("hello.txt").path))
}

/// The server hears a change notification end before the close of its handle.
@Test func deviceRedirectionSessionCompletesChangeNotificationsBeforeTheirHandleCloses() throws {
    let drive = try TemporaryDrive()
    let loopback = try LoopbackDriveSession(drives: [RDPSharedDrive(name: "Docs", url: drive.root)])
    defer { loopback.close() }
    let session = loopback.session
    for packet: [UInt8] in [
        [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x50, 0x53],
        [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x4C, 0x55],
    ] {
        try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
    }
    // The drive is announced from the I/O queue.
    session.waitForDriveIO()
    try session.receive(deviceIORequestPDU(driveRequest(
        completionID: 1,
        major: RDPDriveMajorFunction.create,
        body: createBody(path: "", disposition: RDPDriveCreateDisposition.open)
    )))
    try session.receive(deviceIORequestPDU(driveRequest(
        fileID: 1,
        completionID: 2,
        major: RDPDriveMajorFunction.directoryControl,
        minor: RDPDriveMinorFunction.notifyChangeDirectory,
        body: notifyBody(watchTree: true)
    )))
    try session.receive(deviceIORequestPDU(driveRequest(
        fileID: 1,
        completionID: 3,
        major: RDPDriveMajorFunction.close,
        body: Data(count: 32)
    )))

    let completions = try loopback.sentPDUs().filter { $0.typeName == "rdpdr-device-io-completion" }
    // DeviceId, CompletionId, IoStatus, then the reply: Length 0 and Padding for the notification.
    #expect(completions.map(\.payload.rdpHexString) == [
        "01 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 01",
        "01 00 00 00 02 00 00 00 0b 01 00 00 00 00 00 00 00",
        "01 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00",
    ])
}

/// A server that starts device redirection over gets the drives again, and the handles it
/// forgot are closed, as the session's end would close them.
@Test func deviceRedirectionSessionAnnouncesDrivesAgainWhenTheServerStartsOver() throws {
    let drive = try TemporaryDrive()
    let loopback = try LoopbackDriveSession(drives: [RDPSharedDrive(name: "Docs", url: drive.root)])
    defer { loopback.close() }
    let session = loopback.session
    func setUp() throws {
        for packet: [UInt8] in [
            [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x50, 0x53],
            [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x4C, 0x55],
        ] {
            try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
        }
        session.waitForDriveIO()
    }

    try setUp()
    var create = Data([0x72, 0x44, 0x52, 0x49])
    create.append(driveRequest(major: RDPDriveMajorFunction.create, body: createBody(
        path: "\\scratch.txt",
        disposition: RDPDriveCreateDisposition.create,
        options: RDPDriveCreateOptions.deleteOnClose
    )).encodedHeaderAndBody)
    try session.receive(RDPDeviceRedirectionPDU.parse(from: create))
    session.waitForDriveIO()
    #expect(FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("scratch.txt").path))
    try setUp()

    let announcements = try loopback.sentPDUs().filter { $0.typeName == "rdpdr-device-list-announce" }
    let docs = RDPDeviceRedirectionPDU.parse(fromEncoded: RDPDeviceRedirectionDeviceListAnnounce(devices: [
        .drive(deviceID: 1, name: "Docs"),
    ]).encoded())
    #expect(announcements.filter { $0 == docs }.count == 2)
    #expect(!FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("scratch.txt").path))
}

@Test func deviceRedirectionSessionReportsADriveTheServerRefused() throws {
    let drive = try TemporaryDrive()
    let channel = EmbeddedChannel()
    let session = RDPDeviceRedirectionSession(
        userChannelID: 1006,
        staticChannelID: 1004,
        channel: channel,
        computerName: "RDPKIT",
        drives: [RDPSharedDrive(name: "Docs", url: drive.root)]
    )
    var reply = Data([0x72, 0x44, 0x72, 0x64])
    reply.appendLittleEndianUInt32(1)
    reply.appendLittleEndianUInt32(RDPNTStatus.accessDenied)

    #expect(try session.receive(RDPDeviceRedirectionPDU.parse(from: reply)) == [
        .driveRejected(name: "Docs", status: RDPNTStatus.accessDenied),
    ])
}

/// A server that stops reading the replies stops the client taking its requests too: the
/// connection thread waits for room for each, so the rest stay in the server's socket.
@Test func deviceRedirectionSessionStopsTakingRequestsWhileItsRepliesWait() throws {
    let drive = try TemporaryDrive()
    let stalled = try StalledDriveSession(drive)
    defer { stalled.close() }

    let queued = Locked(0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        for _ in 0 ..< 64 {
            _ = try? stalled.session.receive(deviceIORequestPDU(driveRequest(
                fileID: 1,
                major: RDPDriveMajorFunction.write,
                body: writeBody(offset: 0, data: Data(count: 1_024 * 1_024))
            )))
            queued.withLock { $0 += 1 }
        }
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 1) == .timedOut)
    #expect(queued.value < 40)
    // Closing fails the replies in flight, which frees the I/O queue and the waiting request.
    stalled.channel.close(promise: nil)
    #expect(finished.wait(timeout: .now() + 10) == .success)
}

/// A request waiting for room checks for cancellation about once a second; cancelling
/// closes the connection, as `RDPTransport.pollCancellation` does, which frees it.
@Test func deviceRedirectionSessionStopsWaitingForRoomOnceCancelled() throws {
    let drive = try TemporaryDrive()
    let stalled = try StalledDriveSession(drive)
    defer { stalled.close() }

    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        for _ in 0 ..< 64 {
            _ = try? stalled.session.receive(deviceIORequestPDU(driveRequest(
                fileID: 1,
                major: RDPDriveMajorFunction.write,
                body: writeBody(offset: 0, data: Data(count: 1_024 * 1_024))
            )))
        }
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 1) == .timedOut)
    stalled.cancelled.withLock { $0 = true }
    #expect(finished.wait(timeout: .now() + 10) == .success)
    #expect(!stalled.channel.isActive)
}

/// A User Logged On leaves resolving the shared folders to the I/O queue, so it does not wait
/// for the I/O queued before it, here replies the server does not read. A Server Announce that
/// overtakes that drive announce drops it: the server has forgotten what it would announce.
@Test func deviceRedirectionSessionAnnouncesDrivesWithoutWaitingForDriveIO() throws {
    let drive = try TemporaryDrive()
    let stalled = try StalledDriveSession(drive, alsoSharing: [
        RDPSharedDrive(name: "Gone", url: drive.base.appendingPathComponent("gone")),
    ])
    defer { stalled.close() }
    #expect(stalled.session.takePendingEvents() == [.driveUnavailable(name: "Gone")])

    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        // The server starts over, and over again.
        for packet: [UInt8] in [
            [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x50, 0x53],
            [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x4C, 0x55],
            [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        ] {
            _ = try? stalled.session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
        }
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 5) == .success)
    // Closing fails the replies in flight, which lets the I/O queue reach the drive announce.
    stalled.channel.close(promise: nil)
    stalled.session.waitForDriveIO()
    #expect(stalled.session.takePendingEvents().isEmpty)
}

// MARK: Helpers

/// A device redirection session sharing a drive over a connection whose server never reads,
/// with its I/O queue stuck: the replies to reads of a large file wait for room the server
/// never makes. Its first handle, file 1, is that file, open for writing.
private final class StalledDriveSession: Sendable {
    let server: Channel
    let channel: Channel
    let session: RDPDeviceRedirectionSession
    /// Once set, the session's next cancellation check closes the connection.
    let cancelled: Locked<Bool>

    init(_ drive: TemporaryDrive, alsoSharing otherDrives: [RDPSharedDrive] = []) throws {
        let readByteCount = RDPSharedDriveDevice.maximumReadByteCount
        try Data(count: readByteCount).write(to: drive.root.appendingPathComponent("large.bin"))
        let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let channel = try ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: try #require(server.localAddress?.port))
            .wait()
        let cancelled = Locked(false)
        self.server = server
        self.channel = channel
        self.cancelled = cancelled
        session = RDPDeviceRedirectionSession(
            userChannelID: 1006,
            staticChannelID: 1004,
            channel: channel,
            computerName: "RDPKIT",
            drives: [RDPSharedDrive(name: "Docs", url: drive.root)] + otherDrives,
            isCancelled: {
                guard cancelled.value else {
                    return false
                }
                channel.close(promise: nil)
                return true
            }
        )
        for packet: [UInt8] in [
            [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x50, 0x53],
            [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
            [0x72, 0x44, 0x4C, 0x55],
        ] {
            try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
        }
        session.waitForDriveIO()
        try session.receive(deviceIORequestPDU(driveRequest(major: RDPDriveMajorFunction.create, body: createBody(
            path: "\\large.bin",
            disposition: RDPDriveCreateDisposition.open
        ))))
        // Far more than the reply budget and what the sockets buffer.
        var read = Data()
        read.appendLittleEndianUInt32(UInt32(readByteCount))
        read.appendLittleEndianUInt64(0)
        read.append(Data(count: 20))
        for _ in 0 ..< 6 {
            try session.receive(deviceIORequestPDU(driveRequest(fileID: 1, major: RDPDriveMajorFunction.read, body: read)))
        }
    }

    func close() {
        channel.close(promise: nil)
        server.close(promise: nil)
    }
}

/// A device redirection session sharing `drives` over a loopback connection whose server keeps
/// what the client sends. The session sends from its I/O queue as well as the calling thread,
/// which an `EmbeddedChannel`, confined to one thread, does not allow.
private final class LoopbackDriveSession {
    let session: RDPDeviceRedirectionSession
    private let server: Channel
    private let channel: Channel
    private let receiver: ReceivingHandler

    init(drives: [RDPSharedDrive], pendingEventHandler: @escaping @Sendable () -> Void = {}) throws {
        let receiver = ReceivingHandler()
        self.receiver = receiver
        server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(receiver)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        channel = try ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: try #require(server.localAddress?.port))
            .wait()
        session = RDPDeviceRedirectionSession(
            userChannelID: 1006,
            staticChannelID: 1004,
            channel: channel,
            computerName: "RDPKIT",
            drives: drives,
            pendingEventHandler: pendingEventHandler
        )
    }

    /// What the session sent, once the drive I/O queued so far is done. The connection closes
    /// behind the writes queued on its event loop, so the server has them all once it sees the
    /// close.
    func sentPDUs() throws -> [RDPDeviceRedirectionPDU] {
        session.waitForDriveIO()
        try channel.close().wait()
        #expect(receiver.closed.wait(timeout: .now() + 10) == .success)
        var pdus: [RDPDeviceRedirectionPDU] = []
        var reassembler = RDPStaticVirtualChannelReassembler()
        var received = receiver.received.value
        while let packet = try received.nextPacket() {
            let chunk = try RDPStaticVirtualChannelPDU.parse(
                fromUserData: mcsSendDataRequest(fromTPKT: packet).userData,
                maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
            )
            if let message = try reassembler.append(chunk, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount) {
                try pdus.append(RDPDeviceRedirectionPDU.parse(from: message.payload))
            }
        }
        return pdus
    }

    func close() {
        channel.close(promise: nil)
        server.close(promise: nil)
    }
}

/// Keeps what the client of a test server sends, and signals once its connection closes.
private final class ReceivingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    let received = Locked(ClientByteStream())
    let closed = DispatchSemaphore(value: 0)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        received.withLock { $0.append(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed.signal()
        context.fireChannelInactive()
    }
}

/// A shared folder in a temporary directory, removed when the test ends. Its device runs each
/// request on `queue`, as a session's I/O queue does, where FSEvents reports too.
private final class TemporaryDrive {
    /// The status `Reply` has for a request left pending.
    static let pending: UInt32 = 0xFFFF_FFFF

    let base: URL
    let root: URL
    let device: RDPSharedDriveDevice
    let queue = DispatchQueue(label: "TemporaryDrive")
    /// The replies to change notifications, in the order they went.
    let notificationReplies = Locked<[RDPDeviceIOCompletion]>([])

    /// With `changeSource` `.none`, changes come only from `receive(_:)`.
    init(
        descriptorBudget: RDPSharedDriveDescriptorBudget = RDPSharedDriveDescriptorBudget(maximumCount: 64),
        listingByteLimit: Int = RDPSharedDriveDevice.maximumListingByteCount,
        changeSource: RDPSharedDriveChangeSource = .none,
        watchDescriptorBudget: RDPSharedDriveDescriptorBudget = RDPSharedDriveDescriptorBudget(maximumCount: 32)
    ) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rdpkit-drive-\(UUID().uuidString)")
        root = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        device = RDPSharedDriveDevice(
            deviceID: 1,
            drive: RDPSharedDrive(name: "Shared", url: root),
            queue: queue,
            descriptorBudget: descriptorBudget,
            listingByteLimit: listingByteLimit,
            changeSource: changeSource,
            watchDescriptorBudget: watchDescriptorBudget
        )
        let replies = notificationReplies
        device.notificationCompletionHandler = { completion in
            replies.withLock { $0.append(completion) }
        }
        device.resolveRoot()
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    struct Reply: Equatable {
        var status: UInt32
        var body: Data
        var fileID: UInt32 {
            body.count >= 4 ? body.littleEndianUInt32(at: 0) : 0
        }

        var information: UInt8? {
            body.count >= 5 ? body[body.startIndex + 4] : nil
        }
    }

    func create(
        _ path: String,
        disposition: UInt32,
        options: UInt32 = 0,
        access: UInt32 = 0x0012_019F,
        attributes: UInt32 = 0
    ) -> Reply {
        send(fileID: 0, major: RDPDriveMajorFunction.create, body: createBody(
            path: path,
            disposition: disposition,
            options: options,
            access: access,
            attributes: attributes
        ))
    }

    func close(_ fileID: UInt32) -> Reply {
        send(fileID: fileID, major: RDPDriveMajorFunction.close, body: Data(count: 32))
    }

    func read(_ fileID: UInt32, length: UInt32, offset: UInt64) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(length)
        body.appendLittleEndianUInt64(offset)
        body.append(Data(count: 20))
        return send(fileID: fileID, major: RDPDriveMajorFunction.read, body: body)
    }

    func write(_ fileID: UInt32, offset: UInt64, _ data: Data) -> Reply {
        send(fileID: fileID, major: RDPDriveMajorFunction.write, body: writeBody(offset: offset, data: data))
    }

    func queryInformation(_ fileID: UInt32, informationClass: UInt32) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(informationClass)
        body.appendLittleEndianUInt32(0)
        body.append(Data(count: 24))
        return send(fileID: fileID, major: RDPDriveMajorFunction.queryInformation, body: body)
    }

    func setInformation(_ fileID: UInt32, informationClass: UInt32, _ buffer: Data) -> Reply {
        var body = Data()
        body.appendLittleEndianUInt32(informationClass)
        body.appendLittleEndianUInt32(UInt32(buffer.count))
        body.append(Data(count: 24))
        body.append(buffer)
        return send(fileID: fileID, major: RDPDriveMajorFunction.setInformation, body: body)
    }

    func setDisposition(_ fileID: UInt32) -> Reply {
        setInformation(fileID, informationClass: RDPDriveInformationClass.fileDisposition, Data([1]))
    }

    func rename(_ fileID: UInt32, to path: String, replace: Bool) -> Reply {
        let name = Data(utf16LittleEndian: path)
        var buffer = Data([replace ? 1 : 0, 0])
        buffer.appendLittleEndianUInt32(UInt32(name.count))
        buffer.append(name)
        return setInformation(fileID, informationClass: RDPDriveInformationClass.fileRename, buffer)
    }

    func queryDirectory(_ fileID: UInt32, initialQuery: Bool, path: String) -> Reply {
        send(
            fileID: fileID,
            major: RDPDriveMajorFunction.directoryControl,
            minor: RDPDriveMinorFunction.queryDirectory,
            body: queryDirectoryBody(informationClass: RDPDriveInformationClass.fileBothDirectory, initialQuery: initialQuery, path: path)
        )
    }

    func notify(_ fileID: UInt32, watchTree: Bool = false, completionID: UInt32) -> Reply {
        send(
            fileID: fileID,
            completionID: completionID,
            major: RDPDriveMajorFunction.directoryControl,
            minor: RDPDriveMinorFunction.notifyChangeDirectory,
            body: notifyBody(watchTree: watchTree)
        )
    }

    /// Reports `changes` as FSEvents does, on the I/O queue.
    func receive(_ changes: [RDPSharedDriveChange]) {
        queue.sync { device.receive(changes) }
    }

    func completion(for request: RDPDeviceIORequest) -> RDPDeviceIOCompletion? {
        queue.sync { device.completion(for: request) }
    }

    /// The names a directory query returns, one per request until STATUS_NO_MORE_FILES.
    func listing(_ fileID: UInt32, pattern: String) -> [String] {
        var names: [String] = []
        var reply = queryDirectory(fileID, initialQuery: true, path: pattern)
        while reply.status == RDPNTStatus.success {
            // FILE_BOTH_DIR_INFORMATION after the Length field: FileNameLength at 60, FileName at 93.
            let entry = reply.body.dropFirst(4)
            let nameLength = Int(entry.littleEndianUInt32(at: 60))
            let name = Data(entry.dropFirst(93).prefix(nameLength))
            names.append(String(decoding: stride(from: 0, to: name.count, by: 2).map {
                name.littleEndianUInt16(at: $0)
            }, as: UTF16.self))
            reply = queryDirectory(fileID, initialQuery: false, path: "")
        }
        return names
    }

    private func send(fileID: UInt32, completionID: UInt32 = 7, major: UInt32, minor: UInt32 = 0, body: Data) -> Reply {
        guard let completion = completion(for: driveRequest(
            fileID: fileID,
            completionID: completionID,
            major: major,
            minor: minor,
            body: body
        )) else {
            return Reply(status: Self.pending, body: Data())
        }
        return Reply(status: completion.status, body: completion.body)
    }
}

private func driveRequest(
    deviceID: UInt32 = 1,
    fileID: UInt32 = 0,
    completionID: UInt32 = 7,
    major: UInt32,
    minor: UInt32 = 0,
    body: Data
) -> RDPDeviceIORequest {
    RDPDeviceIORequest(
        deviceID: deviceID,
        fileID: fileID,
        completionID: completionID,
        majorFunction: major,
        minorFunction: minor,
        body: body
    )
}

private extension RDPDeviceIORequest {
    var encodedHeaderAndBody: Data {
        var data = Data()
        data.appendLittleEndianUInt32(deviceID)
        data.appendLittleEndianUInt32(fileID)
        data.appendLittleEndianUInt32(completionID)
        data.appendLittleEndianUInt32(majorFunction)
        data.appendLittleEndianUInt32(minorFunction)
        data.append(body)
        return data
    }
}

private extension RDPDeviceRedirectionPDU {
    static func parse(fromEncoded data: Data) -> RDPDeviceRedirectionPDU? {
        try? parse(from: data)
    }
}

private func deviceIORequestPDU(_ request: RDPDeviceIORequest) throws -> RDPDeviceRedirectionPDU {
    var data = Data([0x72, 0x44, 0x52, 0x49])
    data.append(request.encodedHeaderAndBody)
    return try RDPDeviceRedirectionPDU.parse(from: data)
}

private func createBody(
    path: String,
    disposition: UInt32,
    options: UInt32 = 0,
    access: UInt32 = 0x0012_019F,
    attributes: UInt32 = 0
) -> Data {
    var pathData = Data(utf16LittleEndian: path)
    pathData.appendLittleEndianUInt16(0)
    var body = Data()
    body.appendLittleEndianUInt32(access)
    body.appendLittleEndianUInt64(0)
    body.appendLittleEndianUInt32(attributes)
    body.appendLittleEndianUInt32(7)
    body.appendLittleEndianUInt32(disposition)
    body.appendLittleEndianUInt32(options)
    body.appendLittleEndianUInt32(UInt32(pathData.count))
    body.append(pathData)
    return body
}

private func writeBody(offset: UInt64, data: Data) -> Data {
    var body = Data()
    body.appendLittleEndianUInt32(UInt32(data.count))
    body.appendLittleEndianUInt64(offset)
    body.append(Data(count: 20))
    body.append(data)
    return body
}

private func queryDirectoryBody(informationClass: UInt32, initialQuery: Bool, path: String) -> Data {
    var pathData = Data(utf16LittleEndian: path)
    if !path.isEmpty {
        pathData.appendLittleEndianUInt16(0)
    }
    var body = Data()
    body.appendLittleEndianUInt32(informationClass)
    body.appendUInt8(initialQuery ? 1 : 0)
    body.appendLittleEndianUInt32(UInt32(pathData.count))
    body.append(Data(count: 23))
    body.append(pathData)
    return body
}

/// WatchTree, CompletionFilter (FILE_NOTIFY_CHANGE_FILE_NAME and _DIR_NAME), Padding.
private func notifyBody(watchTree: Bool) -> Data {
    var body = Data([watchTree ? 1 : 0])
    body.appendLittleEndianUInt32(0x0000_0003)
    body.append(Data(count: 27))
    return body
}

private func volumeQueryBody(informationClass: UInt32) -> Data {
    var body = Data()
    body.appendLittleEndianUInt32(informationClass)
    body.appendLittleEndianUInt32(0)
    body.append(Data(count: 24))
    return body
}

private func lengthPrefixed(_ data: Data) -> Data {
    var body = Data()
    body.appendLittleEndianUInt32(UInt32(data.count))
    body.append(data)
    return body
}
