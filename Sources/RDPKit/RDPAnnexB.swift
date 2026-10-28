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

/// H.264 sequence parameter set rewriting (ITU-T H.264 7.3.2.1.1 and E.1.1).
enum RDPH264SequenceParameterSet {
    /// Returns the SPS NAL unit with a VUI video signal type of full range, BT.709 primaries and
    /// matrix, and sRGB transfer, or nil when the SPS cannot be parsed. Every other field is
    /// copied bit for bit.
    static func signalingFullRangeBT709(_ nalUnit: Data) -> Data? {
        guard let header = nalUnit.first, header & 0x1F == 7 else {
            return nil
        }
        let rbsp = removingEmulationPrevention(nalUnit.dropFirst())
        // The last set bit is rbsp_stop_one_bit; anything after it is alignment or trailing zeros.
        guard let lastByteIndex = rbsp.lastIndex(where: { $0 != 0 }) else {
            return nil
        }
        let stopBitPosition = lastByteIndex * 8 + 7 - rbsp[lastByteIndex].trailingZeroBitCount
        var reader = RBSPBitReader(bytes: rbsp, end: stopBitPosition)
        var writer = RBSPBitWriter()
        do {
            try reader.skipToVUIParametersPresentFlag()
            writer.copy(rbsp, bits: 0 ..< reader.position)
            let hasVUI = try reader.readBits(1) == 1
            writer.write(1, bitCount: 1)
            var videoFormat: UInt32 = 5 // Unspecified
            if hasVUI {
                let start = reader.position
                if try reader.readBits(1) == 1, try reader.readBits(8) == 255 {
                    try reader.skipBits(32) // Extended_SAR sar_width, sar_height
                }
                if try reader.readBits(1) == 1 {
                    try reader.skipBits(1) // overscan_appropriate_flag
                }
                writer.copy(rbsp, bits: start ..< reader.position)
                if try reader.readBits(1) == 1 {
                    videoFormat = try reader.readBits(3)
                    try reader.skipBits(1) // video_full_range_flag
                    if try reader.readBits(1) == 1 {
                        try reader.skipBits(24) // colour_primaries, transfer_characteristics, matrix_coefficients
                    }
                }
            } else {
                writer.write(0, bitCount: 2) // aspect_ratio_info_present_flag, overscan_info_present_flag
            }
            writer.write(1, bitCount: 1) // video_signal_type_present_flag
            writer.write(videoFormat, bitCount: 3)
            writer.write(1, bitCount: 1) // video_full_range_flag
            writer.write(1, bitCount: 1) // colour_description_present_flag
            // BT.709 primaries and matrix with the sRGB transfer of desktop content. Tagged with the
            // BT.709 transfer, Core Image renders lighter colours than MS-RDPEGFX 3.3.8.3.1 defines.
            writer.write(0x01_0D_01, bitCount: 24)
            if hasVUI {
                writer.copy(rbsp, bits: reader.position ..< stopBitPosition)
            } else {
                // chroma_loc_info, timing_info, NAL HRD, VCL HRD, pic_struct, and bitstream_restriction flags.
                writer.write(0, bitCount: 6)
            }
        } catch {
            return nil
        }
        writer.write(1, bitCount: 1) // rbsp_stop_one_bit
        return Data([header]) + addingEmulationPrevention(writer.bytes)
    }

    private static func removingEmulationPrevention(_ bytes: Data) -> [UInt8] {
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(bytes.count)
        var zeroCount = 0
        for byte in bytes {
            if zeroCount >= 2, byte == 3 {
                zeroCount = 0
                continue
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return rbsp
    }

    private static func addingEmulationPrevention(_ rbsp: [UInt8]) -> Data {
        var bytes = Data(capacity: rbsp.count + rbsp.count / 2)
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount >= 2, byte <= 3 {
                bytes.append(3)
                zeroCount = 0
            }
            bytes.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return bytes
    }
}

private struct RBSPBitReader {
    struct EndOfData: Error {}

    let bytes: [UInt8]
    let end: Int
    var position = 0

    mutating func readBits(_ count: Int) throws -> UInt32 {
        guard position + count <= end else {
            throw EndOfData()
        }
        var value: UInt32 = 0
        for _ in 0 ..< count {
            let bit = bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1
            value = value << 1 | UInt32(bit)
            position += 1
        }
        return value
    }

    mutating func skipBits(_ count: Int) throws {
        guard position + count <= end else {
            throw EndOfData()
        }
        position += count
    }

    /// ue(v), 9.1.
    mutating func readUnsignedExpGolomb() throws -> UInt32 {
        var leadingZeroBits = 0
        while try readBits(1) == 0 {
            leadingZeroBits += 1
            guard leadingZeroBits < 32 else {
                throw EndOfData()
            }
        }
        let suffix = try readBits(leadingZeroBits)
        return (UInt32(1) << leadingZeroBits) - 1 + suffix
    }

    /// se(v), 9.1.1.
    mutating func readSignedExpGolomb() throws -> Int {
        let codeNum = Int(try readUnsignedExpGolomb())
        return codeNum.isMultiple(of: 2) ? -(codeNum / 2) : (codeNum + 1) / 2
    }

    /// Reads seq_parameter_set_data() up to vui_parameters_present_flag (7.3.2.1.1).
    mutating func skipToVUIParametersPresentFlag() throws {
        let profileIDC = try readBits(8)
        try skipBits(16) // constraint_set flags, reserved_zero_2bits, level_idc
        _ = try readUnsignedExpGolomb() // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIDC) {
            let chromaFormatIDC = try readUnsignedExpGolomb()
            if chromaFormatIDC == 3 {
                try skipBits(1) // separate_colour_plane_flag
            }
            _ = try readUnsignedExpGolomb() // bit_depth_luma_minus8
            _ = try readUnsignedExpGolomb() // bit_depth_chroma_minus8
            try skipBits(1) // qpprime_y_zero_transform_bypass_flag
            if try readBits(1) == 1 { // seq_scaling_matrix_present_flag
                for index in 0 ..< (chromaFormatIDC == 3 ? 12 : 8) {
                    if try readBits(1) == 1 { // seq_scaling_list_present_flag
                        try skipScalingList(size: index < 6 ? 16 : 64)
                    }
                }
            }
        }
        _ = try readUnsignedExpGolomb() // log2_max_frame_num_minus4
        switch try readUnsignedExpGolomb() { // pic_order_cnt_type
        case 0:
            _ = try readUnsignedExpGolomb() // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            try skipBits(1) // delta_pic_order_always_zero_flag
            _ = try readSignedExpGolomb() // offset_for_non_ref_pic
            _ = try readSignedExpGolomb() // offset_for_top_to_bottom_field
            let referenceFrameCount = try readUnsignedExpGolomb() // num_ref_frames_in_pic_order_cnt_cycle
            for _ in 0 ..< referenceFrameCount {
                _ = try readSignedExpGolomb() // offset_for_ref_frame
            }
        default:
            break
        }
        _ = try readUnsignedExpGolomb() // max_num_ref_frames
        try skipBits(1) // gaps_in_frame_num_value_allowed_flag
        _ = try readUnsignedExpGolomb() // pic_width_in_mbs_minus1
        _ = try readUnsignedExpGolomb() // pic_height_in_map_units_minus1
        if try readBits(1) == 0 { // frame_mbs_only_flag
            try skipBits(1) // mb_adaptive_frame_field_flag
        }
        try skipBits(1) // direct_8x8_inference_flag
        if try readBits(1) == 1 { // frame_cropping_flag
            for _ in 0 ..< 4 {
                _ = try readUnsignedExpGolomb()
            }
        }
    }

    /// scaling_list(), 7.3.2.1.1.1.
    private mutating func skipScalingList(size: Int) throws {
        var lastScale = 8
        var nextScale = 8
        for _ in 0 ..< size {
            if nextScale != 0 {
                let deltaScale = try readSignedExpGolomb()
                nextScale = (lastScale + deltaScale + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }
}

private struct RBSPBitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt32, bitCount count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) {
                bytes.append(0)
            }
            bytes[bytes.count - 1] |= UInt8(value >> UInt32(shift) & 1) << (7 - UInt8(bitCount & 7))
            bitCount += 1
        }
    }

    mutating func copy(_ source: [UInt8], bits range: Range<Int>) {
        for position in range {
            write(UInt32(source[position >> 3] >> (7 - UInt8(position & 7)) & 1), bitCount: 1)
        }
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
