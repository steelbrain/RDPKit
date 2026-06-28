import Foundation
@testable import RDPKit
import Testing

// Fixtures captured from a live gnome-remote-desktop (GRD) server during this
// branch's debugging. These are real bytes off the wire, not hand-modelled, so
// they pin the client to GRD's actual behaviour rather than to our own
// assumptions about it — the gap that let the GNOME regressions land green.

@Test func parsesRealGnomeMCSConnectResponseChannelLayout() throws {
    // GRD assigns drdynvc and cliprdr as static channels plus a message channel
    // for connect-time auto-detect.
    let response = try MCSConnectResponse.parse(
        fromTPKT: gnomeHex("""
        03 00 00 72 02 f0 80 7f 66 68 0a 01 00 02 01 00 30 1a 02 01 22 02 01 03 \
        02 01 00 02 01 01 02 01 00 02 01 01 02 03 00 ff f8 02 01 02 04 44 00 05 \
        00 14 7c 00 01 2a 14 76 0a 01 01 00 01 c0 00 4d 63 44 6e 2e 01 0c 10 00 \
        05 00 08 00 03 00 00 00 00 00 00 00 03 0c 0c 00 eb 03 02 00 ec 03 ed 03 \
        02 0c 0c 00 00 00 00 00 00 00 00 00 04 0c 06 00 ee 03
        """),
        requestedChannels: [.drdynvc, .cliprdr]
    )

    #expect(response.result == 0)
    #expect(response.serverUserDataKey == "McDn")
    #expect(response.ioChannelID == 1003)
    #expect(response.messageChannelID == 1006)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1005),
    ])
}

@Test func realGnomeBandwidthMeasureStartParses() throws {
    // The exact auto-detect request GRD sends first, on the message channel
    // (1006), immediately after Client Info. The client must parse it as a
    // bandwidth-measure-start so it can decide not to reply.
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(
        fromTPKT: gnomeHex("03 00 00 19 02 f0 80 68 00 06 03 ee 70 80 0a 00 10 00 00 06 00 00 00 14 10")
    ))

    #expect(request.channelID == 1006)
    #expect(request.sequenceNumber == 0)
    #expect(request.requestType == 0x1014)
    #expect(request.requestTypeName == "bandwidth-measure-start")
    #expect(request.payloadByteCount == 0)
}

private func gnomeHex(_ string: String) -> Data {
    let scalars = string.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
    let characters = Array(scalars)
    precondition(characters.count.isMultiple(of: 2), "hex fixture must have an even digit count")

    var bytes = [UInt8]()
    bytes.reserveCapacity(characters.count / 2)
    var index = 0
    while index < characters.count {
        let pair = String(String.UnicodeScalarView(characters[index ..< index + 2]))
        guard let byte = UInt8(pair, radix: 16) else {
            preconditionFailure("invalid hex pair \(pair)")
        }
        bytes.append(byte)
        index += 2
    }
    return Data(bytes)
}
