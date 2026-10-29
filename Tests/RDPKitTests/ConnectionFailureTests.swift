import Foundation
@testable import RDPKit
import Testing

// The typed reasons a report and `RDPConnectionError` give; the mock server
// and KRdp capture tests check that sessions end with them.

/// Set Error Info codes are named and grouped as [MS-RDPBCGR] 2.2.5.1.1 lists them.
@Test(arguments: [
    (0x0000_0001, "ERRINFO_RPC_INITIATED_DISCONNECT", .admin),
    (0x0000_0002, "ERRINFO_RPC_INITIATED_LOGOFF", .admin),
    (0x0000_0003, "ERRINFO_IDLE_TIMEOUT", .timeLimit),
    (0x0000_0004, "ERRINFO_LOGON_TIMEOUT", .timeLimit),
    (0x0000_0005, "ERRINFO_DISCONNECTED_BY_OTHERCONNECTION", .replaced),
    (0x0000_0006, "ERRINFO_OUT_OF_MEMORY", .serverError),
    (0x0000_0007, "ERRINFO_SERVER_DENIED_CONNECTION", .accessDenied),
    (0x0000_0009, "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES", .accessDenied),
    (0x0000_000A, "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED", .freshCredentialsRequired),
    (0x0000_000B, "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER", .user),
    (0x0000_000C, "ERRINFO_LOGOFF_BY_USER", .user),
    (0x0000_0010, "ERRINFO_SERVER_DWM_CRASH", .serverError),
    (0x0000_001A, "ERRINFO_SERVER_REBOOT", .admin),
    (0x0000_0100, "ERRINFO_LICENSE_INTERNAL", .licensing),
    (0x0000_010A, "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS", .licensing),
    (0x0000_0408, "ERRINFO_CB_DESTINATION_POOL_NOT_FREE", .serverError),
    (0x0000_10C9, "ERRINFO_UNKNOWNPDUTYPE2", .protocolError),
    (0x0000_10CB, "ERRINFO_DATAPDUSEQUENCE", .protocolError),
    (0x0000_10E3, "ERRINFO_BADSUPRESSOUTPUTPDU", .protocolError),
    (0x0000_112C, "ERRINFO_BAD_FRAME_ACK_DATA", .protocolError),
    (0x0000_1194, "ERRINFO_ENCPKGMISMATCH", .protocolError),
    (0x0000_1195, "ERRINFO_DECRYPTFAILED2", .protocolError),
    (0x0000_10CC, "ERRINFO_0x000010cc", .protocolError),
    (0x0000_0008, "ERRINFO_0x00000008", .unknown),
    (0x0000_1196, "ERRINFO_0x00001196", .unknown),
] as [(UInt32, String, RDPRemoteTermination.Category)])
func setErrorInfoCodesAreNamedAndCategorized(code: UInt32, name: String, category: RDPRemoteTermination.Category) {
    let termination = RDPRemoteTermination(errorInfo: code, disconnectReason: 3)

    #expect(termination.errorInfoName == name)
    #expect(termination.category == category)
    #expect(termination.description == "server ended the session with \(name)")
}

/// [MS-RDPBCGR] 2.2.5.1.1 names 78 of the RDP-specific codes, 0x10C9-0x1195;
/// the rest of the range has no name.
@Test func everyRDPSpecificCodeTheSpecListsIsNamed() {
    let named = (UInt32(0x10C9) ... 0x1195).filter {
        RDPRemoteTermination(errorInfo: $0).errorInfoName?.hasPrefix("ERRINFO_0x") == false
    }

    #expect(named.count == 78)
    #expect(named.first == 0x10C9)
    #expect(named.last == 0x1195)
    #expect(!named.contains(0x10CC))
    #expect(!named.contains(0x1137))
}

/// Without Set Error Info, only an rn-user-requested ultimatum is a deliberate end.
@Test func disconnectReasonAloneIsUnspecifiedOrUnknown() {
    #expect(RDPRemoteTermination(disconnectReason: 3).category == .unspecified)
    #expect(RDPRemoteTermination(disconnectReason: 3).isNormalEnd)
    #expect(RDPRemoteTermination(disconnectReason: 1).category == .unknown)
    #expect(!RDPRemoteTermination(disconnectReason: 1).isNormalEnd)
    #expect(RDPRemoteTermination(disconnectReason: 1).description == "server ended the session with rn-provider-initiated")
    #expect(RDPRemoteTermination().category == .unknown)
}

@Test func onlyTheUserAdministratorsTimeLimitsAndTakeoversEndASessionNormally() {
    let normal = [0x1, 0x2, 0x3, 0x4, 0x5, 0xB, 0xC, 0x19, 0x1A] as [UInt32]
    let failures = [0x6, 0x7, 0x9, 0xA, 0x10, 0x101, 0x400, 0x10D3, 0x8] as [UInt32]

    #expect(normal.allSatisfy { RDPRemoteTermination(errorInfo: $0).isNormalEnd })
    #expect(!failures.contains { RDPRemoteTermination(errorInfo: $0).isNormalEnd })
}

@Test func reportDerivesTheTerminationAndStage() {
    var report = RDPSessionClient().dryRun(configuration: RDPConnectionConfiguration(host: "server"))
    #expect(report.connectionStage == nil)
    #expect(report.remoteTermination == nil)

    report.stage = "credssp"
    report.rdpRemoteTerminationErrorInfo = 0x0000_0003
    #expect(report.connectionStage == .credSSP)
    #expect(report.remoteTermination == RDPRemoteTermination(errorInfo: 0x0000_0003))
    #expect(report.remoteTermination?.category == .timeLimit)
}

@Test(arguments: [
    (ECONNREFUSED, .refused),
    (EHOSTUNREACH, .hostUnreachable),
    (EHOSTDOWN, .hostUnreachable),
    (ENETUNREACH, .networkUnreachable),
    (ENETDOWN, .networkUnreachable),
    (ETIMEDOUT, .timedOut),
    (EACCES, .notPermitted),
    (EPERM, .notPermitted),
    (ECONNRESET, .other),
] as [(Int32, RDPSocketError.Category)])
func socketErrorsAreCategorizedByErrno(errno: Int32, category: RDPSocketError.Category) {
    #expect(RDPSocketError(errno: errno).category == category)
}

@Test func socketErrorWithoutErrnoIsOther() {
    #expect(RDPSocketError(errno: nil).category == .other)
}

/// RDP_NEG_FAILURE codes ([MS-RDPBCGR] 2.2.1.2.2); later codes keep their number.
@Test func negotiationFailureCodesAreNamed() {
    let names = (1 ... 6).map { RDPNegotiationFailureCode(rawValue: $0).name }

    #expect(names == [
        "SSL_REQUIRED_BY_SERVER",
        "SSL_NOT_ALLOWED_BY_SERVER",
        "SSL_CERT_NOT_ON_SERVER",
        "INCONSISTENT_FLAGS",
        "HYBRID_REQUIRED_BY_SERVER",
        "SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER",
    ])
    #expect(RDPNegotiationFailureCode.hybridRequiredByServer.description == "HYBRID_REQUIRED_BY_SERVER (0x00000005)")
    #expect(RDPNegotiationFailureCode(rawValue: 7).name == nil)
    #expect(RDPNegotiationFailureCode(rawValue: 7).description == "code 0x00000007")
}

@Test func credSSPErrorsMapToFailures() {
    #expect(RDPCredSSPError.serverError(0xC000_0234).failure == .credSSP(status: .accountLockedOut))
    #expect(RDPCredSSPError.serverError(0xC000_0001).failure == .credSSP(status: RDPLogonStatus(rawValue: 0xC000_0001)))
    #expect(RDPCredSSPError.missingCredentials.failure == .credentialsRequired)
    #expect(RDPCredSSPError.serverBindingMismatch.failure == .protocolViolation)
    #expect(RDPCredSSPError.ntlm("invalid NTLM challenge message").failure == .protocolViolation)
    #expect(RDPCredSSPError.credentialsTooLong.failure == .invalidConfiguration)
    #expect(RDPCredSSPError.ntlmClient("failed to generate random bytes: -1").failure == .clientFailure)
    #expect(RDPLogonStatus.passwordMustChange.name == "STATUS_PASSWORD_MUST_CHANGE")
    #expect(RDPLogonStatus(rawValue: 0xC000_0001).name == nil)
}

/// RDPPreflight prints reports as JSON; the failure keeps its codes there.
@Test func failureEncodesItsCaseAndDetails() throws {
    func json(_ failure: RDPConnectionFailure) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try String(decoding: encoder.encode(failure), as: UTF8.self)
    }

    #expect(try json(.timedOut) == #"{"timedOut":{}}"#)
    #expect(try json(.invalidConfiguration) == #"{"invalidConfiguration":{}}"#)
    #expect(try json(.clientFailure) == #"{"clientFailure":{}}"#)
    #expect(try json(.credSSP(status: .logonFailure)) == #"{"credSSP":{"status":3221225581}}"#)
    #expect(try json(.connect(error: RDPSocketError(errno: ECONNREFUSED)))
        == #"{"connect":{"error":{"category":"refused","errno":61}}}"#)
    #expect(try json(.serverTermination(termination: RDPRemoteTermination(errorInfo: 5)))
        == #"{"serverTermination":{"termination":{"errorInfo":5}}}"#)
}
