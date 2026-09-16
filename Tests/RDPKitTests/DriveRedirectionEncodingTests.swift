import Foundation
@testable import RDPKit
import Testing

/// MS-RDPEFS puts *trimmed* versions of the MS-FSCC structures on the wire: several of them drop
/// the trailing or interior padding that the NT C definition includes. Getting one of those wrong
/// shifts every following field, and the failure is silent - Windows reads a corrupt name or length
/// and abandons the share with a generic error, with nothing in the exchange marked as an error.
/// That cost three separate debugging rounds, so the sizes are pinned here byte for byte.
@Suite("RDPDriveShare wire encoding")
struct DriveRedirectionEncodingTests {
    private func makeShare() throws -> (share: RDPDriveShare, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpkit-enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        return (RDPDriveShare(path: root.path, label: "TEST"), root)
    }

    /// Build the body of a Device I/O Request and run it through `handle`.
    private func request(
        major: UInt32, minor: UInt32 = 0, fileID: UInt32 = 0, body: Data, on share: RDPDriveShare
    ) -> (status: UInt32, payload: Data)? {
        var cursor = ByteCursor(body)
        let io = RDPDriveIORequest(
            deviceID: 1, fileID: fileID, completionID: 0, majorFunction: major, minorFunction: minor
        )
        return share.handle(io, body: &cursor)
    }

    /// Open an existing file by name and return its FileId.
    private func openExisting(_ share: RDPDriveShare, name: String) throws -> UInt32 {
        var body = Data()
        body.appendLittleEndianUInt32(0x0000_0080)
        body.appendLittleEndianUInt64(0)
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt32(7)
        body.appendLittleEndianUInt32(1)                      // FILE_OPEN
        body.appendLittleEndianUInt32(0x0000_0040)            // FILE_NON_DIRECTORY_FILE
        let path = Array(name.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        body.appendLittleEndianUInt32(UInt32(path.count))
        body.append(contentsOf: path)
        let created = try #require(request(major: 0x0000_0000, body: body, on: share))
        var cursor = ByteCursor(created.payload)
        return try cursor.readLittleEndianUInt32()
    }

    private func createRoot(_ share: RDPDriveShare, options: UInt32 = 0x0000_0001) throws -> UInt32 {
        var body = Data()
        body.appendLittleEndianUInt32(0x0000_0080)   // DesiredAccess
        body.appendLittleEndianUInt64(0)             // AllocationSize
        body.appendLittleEndianUInt32(0)             // FileAttributes
        body.appendLittleEndianUInt32(7)             // SharedAccess
        body.appendLittleEndianUInt32(1)             // CreateDisposition: FILE_OPEN
        body.appendLittleEndianUInt32(options)       // CreateOptions
        body.appendLittleEndianUInt32(0)             // PathLength
        let reply = try #require(request(major: 0x0000_0000, body: body, on: share))
        #expect(reply.status == 0)
        var cursor = ByteCursor(reply.payload)
        return try cursor.readLittleEndianUInt32()   // FileId
    }

    private func queryInformation(_ share: RDPDriveShare, fileID: UInt32, infoClass: UInt32) throws -> Int {
        var body = Data()
        body.appendLittleEndianUInt32(infoClass)
        body.appendLittleEndianUInt32(0)             // Length
        body.append(Data(count: 24))                 // Padding
        let reply = try #require(request(major: 0x0000_0005, fileID: fileID, body: body, on: share))
        #expect(reply.status == 0)
        var cursor = ByteCursor(reply.payload)
        return Int(try cursor.readLittleEndianUInt32())
    }

    @Test func fileStandardInformationIs22BytesNotTheNTStructs24() throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)
        // 8 + 8 + 4 + 1 + 1: MS-RDPEFS 2.2.3.3.8 omits the struct's 2-byte Reserved tail.
        #expect(try queryInformation(share, fileID: fileID, infoClass: 5) == 22)
    }

    @Test func fileBasicInformationIs36BytesNotTheNTStructs40() throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)
        // Four 8-byte timestamps + FileAttributes, with no trailing Reserved.
        #expect(try queryInformation(share, fileID: fileID, infoClass: 4) == 36)
    }

    /// The one that broke `\\tsclient` listing: FILE_BOTH_DIR_INFORMATION goes out at 93 bytes plus
    /// the name, not the NT struct's 94 - there is no Reserved byte after ShortNameLength.
    @Test(arguments: [
        (infoClass: UInt32(1), header: 64),    // FileDirectoryInformation
        (infoClass: UInt32(2), header: 68),    // FileFullDirectoryInformation
        (infoClass: UInt32(3), header: 93),    // FileBothDirectoryInformation
        (infoClass: UInt32(12), header: 12),   // FileNamesInformation
    ])
    func directoryEntryHeaderSize(infoClass: UInt32, header: Int) throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)

        var body = Data()
        body.appendLittleEndianUInt32(infoClass)
        body.appendUInt8(1)                          // InitialQuery
        body.appendLittleEndianUInt32(4)             // PathLength
        body.append(Data(count: 23))                 // Padding
        body.append(Data([0x5c, 0x00, 0x2a, 0x00]))  // Path "\*"
        let reply = try #require(request(major: 0x0000_000C, minor: 1, fileID: fileID, body: body, on: share))
        #expect(reply.status == 0)

        var cursor = ByteCursor(reply.payload)
        let length = Int(try cursor.readLittleEndianUInt32())
        let entry = try cursor.readData(count: length)
        // The first entry is always ".", so the name is one UTF-16 code unit.
        let nameLength = infoClass == 12
            ? Int(entry.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
            : Int(entry.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self).littleEndian })
        #expect(nameLength == 2, "the leading entry must be \".\"")
        #expect(length == header + nameLength)
    }

    /// `.` and `..` must lead the listing: Windows needs them to establish the directory node, and
    /// `contentsOfDirectory` does not report them.
    @Test func enumerationLeadsWithDotAndDotDot() throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)

        func next(initial: UInt8) throws -> String {
            var body = Data()
            body.appendLittleEndianUInt32(3)
            body.appendUInt8(initial)
            body.appendLittleEndianUInt32(4)
            body.append(Data(count: 23))
            body.append(Data([0x5c, 0x00, 0x2a, 0x00]))
            let reply = try #require(request(major: 0x0000_000C, minor: 1, fileID: fileID, body: body, on: share))
            var cursor = ByteCursor(reply.payload)
            let length = Int(try cursor.readLittleEndianUInt32())
            let entry = try cursor.readData(count: length)
            let nameLength = Int(entry.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self).littleEndian
            })
            return String(data: entry.suffix(nameLength), encoding: .utf16LittleEndian) ?? ""
        }

        #expect(try next(initial: 1) == ".")
        #expect(try next(initial: 0) == "..")
        #expect(try next(initial: 0) == "a.txt")
    }

    /// `send` must fragment, not trap: the single-PDU initialiser enforces its size limit with a
    /// precondition that is live in release builds, so an unchunked large read killed the process.
    @Test func largePayloadsFragmentAcrossChunks() {
        let payload = Data(repeating: 0xab, count: 5_000)
        let chunks = RDPStaticVirtualChannelPDU.chunks(forPayload: payload, chunkByteCount: 1_600)
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.totalLength == 5_000 })
        #expect(chunks[0].flags & RDPStaticVirtualChannelFlags.first != 0)
        #expect(chunks[0].flags & RDPStaticVirtualChannelFlags.last == 0)
        #expect(chunks[3].flags & RDPStaticVirtualChannelFlags.last != 0)
        #expect(chunks[3].flags & RDPStaticVirtualChannelFlags.first == 0)
        #expect(chunks.reduce(Data()) { $0 + $1.payload } == payload)
        #expect(chunks.allSatisfy { $0.payload.count <= 1_600 })
    }

    @Test func aPayloadThatFitsInOneChunkCarriesBothFlags() {
        let chunks = RDPStaticVirtualChannelPDU.chunks(
            forPayload: Data(repeating: 1, count: 64), chunkByteCount: 1_600
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].flags == RDPStaticVirtualChannelFlags.complete)
        #expect(chunks[0].canDispatchPayload)
    }

    /// RDP_FILE_RENAME_INFORMATION has a 1-byte RootDirectory, not the NT struct's 8-byte HANDLE.
    /// Explorer creates a folder as "New folder" and renames it, so a broken rename reads as
    /// "cannot create folders".
    @Test func renameUsesTheOneByteRootDirectoryField() throws {
        let (share, root) = try makeShare()
        let fileID = try createRoot(share)

        let newName = Array("\\renamed.txt".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        var info = Data()
        info.appendUInt8(1)                                     // ReplaceIfExists
        info.appendUInt8(0)                                     // RootDirectory - ONE byte
        info.appendLittleEndianUInt32(UInt32(newName.count))    // FileNameLength
        info.append(contentsOf: newName)

        // Reopen a.txt so the rename has a real target.
        var createBody = Data()
        createBody.appendLittleEndianUInt32(0x0000_0080)
        createBody.appendLittleEndianUInt64(0)
        createBody.appendLittleEndianUInt32(0)
        createBody.appendLittleEndianUInt32(7)
        createBody.appendLittleEndianUInt32(1)                  // FILE_OPEN
        createBody.appendLittleEndianUInt32(0)
        let path = Array("\\a.txt".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        createBody.appendLittleEndianUInt32(UInt32(path.count))
        createBody.append(contentsOf: path)
        let created = try #require(request(major: 0x0000_0000, body: createBody, on: share))
        #expect(created.status == 0)
        var idCursor = ByteCursor(created.payload)
        let targetID = try idCursor.readLittleEndianUInt32()

        var body = Data()
        body.appendLittleEndianUInt32(10)                       // FileRenameInformation
        body.appendLittleEndianUInt32(UInt32(info.count))       // Length
        body.append(Data(count: 24))                            // Padding
        body.append(info)
        let reply = try #require(request(major: 0x0000_0006, fileID: targetID, body: body, on: share))

        #expect(reply.status == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path) == false)
        _ = fileID

        // DR_DRIVE_SET_INFORMATION_RSP echoes the request's Length, not zero.
        var lengthCursor = ByteCursor(reply.payload)
        #expect(try lengthCursor.readLittleEndianUInt32() == UInt32(info.count))
    }

    /// Explorer decides whether an item is a folder by opening it with FILE_DIRECTORY_FILE. Saying
    /// yes for a regular file makes it render that file as a folder - 0 bytes, "0 files, 0 folders".
    @Test func openingAFileAsADirectoryIsRejected() throws {
        let (share, _) = try makeShare()

        func open(_ name: String, options: UInt32) throws -> UInt32 {
            var body = Data()
            body.appendLittleEndianUInt32(0x0000_0080)
            body.appendLittleEndianUInt64(0)
            body.appendLittleEndianUInt32(0)
            body.appendLittleEndianUInt32(7)
            body.appendLittleEndianUInt32(1)          // FILE_OPEN
            body.appendLittleEndianUInt32(options)
            let path = Array(name.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            body.appendLittleEndianUInt32(UInt32(path.count))
            body.append(contentsOf: path)
            return try #require(request(major: 0x0000_0000, body: body, on: share)).status
        }

        // FILE_DIRECTORY_FILE against a regular file.
        #expect(try open("\\a.txt", options: 0x0000_0001) == 0xC000_0103)   // STATUS_NOT_A_DIRECTORY
        // FILE_NON_DIRECTORY_FILE against the share root.
        #expect(try open("", options: 0x0000_0040) == 0xC000_00BA)            // STATUS_FILE_IS_A_DIRECTORY
        // The matching combinations still succeed.
        #expect(try open("\\a.txt", options: 0x0000_0040) == 0)
        #expect(try open("", options: 0x0000_0001) == 0)
    }

    /// Windows serves a by-name attribute lookup by enumerating the parent with the file's own name
    /// as the search pattern. Ignoring the pattern hands it entry zero - "." - so it concludes the
    /// file is a zero-byte directory and puts a folder property sheet on a document.
    @Test func aNameScopedQueryReturnsThatFileNotDot() throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)

        func query(_ pattern: String, initial: UInt8 = 1) throws -> (status: UInt32, name: String) {
            let path = Array(pattern.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            var body = Data()
            body.appendLittleEndianUInt32(3)                    // FileBothDirectoryInformation
            body.appendUInt8(initial)
            body.appendLittleEndianUInt32(UInt32(path.count))
            body.append(Data(count: 23))
            body.append(contentsOf: path)
            let reply = try #require(request(major: 0x0000_000C, minor: 1, fileID: fileID, body: body, on: share))
            guard reply.status == 0 else { return (reply.status, "") }
            var cursor = ByteCursor(reply.payload)
            let length = Int(try cursor.readLittleEndianUInt32())
            let entry = try cursor.readData(count: length)
            let nameLength = Int(entry.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 60, as: UInt32.self).littleEndian
            })
            let attrs = entry.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 56, as: UInt32.self).littleEndian
            }
            // FILE_BOTH_DIR_INFORMATION: EndOfFile at 40, AllocationSize 48, FileAttributes 56.
            let eof = entry.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self).littleEndian
            }
            #expect(attrs & 0x10 == 0, "a file must not carry FILE_ATTRIBUTE_DIRECTORY")
            #expect(eof == 5, "a.txt holds \"hello\"")
            return (0, String(data: entry.suffix(nameLength), encoding: .utf16LittleEndian) ?? "")
        }

        #expect(try query("\\a.txt").name == "a.txt")
        #expect(try query("\\A.TXT").name == "a.txt", "matching is case-insensitive")
        #expect(try query("\\*.txt").name == "a.txt", "wildcards still select")
        // A first query that matches nothing is STATUS_NO_SUCH_FILE, not an empty success.
        #expect(try query("\\nope.txt").status == 0xC000_000F)
    }

    /// The exact packet that broke copying a file into the share: Windows sends a 1 MB write as a
    /// fragmented message whose first chunk carries CHANNEL_FLAG_FIRST alone. CHANNEL_FLAG_SHOW_
    /// PROTOCOL reflects CHANNEL_OPTION_SHOW_PROTOCOL on the channel (MS-RDPBCGR 2.2.6.1.1) and is
    /// not a precondition for fragmentation, but `parse` demanded it and threw - one layer below
    /// the reassembler, so no inbound message larger than one chunk ever reached it.
    @Test func aFragmentWithoutShowProtocolIsAccepted() throws {
        var userData = Data()
        userData.appendLittleEndianUInt32(1_048_632)                      // totalLength
        userData.appendLittleEndianUInt32(RDPStaticVirtualChannelFlags.first)
        userData.append(Data(repeating: 0xcd, count: 1_600))              // chunk

        let lenient = try RDPStaticVirtualChannelPDU.parse(
            fromUserData: userData,
            maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount,
            requiresShowProtocol: false
        )
        #expect(lenient.totalLength == 1_048_632)
        #expect(lenient.payload.count == 1_600)
        #expect(lenient.canDispatchPayload == false, "a lone fragment is not dispatchable on its own")

        // The strict default is unchanged, so drdynvc keeps rejecting it.
        #expect(throws: (any Error).self) {
            try RDPStaticVirtualChannelPDU.parse(
                fromUserData: userData,
                maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount
            )
        }
    }

    /// End to end: fragments without SHOW_PROTOCOL reassemble into the original message.
    @Test func fragmentsWithoutShowProtocolReassemble() throws {
        let message = Data((0 ..< 5_000).map { UInt8($0 % 251) })
        let chunks = RDPStaticVirtualChannelPDU.chunks(forPayload: message, chunkByteCount: 1_600)
        let inbound = RDPStaticVirtualChannelInbound()

        var completed: RDPStaticVirtualChannelPDU?
        for chunk in chunks {
            var userData = Data()
            userData.appendLittleEndianUInt32(chunk.totalLength)
            userData.appendLittleEndianUInt32(chunk.flags)
            userData.append(chunk.payload)
            let parsed = try RDPStaticVirtualChannelPDU.parse(
                fromUserData: userData,
                maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount,
                requiresShowProtocol: false
            )
            completed = try inbound.accept(
                parsed, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount
            )
        }
        #expect(completed?.payload == message)
    }

    /// `Length` in DR_DRIVE_READ_REQ is chosen by the remote and can reach 4 GiB. It sizes an
    /// allocation from a local file rather than from the bytes received, so it needs a ceiling.
    @Test func anAbsurdReadLengthIsClampedRatherThanAllocated() throws {
        let (share, root) = try makeShare()
        try Data(repeating: 0x5a, count: 4_096).write(to: root.appendingPathComponent("big.bin"))

        var createBody = Data()
        createBody.appendLittleEndianUInt32(0x0000_0080)
        createBody.appendLittleEndianUInt64(0)
        createBody.appendLittleEndianUInt32(0)
        createBody.appendLittleEndianUInt32(7)
        createBody.appendLittleEndianUInt32(1)              // FILE_OPEN
        createBody.appendLittleEndianUInt32(0x0000_0040)    // FILE_NON_DIRECTORY_FILE
        let path = Array("\\big.bin".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        createBody.appendLittleEndianUInt32(UInt32(path.count))
        createBody.append(contentsOf: path)
        let created = try #require(request(major: 0x0000_0000, body: createBody, on: share))
        #expect(created.status == 0)
        var idCursor = ByteCursor(created.payload)
        let fileID = try idCursor.readLittleEndianUInt32()

        // Ask for the whole 32-bit range against a 4 KiB file.
        var readBody = Data()
        readBody.appendLittleEndianUInt32(UInt32.max)       // Length
        readBody.appendLittleEndianUInt64(0)                // Offset
        readBody.append(Data(count: 20))                    // Padding
        let reply = try #require(request(major: 0x0000_0003, fileID: fileID, body: readBody, on: share))

        #expect(reply.status == 0)
        var cursor = ByteCursor(reply.payload)
        let returned = try cursor.readLittleEndianUInt32()
        #expect(returned == 4_096, "a short read is legal; the reply carries its own Length")
        #expect(reply.payload.count == 4 + 4_096)
    }

    /// The previous test cannot fail if the clamp is deleted: a 4 KiB file returns 4 KiB either way.
    /// This one needs a file LARGER than the cap, so the clamp is the only thing bounding the reply.
    @Test func aReadLargerThanTheCapIsTruncatedToIt() throws {
        let (share, root) = try makeShare()
        let cap = RDPDriveShare.maximumReadByteCount
        let big = root.appendingPathComponent("huge.bin")
        try Data(repeating: 0x7a, count: cap + 4_096).write(to: big)

        var createBody = Data()
        createBody.appendLittleEndianUInt32(0x0000_0080)
        createBody.appendLittleEndianUInt64(0)
        createBody.appendLittleEndianUInt32(0)
        createBody.appendLittleEndianUInt32(7)
        createBody.appendLittleEndianUInt32(1)
        createBody.appendLittleEndianUInt32(0x0000_0040)
        let path = Array("\\huge.bin".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        createBody.appendLittleEndianUInt32(UInt32(path.count))
        createBody.append(contentsOf: path)
        let created = try #require(request(major: 0x0000_0000, body: createBody, on: share))
        var idCursor = ByteCursor(created.payload)
        let fileID = try idCursor.readLittleEndianUInt32()

        var readBody = Data()
        readBody.appendLittleEndianUInt32(UInt32.max)
        readBody.appendLittleEndianUInt64(0)
        readBody.append(Data(count: 20))
        let reply = try #require(request(major: 0x0000_0003, fileID: fileID, body: readBody, on: share))
        var cursor = ByteCursor(reply.payload)
        #expect(try cursor.readLittleEndianUInt32() == UInt32(cap),
                "a remote-chosen Length must not size the allocation")
        try? FileManager.default.removeItem(at: big)
    }

    /// A delete-on-close on a directory with contents must be refused at the disposition set, as
    /// NTFS does - not honoured at close, where `removeItem` would take the whole tree with it.
    @Test func deleteOnCloseRefusesANonEmptyDirectoryAndTheShareRoot() throws {
        let (share, root) = try makeShare()
        let sub = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: sub.appendingPathComponent("file.txt"))

        func setDisposition(fileID: UInt32) throws -> UInt32 {
            var body = Data()
            body.appendLittleEndianUInt32(13)                 // FileDispositionInformation
            body.appendLittleEndianUInt32(1)                  // Length
            body.append(Data(count: 24))                      // Padding
            body.appendUInt8(1)                               // DeletePending
            return try #require(request(major: 0x0000_0006, fileID: fileID, body: body, on: share)).status
        }

        // A directory with contents.
        var createBody = Data()
        createBody.appendLittleEndianUInt32(0x0000_0080)
        createBody.appendLittleEndianUInt64(0)
        createBody.appendLittleEndianUInt32(0)
        createBody.appendLittleEndianUInt32(7)
        createBody.appendLittleEndianUInt32(1)
        createBody.appendLittleEndianUInt32(0x0000_0001)      // FILE_DIRECTORY_FILE
        let path = Array("\\keep".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        createBody.appendLittleEndianUInt32(UInt32(path.count))
        createBody.append(contentsOf: path)
        let created = try #require(request(major: 0x0000_0000, body: createBody, on: share))
        var idCursor = ByteCursor(created.payload)
        let dirID = try idCursor.readLittleEndianUInt32()
        #expect(try setDisposition(fileID: dirID) == 0xC000_0101, "STATUS_DIRECTORY_NOT_EMPTY")

        // And the share root itself, whatever it contains.
        let rootID = try createRoot(share)
        #expect(try setDisposition(fileID: rootID) == 0xC000_0022, "the share root is never deletable")

        // Close both; nothing may have been removed.
        for id in [dirID, rootID] {
            _ = request(major: 0x0000_0002, fileID: id, body: Data(count: 32), on: share)
        }
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("file.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// macOS volumes are case-insensitive, so "a.txt" and "A.txt" are one file. Removing "the
    /// existing target" first unlinks the very file about to be moved.
    @Test func aCaseOnlyRenameKeepsTheFile() throws {
        let (share, root) = try makeShare()
        let fileID = try openExisting(share, name: "\\a.txt")

        let newName = Array("\\A.TXT".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        var info = Data()
        info.appendUInt8(1)                                   // ReplaceIfExists
        info.appendUInt8(0)                                   // RootDirectory
        info.appendLittleEndianUInt32(UInt32(newName.count))
        info.append(contentsOf: newName)
        var body = Data()
        body.appendLittleEndianUInt32(10)                     // FileRenameInformation
        body.appendLittleEndianUInt32(UInt32(info.count))
        body.append(Data(count: 24))
        body.append(info)
        let reply = try #require(request(major: 0x0000_0006, fileID: fileID, body: body, on: share))

        #expect(reply.status == 0)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.contains { $0.lowercased() == "a.txt" }, "the file must still exist")
    }

    /// Writing through a read-only handle must be refused, not attempted: the legacy FileHandle
    /// write raises an Objective-C exception that no Swift catch can intercept, aborting the process.
    @Test func aWriteToAReadOnlyFileIsRefusedRatherThanAttempted() throws {
        let (share, root) = try makeShare()
        let locked = root.appendingPathComponent("locked.txt")
        try Data("read only".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let fileID = try openExisting(share, name: "\\locked.txt")
        var body = Data()
        body.appendLittleEndianUInt32(4)                      // Length
        body.appendLittleEndianUInt64(0)                      // Offset
        body.append(Data(count: 20))                          // Padding
        body.append(Data("boom".utf8))
        let reply = try #require(request(major: 0x0000_0004, fileID: fileID, body: body, on: share))

        #expect(reply.status == 0xC000_0022, "STATUS_ACCESS_DENIED")
        // Every DR_DRIVE_WRITE_RSP carries Length + padding, failure included.
        #expect(reply.payload.count == 5)
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read only")
    }

    /// A change-notification IRP stays outstanding; answering it retires the directory handle and
    /// Explorer stops before it ever asks for a single entry.
    @Test func notifyChangeDirectoryIsLeftPending() throws {
        let (share, _) = try makeShare()
        let fileID = try createRoot(share)
        #expect(request(major: 0x0000_000C, minor: 2, fileID: fileID, body: Data(), on: share) == nil)
    }
}
