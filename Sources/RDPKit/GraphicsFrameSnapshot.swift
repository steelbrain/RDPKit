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
    /// A copy among the decoder's own surfaces and cache, in ``RDPGraphicsFrameSnapshot/surfaceCopy``.
    case surfaceCopy
}

/// A copy the decoder makes itself ([MS-RDPEGFX] 2.2.2.6-2.2.2.8) because the copied area
/// holds pixels only the decoder has: video it decoded, or pixels such a copy put there.
/// The session copies every other area itself and sends it in bitmap snapshots.
public struct RDPGraphicsSurfaceCopy: Encodable, Equatable, Sendable {
    public enum Location: Encodable, Equatable, Sendable {
        case surface(UInt16)
        case cacheSlot(UInt16)
    }

    /// A rectangle of the source, in its coordinates, and where it goes, in the destination's.
    public struct Block: Encodable, Equatable, Sendable {
        public var source: RDPFrameRect
        public var destination: RDPFrameRect

        public init(source: RDPFrameRect, destination: RDPFrameRect) {
            self.source = source
            self.destination = destination
        }
    }

    public var source: Location
    public var destination: Location
    /// Every block copies the source as it was before the copy, so blocks may overlap.
    public var blocks: [Block]

    public init(source: Location, destination: Location, blocks: [Block]) {
        self.source = source
        self.destination = destination
        self.blocks = blocks
    }
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
    /// Surfaces the server deleted ([MS-RDPEGFX] 2.2.2.10) since the previous
    /// snapshot. A decoder drops what it kept for them before using this frame,
    /// whose surface ID may name a new surface.
    public var deletedSurfaceIDs: [UInt16]
    /// The copy to make when ``contentKind`` is ``RDPGraphicsFrameContentKind/surfaceCopy``.
    public var surfaceCopy: RDPGraphicsSurfaceCopy?
    /// Cache slots a ``surfaceCopy`` stored into that the server has since evicted or
    /// refilled without one. A decoder drops them before using this frame.
    public var evictedCacheSlots: [UInt16]

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
        decodedBitmapBytesPerRow: Int? = nil,
        deletedSurfaceIDs: [UInt16] = [],
        surfaceCopy: RDPGraphicsSurfaceCopy? = nil,
        evictedCacheSlots: [UInt16] = []
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
        self.deletedSurfaceIDs = deletedSurfaceIDs
        self.surfaceCopy = surfaceCopy
        self.evictedCacheSlots = evictedCacheSlots
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
        case surfaceCopy
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
        try container.encodeIfPresent(surfaceCopy, forKey: .surfaceCopy)
    }
}

extension RDPGraphicsFrameSnapshot {
    /// Whether a video update's region rectangles are relative to `destinationRect`.
    /// Servers send them so or in surface coordinates; all of them fitting the
    /// destination's size reads as relative.
    var hasRelativeRegions: Bool {
        (regionRects + auxiliaryRegionRects).allSatisfy {
            $0.right <= destinationRect.width && $0.bottom <= destinationRect.height
        }
    }

    /// `region`, one of this update's, in surface coordinates.
    func surfaceRegion(_ region: RDPFrameRect, relative: Bool) -> RDPFrameRect {
        guard relative else {
            return region
        }
        return RDPFrameRect(
            left: destinationRect.left &+ region.left,
            top: destinationRect.top &+ region.top,
            right: destinationRect.left &+ region.right,
            bottom: destinationRect.top &+ region.bottom
        )
    }

    /// The surface areas a video update writes: its region rectangles, or the whole
    /// destination when it lists none.
    var videoSurfaceRegions: [RDPFrameRect] {
        let regions = regionRects + auxiliaryRegionRects
        guard !regions.isEmpty else {
            return [destinationRect]
        }
        let relative = hasRelativeRegions
        return regions.map { surfaceRegion($0, relative: relative) }
    }
}
