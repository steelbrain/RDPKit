import Foundation
@testable import RDPKit
import Testing

/// The shared folder is a boundary: a redirected drive must expose exactly what the user shared and
/// nothing above it. The remote controls every path string, so these tests exercise the guard with
/// the shapes a hostile — or merely careless — server would send.
@Suite("RDPDriveShare path resolution")
struct DriveRedirectionPathTests {
    /// A share root containing `inside.txt`, plus `escape` -> the parent directory.
    private func makeShare() throws -> (share: RDPDriveShare, root: URL, outsideFile: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpkit-share-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outside = base.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: outside)
        try Data("public".utf8).write(to: root.appendingPathComponent("inside.txt"))

        // A symlink inside the share pointing at its parent - the classic escape, and something a
        // user can easily have in a directory they share without thinking about it.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: base
        )
        return (RDPDriveShare(path: root.path, label: "TEST"), root, outside)
    }

    private func resolve(_ share: RDPDriveShare, _ path: String) -> URL? {
        // `resolve` is private; exercise it through the public surface the remote actually drives.
        share.resolveForTesting(path)
    }

    @Test func aPathInsideTheShareResolves() throws {
        let (share, root, _) = try makeShare()
        let resolved = resolve(share, "\\inside.txt")
        #expect(resolved != nil)
        #expect(resolved?.lastPathComponent == "inside.txt")
        #expect(resolved?.path.hasPrefix(root.resolvingSymlinksInPath().path) == true)
    }

    @Test func aSymlinkOutOfTheShareIsRejected() throws {
        let (share, _, _) = try makeShare()
        // Without symlink resolution this returns a URL under the share's parent and the remote can
        // read or overwrite it: the guard is lexical, and FileHandle follows the link.
        #expect(resolve(share, "\\escape\\secret.txt") == nil,
                "a symlink inside the share must not grant access above it")
        #expect(resolve(share, "\\escape") == nil)
    }

    @Test func dotSegmentsAreRejected() throws {
        let (share, _, _) = try makeShare()
        #expect(resolve(share, "\\..\\secret.txt") == nil)
        #expect(resolve(share, "\\.\\inside.txt") == nil)
        #expect(resolve(share, "\\sub\\..\\..\\secret.txt") == nil)
    }

    @Test func theShareRootItselfResolves() throws {
        let (share, _, _) = try makeShare()
        #expect(resolve(share, "\\") != nil, "the root is a legitimate target for a directory query")
        #expect(resolve(share, "") != nil)
    }

    @Test func aRootBehindASymlinkStillAcceptsItsOwnChildren() throws {
        // On macOS NSTemporaryDirectory() commonly sits under /var -> /private/var, so resolving the
        // child but not the root would reject everything in a share created there.
        let (share, _, _) = try makeShare()
        #expect(resolve(share, "\\inside.txt") != nil)
    }
}
