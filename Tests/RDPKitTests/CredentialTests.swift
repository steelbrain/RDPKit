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
