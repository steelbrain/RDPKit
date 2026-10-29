import Foundation
@testable import RDPKit
import Testing

private let arcRandomBits = Data((1 ... 16).map { UInt8($0 * 11) })

/// ARC_CS_PRIVATE_PACKET ([MS-RDPBCGR] 2.2.4.3). The SecurityVerifier was computed apart,
/// with Python's hmac module and `openssl mac`: HMAC-MD5 keyed with the ArcRandomBits
/// 0b 16 21 … b0 over 32 zero bytes, the client random under TLS and CredSSP.
@Test func autoReconnectCookieSignsTheClientRandomWithItsRandomBits() throws {
    let cookie = try #require(RDPAutoReconnectCookie(logonID: 0x1234_5678, arcRandomBits: arcRandomBits))

    #expect(arcRandomBits == hexData("0b 16 21 2c 37 42 4d 58 63 6e 79 84 8f 9a a5 b0"))
    #expect(cookie.securityVerifier == hexData("84 72 b7 1e 6b 17 b1 61 1a a0 55 6a 57 c3 48 42"))
    #expect(cookie.clientPacket == hexData("""
        1c 00 00 00 01 00 00 00 78 56 34 12
        84 72 b7 1e 6b 17 b1 61 1a a0 55 6a 57 c3 48 42
        """))
}

@Test func autoReconnectCookieNeedsSixteenRandomBytes() {
    #expect(RDPAutoReconnectCookie(logonID: 1, arcRandomBits: Data(count: 15)) == nil)
    #expect(RDPAutoReconnectCookie(logonID: 1, arcRandomBits: Data(count: 17)) == nil)
    #expect(RDPAutoReconnectCookie(logonID: 1, arcRandomBits: Data(count: 16))?.arcRandomBits == Data(count: 16))
}

/// cbAutoReconnectCookie, then the cookie, end the Extended Info Packet
/// ([MS-RDPBCGR] 2.2.1.11.1.1.1); without a cookie the length is 0.
@Test func clientInfoEndsWithTheAutoReconnectCookie() throws {
    let cookie = try #require(RDPAutoReconnectCookie(logonID: 0x1234_5678, arcRandomBits: arcRandomBits))
    let credentials = RDPCredentials(username: "rdp-user", domain: "LAB", password: "secret")
    let without = try RDPClientInfoPDU(credentials: credentials).encodedPDUData()
    let with = try RDPClientInfoPDU(credentials: credentials, autoReconnectCookie: cookie).encodedPDUData()

    #expect(without.suffix(2) == Data([0x00, 0x00]))
    #expect(with.prefix(without.count - 2) == without.prefix(without.count - 2))
    #expect(with.suffix(30) == hexData("1c 00") + cookie.clientPacket)
}

/// The cookie lets whoever holds it into the session, so logs and encoded reports
/// keep only its logon ID.
@Test func autoReconnectCookieLeavesItsRandomBitsOutOfDescriptionsAndEncoding() throws {
    let cookie = try #require(RDPAutoReconnectCookie(logonID: 7, arcRandomBits: arcRandomBits))
    let configuration = RDPConnectionConfiguration(host: "example.test", autoReconnectCookie: cookie)
    var report = RDPSessionClient().dryRun(configuration: configuration)
    report.rdpAutoReconnectCookie = cookie
    var dumped = ""
    dump(configuration, to: &dumped)
    dump(report, to: &dumped)
    let json = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)

    #expect(configuration.autoReconnectCookie == cookie)
    for text in [String(describing: cookie), String(reflecting: cookie), String(describing: configuration), dumped, json] {
        #expect(!text.contains(arcRandomBits.base64EncodedString()))
        #expect(!text.contains(arcRandomBits.rdpHexString))
        #expect(!text.contains("11, 22, 33"))
    }
    #expect(json.contains(#""rdpAutoReconnectCookie":{"logonID":7}"#))
}

/// The server may send a new cookie at any time; the report keeps the latest
/// ([MS-RDPBCGR] 5.5).
@Test func reportKeepsTheLatestAutoReconnectCookie() throws {
    let first = try #require(RDPAutoReconnectCookie(logonID: 2, arcRandomBits: arcRandomBits))
    let latest = try #require(RDPAutoReconnectCookie(logonID: 3, arcRandomBits: Data(arcRandomBits.reversed())))
    let run = try KRdpCapture.run(
        appending: [
            saveSessionInfo(with: first),
            saveSessionInfo(with: latest),
            KRdpCapture.emptyGraphicsFrame(id: 1),
        ],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpAutoReconnectCookie == latest)
}

/// A Save Session Info PDU with only an ARC_SC_PRIVATE_PACKET ([MS-RDPBCGR] 2.2.10.1.1.4).
private func saveSessionInfo(with cookie: RDPAutoReconnectCookie) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0003) // INFOTYPE_LOGON_EXTENDED_INF
    payload.appendLittleEndianUInt16(38) // Length
    payload.appendLittleEndianUInt32(0x0000_0001) // LOGON_EX_AUTORECONNECTCOOKIE
    payload.appendLittleEndianUInt32(28) // cbFieldData
    payload.appendLittleEndianUInt32(28) // cbLen
    payload.appendLittleEndianUInt32(1) // Version
    payload.appendLittleEndianUInt32(cookie.logonID)
    payload.append(cookie.arcRandomBits)
    payload.append(Data(repeating: 0, count: 570)) // Pad
    return KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x26, payload: payload))
}
