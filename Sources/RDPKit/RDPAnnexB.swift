import Foundation

public struct RDPH264AnnexBSample: Equatable, Sendable {
    public var lengthPrefixedData: Data
    public var sequenceParameterSet: Data?
    public var pictureParameterSet: Data?

    public var isEmpty: Bool {
        lengthPrefixedData.isEmpty
    }
}

public struct RDPHEVCAnnexBSample: Equatable, Sendable {
    public var lengthPrefixedData: Data
    public var videoParameterSet: Data?
    public var sequenceParameterSet: Data?
    public var pictureParameterSet: Data?

    public var isEmpty: Bool {
        lengthPrefixedData.isEmpty
    }
}

public enum RDPH264AnnexB {
    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        RDPAnnexB.nalUnitTypes(from: data, codec: .h264)
    }

    public static func sample(from data: Data) -> RDPH264AnnexBSample {
        let sample = RDPAnnexB.lengthPrefixedSample(from: data, codec: .h264)
        return RDPH264AnnexBSample(
            lengthPrefixedData: sample.data,
            sequenceParameterSet: sample.parameterSets[7],
            pictureParameterSet: sample.parameterSets[8]
        )
    }
}

public enum RDPHEVCAnnexB {
    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        RDPAnnexB.nalUnitTypes(from: data, codec: .hevc)
    }

    public static func sample(from data: Data) -> RDPHEVCAnnexBSample {
        let sample = RDPAnnexB.lengthPrefixedSample(from: data, codec: .hevc)
        return RDPHEVCAnnexBSample(
            lengthPrefixedData: sample.data,
            videoParameterSet: sample.parameterSets[32],
            sequenceParameterSet: sample.parameterSets[33],
            pictureParameterSet: sample.parameterSets[34]
        )
    }
}

/// Splits ITU-T H.264/H.265 Annex B byte streams at their start codes.
enum RDPAnnexB {
    enum Codec {
        case h264
        case hevc

        /// NAL units shorter than their header are skipped.
        var headerByteCount: Int {
            self == .h264 ? 1 : 2
        }

        var parameterSetTypes: [UInt8] {
            self == .h264 ? [7, 8] : [32, 33, 34]
        }

        func nalUnitType(_ firstHeaderByte: UInt8) -> UInt8 {
            self == .h264 ? firstHeaderByte & 0x1F : (firstHeaderByte >> 1) & 0x3F
        }
    }

    static func nalUnitTypes(from data: Data, codec: Codec) -> [UInt8] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return nalUnitPayloadRanges(in: bytes, codec: codec).map { range in
                codec.nalUnitType(bytes[range.lowerBound])
            }
        }
    }

    /// Converts NAL units to the 4-byte big-endian length-prefixed form, keeping the
    /// first payload of each parameter-set NAL unit type.
    static func lengthPrefixedSample(
        from data: Data,
        codec: Codec
    ) -> (data: Data, parameterSets: [UInt8: Data]) {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let ranges = nalUnitPayloadRanges(in: bytes, codec: codec)
            var lengthPrefixedData = Data()
            lengthPrefixedData.reserveCapacity(ranges.reduce(0) { $0 + 4 + $1.count })
            var parameterSets: [UInt8: Data] = [:]
            for range in ranges {
                let payload = UnsafeBufferPointer(rebasing: bytes[range])
                let type = codec.nalUnitType(payload[0])
                if codec.parameterSetTypes.contains(type), parameterSets[type] == nil {
                    parameterSets[type] = Data(payload)
                }
                withUnsafeBytes(of: UInt32(range.count).bigEndian) { lengthBytes in
                    lengthPrefixedData.append(contentsOf: lengthBytes)
                }
                lengthPrefixedData.append(payload)
            }
            return (lengthPrefixedData, parameterSets)
        }
    }

    static func nalUnitPayloadRanges(in bytes: UnsafeBufferPointer<UInt8>, codec: Codec) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        var searchOffset = 0
        while let startCode = nextStartCode(in: bytes, from: searchOffset) {
            if let payloadStart, payloadStart < startCode.index {
                ranges.append(payloadStart ..< startCode.index)
            }
            payloadStart = startCode.index + startCode.length
            searchOffset = startCode.index + startCode.length
        }
        if let payloadStart, payloadStart < bytes.count {
            ranges.append(payloadStart ..< bytes.count)
        }
        return ranges.filter { $0.count >= codec.headerByteCount }
    }

    private static func nextStartCode(
        in bytes: UnsafeBufferPointer<UInt8>,
        from offset: Int
    ) -> (index: Int, length: Int)? {
        var index = offset
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    return (index, 3)
                }
                if bytes[index + 2] == 0, index + 3 < bytes.count, bytes[index + 3] == 1 {
                    return (index, 4)
                }
            }
            index += 1
        }
        return nil
    }
}
