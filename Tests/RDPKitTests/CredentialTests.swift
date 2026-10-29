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
