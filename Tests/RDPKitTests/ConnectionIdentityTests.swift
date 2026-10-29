@testable import RDPKit
import Testing

@Test func connectionIdentityFormatsDisplayName() {
    #expect(RDPConnectionIdentity(host: "server.local").displayName == "server.local")
    #expect(
        RDPConnectionIdentity(
            host: "server.local",
            port: 3390,
            username: "anees"
        ).displayName == "anees@server.local:3390"
    )
    #expect(
        RDPConnectionIdentity(
            host: "server.local",
            username: "anees",
            domain: "LAB"
        ).displayName == "LAB\\anees@server.local"
    )
}

@Test func connectionIdentityFormatsCredentialAccountName() {
    #expect(RDPConnectionIdentity(host: "server.local").credentialAccountName == nil)
    #expect(
        RDPConnectionIdentity(
            host: "server.local",
            username: "anees"
        ).credentialAccountName == "anees@server.local:3389"
    )
    #expect(
        RDPConnectionIdentity(
            host: "server.local",
            port: 3390,
            username: "anees",
            domain: "LAB"
        ).credentialAccountName == "LAB\\anees@server.local:3390"
    )
    #expect(
        RDPConnectionIdentity(host: "Server.Local", username: "Anees").credentialAccountName
            == RDPConnectionIdentity(host: "server.local", username: "Anees").credentialAccountName
    )
}

@Test func connectionIdentityCredentialAccountNameIgnoresOnlyTheHostsCase() {
    let identity = RDPConnectionIdentity(host: " Server.Local ", port: 3390, username: " Anees ", domain: " Lab ")

    // Clients key saved passwords by this name, so its form must not change between releases.
    #expect(identity.credentialAccountName == "Lab\\Anees@server.local:3390")
    #expect(
        RDPConnectionIdentity(host: "server.local", port: 3390, username: "anees", domain: "Lab").credentialAccountName
            != identity.credentialAccountName
    )
    #expect(
        RDPConnectionIdentity(host: "server.local", port: 3390, username: "Anees", domain: "LAB").credentialAccountName
            != identity.credentialAccountName
    )
    #expect(
        RDPConnectionIdentity(host: "server.local", port: 3390, username: "Anees", domain: "").credentialAccountName
            == "Anees@server.local:3390"
    )
}

@Test func connectionIdentityListsTheAccountNamesEarlierReleasesUsed() {
    // RDPKit 0.1 to 0.3 kept the host as entered.
    #expect(
        RDPConnectionIdentity(host: "Server.Local", port: 3390, username: "Anees", domain: "LAB")
            .legacyCredentialAccountNames == ["LAB\\Anees@Server.Local:3390"]
    )
    #expect(
        RDPConnectionIdentity(host: " DESKTOP ", username: "anees").legacyCredentialAccountNames
            == ["anees@DESKTOP:3389"]
    )
    // A lowercase host had the same name then, so there is nothing to move.
    #expect(RDPConnectionIdentity(host: "server.local", username: "anees").legacyCredentialAccountNames.isEmpty)
    #expect(RDPConnectionIdentity(host: "Server.Local").legacyCredentialAccountNames.isEmpty)
}

@Test func connectionIdentityTrimsComponents() {
    let identity = RDPConnectionIdentity(
        host: "  Server.Local  ",
        port: 3389,
        username: "  anees  ",
        domain: "  LAB  "
    )

    #expect(identity.host == "Server.Local")
    #expect(identity.username == "anees")
    #expect(identity.domain == "LAB")
    #expect(identity.displayName == "LAB\\anees@Server.Local")
}

@Test func connectionIdentityMatchesNormalizedHostAndAccount() {
    let lhs = RDPConnectionIdentity(
        host: "SERVER.LOCAL",
        port: 3389,
        username: "anees",
        domain: ""
    )
    let rhs = RDPConnectionIdentity(
        host: "server.local",
        port: 3389,
        username: "anees",
        domain: nil
    )
    let differentAccount = RDPConnectionIdentity(
        host: "server.local",
        port: 3389,
        username: "anees",
        domain: "LAB"
    )

    #expect(lhs.hasSameConnectionIdentity(as: rhs))
    #expect(lhs.hasSameConnectionIdentity(as: differentAccount) == false)
}

@Test func connectionIdentityMatchesExactlyWhereItsCredentialAccountNameDoes() {
    let identities = [
        RDPConnectionIdentity(host: "server.local", username: "LAB\\anees"),
        RDPConnectionIdentity(host: "Server.Local", username: "anees", domain: "LAB"),
        RDPConnectionIdentity(host: "server.local", username: "anees", domain: "lab"),
        RDPConnectionIdentity(host: "server.local", username: "anees"),
        RDPConnectionIdentity(host: "server.local", username: "\\anees"),
        RDPConnectionIdentity(host: "server.local", port: 3390, username: "LAB\\anees"),
    ]
    for lhs in identities {
        for rhs in identities {
            #expect(lhs.hasSameConnectionIdentity(as: rhs) == (lhs.credentialAccountName == rhs.credentialAccountName))
        }
    }
    // RDPCredentials signs "LAB\anees" with no domain in as "anees" in LAB.
    #expect(identities[0].hasSameConnectionIdentity(as: identities[1]))

    // Without a user name there is no account name, and the domain still tells them apart.
    #expect(RDPConnectionIdentity(host: "server.local").hasSameConnectionIdentity(as: RDPConnectionIdentity(host: "Server.Local")))
    #expect(
        RDPConnectionIdentity(host: "server.local", domain: "LAB")
            .hasSameConnectionIdentity(as: RDPConnectionIdentity(host: "server.local")) == false
    )
}

@Test func connectionTargetValidatesHostAndPortText() throws {
    let target = try RDPConnectionTarget(host: "  server.local  ", portText: " 3390 ")

    #expect(target.host == "server.local")
    #expect(target.port == 3390)
}

@Test func connectionTargetRejectsMissingHostAndInvalidPort() {
    #expect(
        throws: RDPConnectionValidationError.missingHost,
        performing: {
            _ = try RDPConnectionTarget(host: "  ", portText: "3389")
        }
    )
    #expect(
        throws: RDPConnectionValidationError.invalidPort,
        performing: {
            _ = try RDPConnectionTarget(host: "server.local", portText: "99999")
        }
    )
    #expect(
        throws: RDPConnectionValidationError.invalidPort,
        performing: {
            _ = try RDPConnectionTarget(host: "server.local", portText: "0")
        }
    )
}

@Test func desktopSizeValidatesProtocolRange() throws {
    let size = try RDPDesktopSize(widthText: " 1920 ", heightText: " 1080 ")

    #expect(size.width == 1920)
    #expect(size.height == 1080)
}

@Test func desktopSizeRejectsInvalidOrOutOfRangeValues() {
    #expect(
        throws: RDPConnectionValidationError.invalidDesktopSize,
        performing: {
            _ = try RDPDesktopSize(widthText: "639", heightText: "1080")
        }
    )
    #expect(
        throws: RDPConnectionValidationError.invalidDesktopSize,
        performing: {
            _ = try RDPDesktopSize(widthText: "1920", heightText: "not-a-height")
        }
    )
}
