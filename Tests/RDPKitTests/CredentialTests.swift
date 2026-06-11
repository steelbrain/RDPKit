@testable import RDPKit
import Testing

@Test func qualifiedUsernameOmitsEmptyDomain() {
    let credentials = RDPCredentials(username: "aneesi", domain: "", password: "secret")

    #expect(credentials.qualifiedUsername == "aneesi")
}

@Test func qualifiedUsernameIncludesDomainWhenPresent() {
    let credentials = RDPCredentials(username: "aneesi", domain: "KDE", password: "secret")

    #expect(credentials.qualifiedUsername == "KDE\\aneesi")
}

@Test func credentialValidationReturnsNilWhenFieldsAreEmpty() throws {
    let credentials = try RDPCredentials.validated(username: "  ", domain: "  ", password: "")

    #expect(credentials == nil)
}

@Test func credentialValidationTrimsUsernameAndDomain() throws {
    let validatedCredentials = try RDPCredentials.validated(
        username: "  aneesi  ",
        domain: "  KDE  ",
        password: "secret"
    )
    let credentials = try #require(validatedCredentials)

    #expect(credentials.username == "aneesi")
    #expect(credentials.domain == "KDE")
    #expect(credentials.password == "secret")
}

@Test func credentialValidationDropsEmptyDomain() throws {
    let validatedCredentials = try RDPCredentials.validated(
        username: "aneesi",
        domain: "  ",
        password: "secret"
    )
    let credentials = try #require(validatedCredentials)

    #expect(credentials.domain == nil)
    #expect(credentials.qualifiedUsername == "aneesi")
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
            _ = try RDPCredentials.validated(username: "aneesi", domain: "", password: "")
        }
    )
}
