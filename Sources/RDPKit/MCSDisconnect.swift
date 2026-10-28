import Foundation

struct MCSDisconnectProviderUltimatumPDU: Equatable, Sendable {
    /// The reason a client gives when it ends the session ([MS-RDPBCGR] 3.1.5.1.1).
    static let userRequested = MCSDisconnectProviderUltimatumPDU(reason: 3)

    var reason: UInt8

    var reasonName: String {
        switch reason {
        case 0:
            "rn-domain-disconnected"
        case 1:
            "rn-provider-initiated"
        case 2:
            "rn-token-purged"
        case 3:
            "rn-user-requested"
        case 4:
            "rn-channel-purged"
        default:
            "rn-unknown-\(reason)"
        }
    }

    func encodedTPKT() -> Data {
        X224DataTPDU.wrap(Data([0x20 | (reason >> 1), (reason & 0x01) << 7]))
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> MCSDisconnectProviderUltimatumPDU? {
        guard packet.count == 9,
              packet.starts(with: [
                  TPKT.version, 0x00, 0x00, 0x09,
                  0x02, 0xF0, 0x80,
              ])
        else {
            return nil
        }

        // T.125 PER: 6-bit DomainMCSPDU choice (8), then the 3-bit Reason
        // spanning the byte boundary, then padding.
        let choiceAndReasonHighBits = packet[packet.index(packet.startIndex, offsetBy: 7)]
        let reasonLowBitAndPadding = packet[packet.index(packet.startIndex, offsetBy: 8)]
        guard choiceAndReasonHighBits & 0xFC == 0x20,
              reasonLowBitAndPadding & 0x7F == 0
        else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }

        let reason = ((choiceAndReasonHighBits & 0x03) << 1) | (reasonLowBitAndPadding >> 7)
        return MCSDisconnectProviderUltimatumPDU(reason: reason)
    }
}
