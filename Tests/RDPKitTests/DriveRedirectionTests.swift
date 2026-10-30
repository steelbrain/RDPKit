import Foundation
import NIOCore
import NIOEmbedded
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
        body: createBody(path: "\\docs\\a.txt", disposition: RDPDriveCreateDisposition.openIf, options: 0x40)
    ))
    #expect(create == .create(desiredAccess: 0x0012_019F, disposition: 3, options: 0x40, path: "\\docs\\a.txt"))

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

@Test func driveLeavesChangeNotificationsPendingAndAnswersOtherRequests() throws {
    let drive = try TemporaryDrive()
    let root = drive.create("", disposition: RDPDriveCreateDisposition.open)

    #expect(drive.device.completion(for: driveRequest(
        fileID: root.fileID,
        major: RDPDriveMajorFunction.directoryControl,
        minor: RDPDriveMinorFunction.notifyChangeDirectory,
        body: Data(count: 32)
    )) == nil)
    let control = try #require(drive.device.completion(for: driveRequest(
        fileID: root.fileID,
        major: RDPDriveMajorFunction.deviceControl,
        body: Data(count: 32)
    )))
    #expect(control.status == RDPNTStatus.success)
    #expect(control.body == Data(count: 4))
    let volume = try #require(drive.device.completion(for: driveRequest(
        major: RDPDriveMajorFunction.queryVolumeInformation,
        body: volumeQueryBody(informationClass: RDPDriveVolumeInformationClass.size)
    )))
    #expect(volume.status == RDPNTStatus.success)
    #expect(volume.body.littleEndianUInt32(at: 0) == 24)
    #expect(drive.close(999).status == RDPDriveFailure.invalidHandle.status)
}

// MARK: Session

@Test func deviceRedirectionSessionAnnouncesDrivesAfterLogonAndServesThem() throws {
    let drive = try TemporaryDrive()
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPDeviceRedirectionSession(
        userChannelID: 1006,
        staticChannelID: 1004,
        channel: channel,
        computerName: "RDPKIT",
        drives: [RDPSharedDrive(name: "Docs", url: drive.root), RDPSharedDrive(name: "Gone", url: drive.base.appendingPathComponent("gone"))]
    )

    for packet: [UInt8] in [
        [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x50, 0x53],
        [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
    ] {
        #expect(try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet))).isEmpty)
    }
    let events = try session.receive(RDPDeviceRedirectionPDU.parse(from: Data([0x72, 0x44, 0x4C, 0x55])))
    #expect(events == [.driveUnavailable(name: "Gone")])

    var create = Data([0x72, 0x44, 0x52, 0x49])
    create.append(driveRequest(major: RDPDriveMajorFunction.create, body: createBody(
        path: "\\hello.txt",
        disposition: RDPDriveCreateDisposition.create
    )).encodedHeaderAndBody)
    try session.receive(RDPDeviceRedirectionPDU.parse(from: create))
    var unknownDevice = Data([0x72, 0x44, 0x52, 0x49])
    unknownDevice.append(driveRequest(deviceID: 2, major: RDPDriveMajorFunction.read, body: Data(count: 32)).encodedHeaderAndBody)
    try session.receive(RDPDeviceRedirectionPDU.parse(from: unknownDevice))
    session.waitForDriveIO()

    let sent = try sentDeviceRedirectionPDUs(channel)
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
    // The unknown device is answered on the connection thread, before the queued create.
    #expect(sent[5].payload.littleEndianUInt32(at: 8) == RDPNTStatus.unsuccessful)
    #expect(sent[6].payload.littleEndianUInt32(at: 8) == RDPNTStatus.success)
    #expect(FileManager.default.fileExists(atPath: drive.root.appendingPathComponent("hello.txt").path))
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

// MARK: Helpers

/// A shared folder in a temporary directory, removed when the test ends.
private final class TemporaryDrive {
    let base: URL
    let root: URL
    let device: RDPSharedDriveDevice

    init(descriptorBudget: RDPSharedDriveDescriptorBudget = RDPSharedDriveDescriptorBudget(maximumCount: 64)) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rdpkit-drive-\(UUID().uuidString)")
        root = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        device = RDPSharedDriveDevice(
            deviceID: 1,
            drive: RDPSharedDrive(name: "Shared", url: root),
            descriptorBudget: descriptorBudget
        )
        device.resolveRoot()
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    struct Reply {
        var status: UInt32
        var body: Data
        var fileID: UInt32 {
            body.count >= 4 ? body.littleEndianUInt32(at: 0) : 0
        }

        var information: UInt8? {
            body.count >= 5 ? body[body.startIndex + 4] : nil
        }
    }

    func create(_ path: String, disposition: UInt32, options: UInt32 = 0, access: UInt32 = 0x0012_019F) -> Reply {
        send(fileID: 0, major: RDPDriveMajorFunction.create, body: createBody(
            path: path,
            disposition: disposition,
            options: options,
            access: access
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

    private func send(fileID: UInt32, major: UInt32, minor: UInt32 = 0, body: Data) -> Reply {
        guard let completion = device.completion(for: driveRequest(fileID: fileID, major: major, minor: minor, body: body)) else {
            return Reply(status: 0xFFFF_FFFF, body: Data())
        }
        return Reply(status: completion.status, body: completion.body)
    }
}

private func driveRequest(
    deviceID: UInt32 = 1,
    fileID: UInt32 = 0,
    major: UInt32,
    minor: UInt32 = 0,
    body: Data
) -> RDPDeviceIORequest {
    RDPDeviceIORequest(deviceID: deviceID, fileID: fileID, completionID: 7, majorFunction: major, minorFunction: minor, body: body)
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

private func createBody(path: String, disposition: UInt32, options: UInt32 = 0, access: UInt32 = 0x0012_019F) -> Data {
    var pathData = Data(utf16LittleEndian: path)
    pathData.appendLittleEndianUInt16(0)
    var body = Data()
    body.appendLittleEndianUInt32(access)
    body.appendLittleEndianUInt64(0)
    body.appendLittleEndianUInt32(0)
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

private func sentDeviceRedirectionPDUs(_ channel: EmbeddedChannel) throws -> [RDPDeviceRedirectionPDU] {
    channel.embeddedEventLoop.run()
    var pdus: [RDPDeviceRedirectionPDU] = []
    var reassembler = RDPStaticVirtualChannelReassembler()
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        let packet = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
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
