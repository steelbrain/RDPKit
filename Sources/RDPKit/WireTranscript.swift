import Foundation

/// Which side of the connection emitted a captured wire event.
public enum RDPWireDirection: String, Codable, Equatable, Sendable {
    case clientToServer
    case serverToClient
}

/// The protocol layer a captured wire event belongs to.
///
/// - ``x224``: the pre-TLS X.224 negotiation (plaintext on the wire).
/// - ``security``: the TLS/CredSSP exchange. Recorded as a marker only — the
///   bytes are encrypted and the NLA handshake is non-deterministic (fresh NTLM
///   nonces, timestamps, and TLS randoms every run), so it cannot be replayed
///   verbatim. A replay server terminates TLS and performs NLA live instead.
/// - ``application``: the post-NLA plaintext RDP PDUs (MCS, auto-detect,
///   activation, finalization, RDPGFX, …) that drive the negotiation up to the
///   point where video frames start flowing.
public enum RDPWireLayer: String, Codable, Equatable, Sendable {
    case x224
    case security
    case application
}

/// A single captured exchange on the RDP wire.
///
/// Server→client application PDUs carry their full plaintext ``hex`` so a replay
/// server can feed them back verbatim. Client→server application PDUs are
/// recorded as length-only markers (``hex`` is `nil`): their payload can contain
/// credentials (the Client Info PDU) and, for replay purposes, the client side
/// is only needed as an ordering barrier — not asserted byte-for-byte.
public struct RDPWireEvent: Codable, Equatable, Sendable {
    public var sequence: Int
    public var direction: RDPWireDirection
    public var layer: RDPWireLayer
    public var byteCount: Int
    /// Space-separated plaintext bytes, or `nil` when the payload is redacted.
    public var hex: String?

    public init(
        sequence: Int,
        direction: RDPWireDirection,
        layer: RDPWireLayer,
        byteCount: Int,
        hex: String?
    ) {
        self.sequence = sequence
        self.direction = direction
        self.layer = layer
        self.byteCount = byteCount
        self.hex = hex
    }

    /// The decoded plaintext bytes, or `nil` when the payload was redacted.
    public var bytes: Data? {
        hex.flatMap { Data(rdpHexString: $0) }
    }
}

/// Collects the ordered wire exchange of an RDP connection so it can be dumped
/// and replayed as a deterministic regression fixture.
///
/// Pass an instance to `RDPPreflightClient.run(...)` / `connect(...)` via the
/// `wireTranscript:` parameter, then read ``events`` once the call returns. Call
/// ``stop()`` to freeze recording at a boundary — e.g. when the first video
/// frame arrives — so the transcript captures everything up to, but not beyond,
/// where pixels start flowing.
public final class RDPWireTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RDPWireEvent] = []
    private var stopped = false

    public init() {}

    /// The captured events in wire order.
    public var events: [RDPWireEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Freezes recording. Subsequent ``record(direction:layer:bytes:capturePayload:)``
    /// calls are ignored. Idempotent.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }

    func record(
        direction: RDPWireDirection,
        layer: RDPWireLayer,
        bytes: Data,
        capturePayload: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        storage.append(RDPWireEvent(
            sequence: storage.count,
            direction: direction,
            layer: layer,
            byteCount: bytes.count,
            hex: capturePayload ? bytes.rdpHexString : nil
        ))
    }

    /// Records a layer marker with no payload (e.g. the NLA handshake).
    func recordMarker(direction: RDPWireDirection, layer: RDPWireLayer, byteCount: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        storage.append(RDPWireEvent(
            sequence: storage.count,
            direction: direction,
            layer: layer,
            byteCount: byteCount,
            hex: nil
        ))
    }
}
