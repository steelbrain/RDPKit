import Foundation

struct MCSDisconnectProviderUltimatumPDU: Equatable, Sendable {
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
        default:
            "rn-unknown-\(reason)"
        }
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

        let choiceAndReasonHighBit = packet[7]
        let reasonLowBitAndPadding = packet[8]
        guard choiceAndReasonHighBit & 0xFE == 0x20,
              reasonLowBitAndPadding & 0x7F == 0
        else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }

        let reason = ((choiceAndReasonHighBit & 0x01) << 1) | (reasonLowBitAndPadding >> 7)
        return MCSDisconnectProviderUltimatumPDU(reason: reason)
    }
}
