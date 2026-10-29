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
/// credentials and an auto-reconnect cookie (the Client Info PDU) and, for replay
/// purposes, the client side is only needed as an ordering barrier — not
/// asserted byte-for-byte.
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
/// Pass an instance to `RDPSessionClient.run(...)` / `connect(...)` via the
/// `wireTranscript:` parameter, then read ``events`` once the call returns. Call
/// ``stop()`` to freeze recording at a boundary — e.g. when the first video
/// frame arrives — so the transcript captures everything up to, but not beyond,
/// where pixels start flowing.
///
/// A transcript is session data: server PDUs are kept in full, so it holds what
/// the server sent, such as screen contents, clipboard data, user and domain
/// names. Store and share it as you would the session itself. The secrets a
/// server sends in the clear are zeroed in ``events``: a Server Redirection
/// PDU's Password field and a Save Session Info PDU's auto-reconnect cookie.
/// The client's own application PDUs, which carry its credentials and
/// auto-reconnect cookie, are recorded by length only.
public final class RDPWireTranscript: @unchecked Sendable {
    private struct Record {
        var direction: RDPWireDirection
        var layer: RDPWireLayer
        var byteCount: Int
        var payload: Data?
    }

    private let lock = NSLock()
    private var storage: [Record] = []
    private var stopped = false
    private let maximumPayloadByteCount: Int?
    private var payloadByteCount = 0

    /// `maximumPayloadByteCount` bounds the bytes kept: recording stops, as
    /// with ``stop()``, before the first payload that would exceed it.
    public init(maximumPayloadByteCount: Int? = nil) {
        self.maximumPayloadByteCount = maximumPayloadByteCount
    }

    /// The captured events in wire order.
    public var events: [RDPWireEvent] {
        let records = lock.withLock { storage }
        return records.enumerated().map { sequence, record in
            RDPWireEvent(
                sequence: sequence,
                direction: record.direction,
                layer: record.layer,
                byteCount: record.byteCount,
                hex: record.payload.map {
                    (record.direction == .serverToClient ? $0.redactingServerSecrets : $0).rdpHexString
                }
            )
        }
    }

    /// Freezes recording. Subsequent ``record(direction:layer:bytes:capturePayload:)``
    /// calls are ignored. Idempotent.
    public func stop() {
        lock.withLock { stopped = true }
    }

    func record(
        direction: RDPWireDirection,
        layer: RDPWireLayer,
        bytes: Data,
        capturePayload: Bool
    ) {
        lock.withLock {
            guard !stopped else { return }
            if capturePayload {
                payloadByteCount += bytes.count
                if let maximumPayloadByteCount, payloadByteCount > maximumPayloadByteCount {
                    stopped = true
                    return
                }
            }
            storage.append(Record(
                direction: direction,
                layer: layer,
                byteCount: bytes.count,
                payload: capturePayload ? bytes : nil
            ))
        }
    }

    /// Records a layer marker with no payload (e.g. the NLA handshake).
    func recordMarker(direction: RDPWireDirection, layer: RDPWireLayer, byteCount: Int = 0) {
        lock.withLock {
            guard !stopped else { return }
            storage.append(Record(direction: direction, layer: layer, byteCount: byteCount, payload: nil))
        }
    }
}

extension Data {
    /// This server packet with the secrets servers send in the clear zeroed,
    /// lengths kept: a Server Redirection PDU's Password field, a cleartext
    /// password unless PK-encrypted ([MS-RDPBCGR] 2.2.13.1), and the
    /// auto-reconnect cookie of a Save Session Info PDU, which reconnects to
    /// the session without a password ([MS-RDPBCGR] 2.2.4.2, 5.5).
    var redactingServerSecrets: Data {
        guard first == TPKT.version, let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: self) else {
            return self
        }
        func littleEndian(_ value: UInt32) -> Data {
            var data = Data()
            data.appendLittleEndianUInt32(value)
            return data
        }
        // Each secret is found with the field just before it, so a short one
        // cannot match a header.
        let secret: (prefix: Data, bytes: Data)?
        if let redirection = try? RDPServerRedirectionPDU.parseIfPresent(from: indication) {
            secret = redirection.passwordCookie.map { (littleEndian(UInt32($0.count)), $0) }
        } else if let reconnect = (try? RDPShareDataPDU.parseIfPresent(from: indication))?
            .saveSessionInfo?.autoReconnectPacket
        {
            secret = (littleEndian(reconnect.logonID), reconnect.arcRandomBits)
        } else {
            secret = nil
        }
        guard let secret, !secret.bytes.isEmpty, let range = range(of: secret.prefix + secret.bytes) else {
            return self
        }
        var redacted = self
        redacted.resetBytes(in: range.lowerBound + secret.prefix.count ..< range.upperBound)
        return redacted
    }
}
