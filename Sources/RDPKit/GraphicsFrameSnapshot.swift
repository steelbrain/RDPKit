import Foundation

public enum RDPVideoCodec: String, Encodable, Equatable, Sendable {
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .h264:
            "H.264"
        case .hevc:
            "HEVC"
        }
    }

    public func nalUnitTypes(from data: Data) -> [UInt8] {
        switch self {
        case .h264:
            RDPH264AnnexB.nalUnitTypes(from: data)
        case .hevc:
            RDPHEVCAnnexB.nalUnitTypes(from: data)
        }
    }
}

public enum RDPGraphicsFrameContentKind: String, Encodable, Equatable, Sendable {
    case video
    case bitmap
}

public struct RDPFrameRect: Encodable, Equatable, Sendable {
    public var left: UInt16
    public var top: UInt16
    public var right: UInt16
    public var bottom: UInt16

    public init(left: UInt16, top: UInt16, right: UInt16, bottom: UInt16) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    init(_ rect: RDPGFXRect16) {
        self.init(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
    }

    public var width: UInt16 {
        right >= left ? right - left : 0
    }

    public var height: UInt16 {
        bottom >= top ? bottom - top : 0
    }
}

public enum RDPAVC444SubframeLayout: String, Encodable, Equatable, Sendable {
    case yuv420AndChroma420
    case yuv420Only
    case chroma420Only
}

public struct RDPGraphicsFrameSnapshot: Encodable, Equatable, Sendable {
    public var frameID: UInt32?
    public var surfaceID: UInt16
    public var codecID: UInt16
    public var codecName: String
    public var videoCodec: RDPVideoCodec
    public var pixelFormat: UInt8
    public var graphicsOutputRect: RDPFrameRect?
    public var surfaceRect: RDPFrameRect?
    public var mappedOutputRect: RDPFrameRect?
    public var destinationRect: RDPFrameRect
    public var regionRects: [RDPFrameRect]
    public var encodedVideoData: Data
    public var auxiliaryEncodedVideoData: Data?
    public var auxiliaryRegionRects: [RDPFrameRect]
    public var avc444SubframeLayout: RDPAVC444SubframeLayout?
    public var contentKind: RDPGraphicsFrameContentKind
    public var decodedBitmapData: Data?
    public var decodedBitmapBytesPerRow: Int?

    public init(
        frameID: UInt32?,
        surfaceID: UInt16,
        codecID: UInt16,
        codecName: String,
        videoCodec: RDPVideoCodec = .h264,
        pixelFormat: UInt8,
        graphicsOutputRect: RDPFrameRect? = nil,
        surfaceRect: RDPFrameRect? = nil,
        mappedOutputRect: RDPFrameRect? = nil,
        destinationRect: RDPFrameRect,
        regionRects: [RDPFrameRect],
        encodedVideoData: Data,
        auxiliaryEncodedVideoData: Data? = nil,
        auxiliaryRegionRects: [RDPFrameRect] = [],
        avc444SubframeLayout: RDPAVC444SubframeLayout? = nil,
        contentKind: RDPGraphicsFrameContentKind = .video,
        decodedBitmapData: Data? = nil,
        decodedBitmapBytesPerRow: Int? = nil
    ) {
        self.frameID = frameID
        self.surfaceID = surfaceID
        self.codecID = codecID
        self.codecName = codecName
        self.videoCodec = videoCodec
        self.pixelFormat = pixelFormat
        self.graphicsOutputRect = graphicsOutputRect
        self.surfaceRect = surfaceRect
        self.mappedOutputRect = mappedOutputRect
        self.destinationRect = destinationRect
        self.regionRects = regionRects
        self.encodedVideoData = encodedVideoData
        self.auxiliaryEncodedVideoData = auxiliaryEncodedVideoData
        self.auxiliaryRegionRects = auxiliaryRegionRects
        self.avc444SubframeLayout = avc444SubframeLayout
        self.contentKind = contentKind
        self.decodedBitmapData = decodedBitmapData
        self.decodedBitmapBytesPerRow = decodedBitmapBytesPerRow
    }

    public var width: UInt16 {
        destinationRect.width
    }

    public var height: UInt16 {
        destinationRect.height
    }

    public var videoByteCount: Int {
        guard contentKind == .video else {
            return 0
        }
        return encodedVideoData.count + (auxiliaryEncodedVideoData?.count ?? 0)
    }

    public var videoNalUnitTypes: [UInt8] {
        guard contentKind == .video else {
            return []
        }
        var types = videoCodec.nalUnitTypes(from: encodedVideoData)
        if let auxiliaryEncodedVideoData {
            types.append(contentsOf: videoCodec.nalUnitTypes(from: auxiliaryEncodedVideoData))
        }
        return types
    }

    public var bitmapByteCount: Int {
        decodedBitmapData?.count ?? 0
    }

    public var payloadByteCount: Int {
        contentKind == .bitmap ? bitmapByteCount : videoByteCount
    }

    enum CodingKeys: String, CodingKey {
        case frameID
        case surfaceID
        case codecID
        case codecName
        case contentKind
        case videoCodec
        case videoCodecName
        case pixelFormat
        case graphicsOutputRect
        case surfaceRect
        case mappedOutputRect
        case destinationRect
        case regionRects
        case videoByteCount
        case videoNalUnitTypes
        case bitmapByteCount
        case decodedBitmapBytesPerRow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(frameID, forKey: .frameID)
        try container.encode(surfaceID, forKey: .surfaceID)
        try container.encode(codecID, forKey: .codecID)
        try container.encode(codecName, forKey: .codecName)
        try container.encode(contentKind, forKey: .contentKind)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(videoCodec.displayName, forKey: .videoCodecName)
        try container.encode(pixelFormat, forKey: .pixelFormat)
        try container.encodeIfPresent(graphicsOutputRect, forKey: .graphicsOutputRect)
        try container.encodeIfPresent(surfaceRect, forKey: .surfaceRect)
        try container.encodeIfPresent(mappedOutputRect, forKey: .mappedOutputRect)
        try container.encode(destinationRect, forKey: .destinationRect)
        try container.encode(regionRects, forKey: .regionRects)
        try container.encode(videoByteCount, forKey: .videoByteCount)
        try container.encode(videoNalUnitTypes, forKey: .videoNalUnitTypes)
        try container.encode(bitmapByteCount, forKey: .bitmapByteCount)
        try container.encodeIfPresent(decodedBitmapBytesPerRow, forKey: .decodedBitmapBytesPerRow)
    }
}
