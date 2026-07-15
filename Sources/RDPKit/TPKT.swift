import Foundation

enum TPKT {
    static let version: UInt8 = 3
    private static let headerLength = 4

    static func wrap(_ payload: Data) -> Data {
        precondition(payload.count <= Int(UInt16.max) - headerLength)

        var data = Data()
        data.appendUInt8(version)
        data.appendUInt8(0)
        data.appendBigEndianUInt16(UInt16(payload.count + headerLength))
        data.append(payload)
        return data
    }

    static func unwrap(_ packet: Data) throws -> Data {
        var cursor = ByteCursor(packet)
        let parsedVersion = try cursor.readUInt8()
        guard parsedVersion == version else {
            throw RDPDecodeError.invalidTPKTVersion(parsedVersion)
        }

        let reserved = try cursor.readUInt8()
        guard reserved == 0 else {
            throw RDPDecodeError.invalidTPKTReserved(reserved)
        }

        let declaredLength = try Int(cursor.readBigEndianUInt16())
        guard declaredLength >= headerLength else {
            throw RDPDecodeError.invalidTPKTLength(
                declared: declaredLength,
                actual: packet.count
            )
        }
        guard declaredLength == packet.count else {
            throw RDPDecodeError.invalidTPKTLength(
                declared: declaredLength,
                actual: packet.count
            )
        }

        return cursor.readRemainingData()
    }
}
