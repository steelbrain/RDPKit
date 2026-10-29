@testable import RDPKit
import Testing

@Test func qualifiedUsernameOmitsEmptyDomain() {
    let credentials = RDPCredentials(username: "rdp-user", domain: "", password: "secret")

    #expect(credentials.qualifiedUsername == "rdp-user")
}

@Test func qualifiedUsernameIncludesDomainWhenPresent() {
    let credentials = RDPCredentials(username: "rdp-user", domain: "KDE", password: "secret")

    #expect(credentials.qualifiedUsername == "KDE\\rdp-user")
}

@Test func credentialValidationReturnsNilWhenFieldsAreEmpty() throws {
    let credentials = try RDPCredentials.validated(username: "  ", domain: "  ", password: "")

    #expect(credentials == nil)
}

@Test func credentialValidationTrimsUsernameAndDomain() throws {
    let validatedCredentials = try RDPCredentials.validated(
        username: "  rdp-user  ",
        domain: "  KDE  ",
        password: "secret"
    )
    let credentials = try #require(validatedCredentials)

    #expect(credentials.username == "rdp-user")
    #expect(credentials.domain == "KDE")
    #expect(credentials.password == "secret")
}

@Test func credentialValidationDropsEmptyDomain() throws {
    let validatedCredentials = try RDPCredentials.validated(
        username: "rdp-user",
        domain: "  ",
        password: "secret"
    )
    let credentials = try #require(validatedCredentials)

    #expect(credentials.domain == nil)
    #expect(credentials.qualifiedUsername == "rdp-user")
}

@Test func credentialDescriptionsRedactPassword() {
    let credentials = RDPCredentials(username: "rdp-user", domain: "KDE", password: "hunter2")
    let configuration = RDPConnectionConfiguration(host: "example.com", credentials: credentials)
    var dumped = ""
    dump(configuration, to: &dumped)

    for text in [
        String(describing: credentials),
        String(reflecting: credentials),
        String(describing: configuration),
        String(reflecting: configuration),
        dumped,
    ] {
        #expect(text.contains("rdp-user"))
        #expect(!text.contains("hunter2"))
    }
}

@Test func credentialValidationRejectsIncompleteCredentials() {
    #expect(
        throws: RDPCredentialValidationError.missingUsernameOrPassword,
        performing: {
            _ = try RDPCredentials.validated(username: "", domain: "KDE", password: "")
        }
    )
    #expect(
        throws: RDPCredentialValidationError.missingUsernameOrPassword,
        performing: {
            _ = try RDPCredentials.validated(username: "rdp-user", domain: "", password: "")
        }
    )
}

/// With no domain, "DOMAIN\user" names both, as mstsc and FreeRDP read it.
@Test(arguments: [
    ("CORP\\alice", nil, "alice", "CORP"),
    ("CORP\\alice", "", "alice", "CORP"),
    (".\\alice", nil, "alice", "."),
    ("\\alice", nil, "alice", nil),
    ("CORP\\alice\\x", nil, "alice\\x", "CORP"),
    // A domain given separately keeps the user name as typed.
    ("CORP\\alice", "LAB", "CORP\\alice", "LAB"),
    // Nothing after the backslash: no user name to split off.
    ("CORP\\", nil, "CORP\\", nil),
    // A UPN is the user name, with an empty domain.
    ("alice@corp.example", nil, "alice@corp.example", nil),
] as [(String, String?, String, String?)])
func credentialsSplitDomainQualifiedUsername(given: String, domain: String?, username: String, splitDomain: String?) {
    let credentials = RDPCredentials(username: given, domain: domain, password: "secret")

    #expect(credentials.username == username)
    #expect(credentials.domain == splitDomain)
}

@Test func validatedCredentialsSplitDomainQualifiedUsername() throws {
    let credentials = try #require(try RDPCredentials.validated(username: "  CORP\\alice ", domain: " ", password: "secret"))
    let configuration = RDPConnectionConfiguration(host: "Example.test", credentials: credentials)

    #expect(credentials.username == "alice")
    #expect(credentials.domain == "CORP")
    // The account a password is stored under is the one for the name as typed.
    #expect(configuration.identity.credentialAccountName
        == RDPConnectionIdentity(host: "Example.test", username: "CORP\\alice").credentialAccountName)
}

/// The longest fields `validated` accepts are the longest the Client Info PDU carries.
@Test func credentialValidationAcceptsFieldsTheClientInfoPDUHolds() throws {
    let longest = String(repeating: "x", count: 255)
    let credentials = try #require(try RDPCredentials.validated(username: longest, domain: longest, password: longest))

    #expect(RDPCredentials.maximumFieldLength == 255)
    #expect(throws: Never.self) { try RDPClientInfoPDU(credentials: credentials).encodedPDUData() }
}

/// A field one UTF-16 code unit longer fails `validated`, naming it, as it would fail connecting.
@Test(arguments: [RDPCredentialField.username, .domain, .password])
func credentialValidationRejectsFieldsTooLongForTheClientInfoPDU(field: RDPCredentialField) {
    let tooLong = String(repeating: "x", count: 256)
    let username = field == .username ? tooLong : "alice"
    let domain = field == .domain ? tooLong : "CORP"
    let password = field == .password ? tooLong : "secret"

    #expect(throws: RDPCredentialValidationError.fieldTooLong(field)) {
        _ = try RDPCredentials.validated(username: username, domain: domain, password: password)
    }
    let unvalidated = RDPCredentials(username: username, domain: domain, password: password)
    #expect(throws: RDPClientInfoEncodingError.self) { try RDPClientInfoPDU(credentials: unvalidated).encodedPDUData() }
}

/// The limit counts UTF-16 code units, as the Client Info PDU does: 128 emoji are 256.
@Test func credentialValidationCountsUTF16CodeUnits() {
    #expect(throws: RDPCredentialValidationError.fieldTooLong(.password)) {
        _ = try RDPCredentials.validated(username: "alice", password: String(repeating: "😀", count: 128))
    }
}

/// The limits apply to the fields connecting sends, after "DOMAIN\user" is split.
@Test func credentialValidationLimitsTheSplitFields() throws {
    let credentials = try #require(try RDPCredentials.validated(
        username: "CORP\\" + String(repeating: "u", count: 255),
        password: "secret"
    ))
    #expect(credentials.username.utf16.count == 255)

    #expect(throws: RDPCredentialValidationError.fieldTooLong(.domain)) {
        _ = try RDPCredentials.validated(username: String(repeating: "d", count: 256) + "\\alice", password: "secret")
    }
}

@Test func credentialValidationErrorNamesTheField() {
    #expect(String(describing: RDPCredentialValidationError.fieldTooLong(.password))
        == "Password is too long: RDP sends at most 255 characters (UTF-16 code units).")
    #expect(String(describing: RDPCredentialValidationError.fieldTooLong(.username)).hasPrefix("Username is too long"))
    #expect(String(describing: RDPCredentialValidationError.fieldTooLong(.domain)).hasPrefix("Domain is too long"))
}
