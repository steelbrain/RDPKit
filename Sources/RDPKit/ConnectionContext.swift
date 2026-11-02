/// What the session a handler gets knows of the connection it belongs to, fixed for that
/// connection. Read it there rather than in the live report, which moves on to the next
/// connection once a Server Redirection comes, maybe before the handler's work reaches another
/// thread.
public struct RDPConnectionContext: Equatable, Sendable {
    /// How many Server Redirections led to this connection ([MS-RDPBCGR] 3.1.5.2): 0 for the
    /// configured server, as ``RDPConnectionReport/redirectionDepth`` counts them.
    public var redirectionDepth: Int
    /// Whether the server checked the credentials before the session started, as
    /// ``RDPConnectionReport/credentialsVerifiedBeforeActivation`` says.
    public var credentialsVerifiedBeforeActivation: Bool

    public init(redirectionDepth: Int = 0, credentialsVerifiedBeforeActivation: Bool = false) {
        self.redirectionDepth = redirectionDepth
        self.credentialsVerifiedBeforeActivation = credentialsVerifiedBeforeActivation
    }
}
