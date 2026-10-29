import Foundation

/// The RC4 stream cipher, for NTLM key exchange and sealing ([MS-NLMP]) and
/// licensing data encryption ([MS-RDPELE]).
final class RDPRC4 {
    private var i = 0
    private var j = 0
    private var state = [UInt8](0 ... 255)

    init(key: Data) {
        precondition(key.isEmpty == false)
        var j = 0
        let keyBytes = [UInt8](key)
        for i in 0 ..< 256 {
            j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
            state.swapAt(i, j)
        }
    }

    func process(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        for byte in input {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            let keyIndex = (Int(state[i]) + Int(state[j])) & 0xFF
            output.append(byte ^ state[keyIndex])
        }
        return output
    }
}
