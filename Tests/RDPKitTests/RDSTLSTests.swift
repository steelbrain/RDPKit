import Foundation
@testable import RDPKit
import Testing

/// The Authentication Request lays its fields out as FreeRDP 3.32's
/// rdstls_write_authentication_request_with_password does.
@Test func rdSTLSAuthenticationRequestCarriesTheRedirectionCredentials() throws {
    let password = utf16LENullTerminated("one-time")
    let request = try RDPRDSTLS.authenticationRequest(RDPRDSTLSPasswordCredentials(
        redirectionGuid: Data([0xAA, 0xBB]),
        username: "kq7Z",
        domain: "",
        password: password
    ))

    var expected = hexData("01 00 02 00 01 00 02 00 aa bb")
    expected.append(hexData("0a 00") + utf16LENullTerminated("kq7Z"))
    expected.append(hexData("02 00 00 00"))
    expected.append(hexData("12 00") + password)
    #expect(request == expected)
}

@Test func rdSTLSAuthenticationRequestRejectsAFieldTooLongForItsLength() {
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.authenticationRequest(RDPRDSTLSPasswordCredentials(
            redirectionGuid: Data(),
            username: "user",
            domain: "",
            password: Data(count: Int(UInt16.max) + 1)
        ))
    }
}

@Test func rdSTLSCapabilitiesMustOfferVersionOne() throws {
    try RDPRDSTLS.checkCapabilities(hexData("01 00 01 00 01 00 03 00"))
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.checkCapabilities(hexData("01 00 01 00 01 00 02 00"))
    }
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.checkCapabilities(hexData("01 00 04 00 01 00 01 00"))
    }
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.checkCapabilities(hexData("02 00 01 00 01 00 03 00"))
    }
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.checkCapabilities(hexData("01 00 01 00 02 00 01 00"))
    }
}

@Test func rdSTLSAuthenticationResponseGivesItsResultCode() throws {
    #expect(try RDPRDSTLS.authenticationResult(hexData("01 00 04 00 01 00 00 00 00 00")) == .success)
    #expect(try RDPRDSTLS.authenticationResult(hexData("01 00 04 00 01 00 2e 05 00 00")) == .logonFailure)
    #expect(RDPRDSTLSResultCode.logonFailure.description == "ERROR_LOGON_FAILURE (0x0000052e)")
    #expect(RDPRDSTLSResultCode(rawValue: 0x1234).description == "code 0x00001234")
    #expect(throws: RDPConnectionError.self) {
        try RDPRDSTLS.authenticationResult(hexData("01 00 01 00 01 00 00 00 00 00"))
    }
}

/// A server PDU's type sets its length: 8 bytes for Capabilities, 10 for the
/// Authentication Response.
@Test func rdSTLSFramingReadsTheLengthFromThePDUType() throws {
    func length(_ hex: String) throws -> Int? {
        let bytes = hexData(hex)
        return try RDPRDSTLS.serverPDULength(readableByteCount: bytes.count) { bytes[bytes.startIndex + $0] }
    }

    #expect(try length("01 00 01") == nil)
    #expect(try length("01 00 01 00") == 8)
    #expect(try length("01 00 04 00 01 00") == 10)
    #expect(throws: RDPConnectionError.self) {
        try length("01 00 02 00")
    }
}
