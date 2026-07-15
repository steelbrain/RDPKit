import CoreVideo
import Foundation

struct RDPYUV420Frame: Equatable, Sendable {
    var width: Int
    var height: Int
    var y: [UInt8]
    var u: [UInt8]
    var v: [UInt8]

    init(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8]) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              y.count == width * height,
              u.count == width * height / 4,
              v.count == width * height / 4
        else {
            throw RDPAVC444DecodeError.invalidYUV420Layout
        }
        self.width = width
        self.height = height
        self.y = y
        self.u = u
        self.v = v
    }

    func yValue(x: Int, y: Int) -> Int {
        Int(self.y[y * width + x])
    }

    func uValue(x: Int, y: Int) -> Int {
        Int(u[y * (width / 2) + x])
    }

    func vValue(x: Int, y: Int) -> Int {
        Int(v[y * (width / 2) + x])
    }
}

struct RDPAVC444ReconstructedFrame: Equatable, Sendable {
    var width: Int
    var height: Int
    var bgra: Data
}

final class RDPAVC444FrameStore {
    private struct MainFrameKey: Hashable {
        var surfaceID: UInt16
        var codecID: UInt16
        var left: UInt16
        var top: UInt16
        var right: UInt16
        var bottom: UInt16
    }

    private var mainFrames: [MainFrameKey: RDPYUV420Frame] = [:]

    func reset() {
        mainFrames.removeAll()
    }

    func reconstruct(
        surfaceID: UInt16,
        codecID: UInt16,
        layout: RDPAVC444SubframeLayout,
        firstFrame: RDPYUV420Frame,
        secondFrame: RDPYUV420Frame?,
        destinationRect: RDPFrameRect? = nil,
        chromaRegionRects: [RDPFrameRect] = []
    ) throws -> RDPAVC444ReconstructedFrame {
        let destinationRect = destinationRect ?? RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(clamping: firstFrame.width),
            bottom: UInt16(clamping: firstFrame.height)
        )
        let mainFrameKey = MainFrameKey(
            surfaceID: surfaceID,
            codecID: codecID,
            left: destinationRect.left,
            top: destinationRect.top,
            right: destinationRect.right,
            bottom: destinationRect.bottom
        )
        let mainFrame: RDPYUV420Frame
        let chromaFrame: RDPYUV420Frame?
        switch layout {
        case .yuv420AndChroma420:
            guard let secondFrame else {
                throw RDPAVC444DecodeError.missingChromaSubframe
            }
            mainFrame = firstFrame
            chromaFrame = secondFrame
        case .yuv420Only:
            mainFrame = firstFrame
            chromaFrame = nil
        case .chroma420Only:
            guard let previousMainFrame = mainFrames[mainFrameKey] else {
                throw RDPAVC444DecodeError.missingLumaSubframe
            }
            mainFrame = previousMainFrame
            chromaFrame = firstFrame
        }

        if let chromaFrame,
           chromaFrame.width != mainFrame.width || chromaFrame.height != mainFrame.height
        {
            throw RDPAVC444DecodeError.mismatchedSubframeDimensions
        }

        guard codecID == RDPGFXCodecID.avc444 || codecID == RDPGFXCodecID.avc444v2 else {
            throw RDPAVC444DecodeError.unsupportedCodec(codecID)
        }
        let usesV2Layout = codecID == RDPGFXCodecID.avc444v2
        guard mainFrame.width.isMultiple(of: 16),
              mainFrame.height.isMultiple(of: 16)
        else {
            throw RDPAVC444DecodeError.invalidYUV420Layout
        }
        if layout != .chroma420Only {
            mainFrames[mainFrameKey] = mainFrame
        }
        let chromaMask = chromaFrame.map { _ in
            avc444ChromaMask(
                width: mainFrame.width,
                height: mainFrame.height,
                regionRects: chromaRegionRects
            )
        }
        var bgra = Data(repeating: 0, count: mainFrame.width * mainFrame.height * 4)
        writeAVC444Pixels(
            main: mainFrame,
            auxiliary: chromaFrame,
            chromaMask: chromaMask,
            usesV2Layout: usesV2Layout,
            to: &bgra
        )
        return RDPAVC444ReconstructedFrame(width: mainFrame.width, height: mainFrame.height, bgra: bgra)
    }
}

private func avc444ChromaMask(width: Int, height: Int, regionRects: [RDPFrameRect]) -> Data {
    var mask = Data(repeating: 0, count: width * height)
    mask.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        for rect in regionRects {
            let left = min(width, Int(rect.left))
            let top = min(height, Int(rect.top))
            let right = min(width, Int(rect.right))
            let bottom = min(height, Int(rect.bottom))
            guard right > left, bottom > top else {
                continue
            }
            for row in top ..< bottom {
                memset(baseAddress.advanced(by: row * width + left), 1, right - left)
            }
        }
    }
    return mask
}

private func writeAVC444Pixels(
    main: RDPYUV420Frame,
    auxiliary: RDPYUV420Frame?,
    chromaMask: Data?,
    usesV2Layout: Bool,
    to bgra: inout Data
) {
    main.y.withUnsafeBufferPointer { mainYBuffer in
        main.u.withUnsafeBufferPointer { mainUBuffer in
            main.v.withUnsafeBufferPointer { mainVBuffer in
                guard let mainY = mainYBuffer.baseAddress,
                      let mainU = mainUBuffer.baseAddress,
                      let mainV = mainVBuffer.baseAddress
                else {
                    return
                }
                guard let auxiliary, let chromaMask else {
                    bgra.withUnsafeMutableBytes { outputBuffer in
                        guard let output = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        RDPYUV420PixelWriter(
                            yPlane: mainY,
                            uPlane: mainU,
                            vPlane: mainV,
                            width: main.width,
                            height: main.height,
                            output: output
                        ).write()
                    }
                    return
                }
                auxiliary.y.withUnsafeBufferPointer { auxiliaryYBuffer in
                    auxiliary.u.withUnsafeBufferPointer { auxiliaryUBuffer in
                        auxiliary.v.withUnsafeBufferPointer { auxiliaryVBuffer in
                            chromaMask.withUnsafeBytes { maskBuffer in
                                bgra.withUnsafeMutableBytes { outputBuffer in
                                    guard let auxiliaryY = auxiliaryYBuffer.baseAddress,
                                          let auxiliaryU = auxiliaryUBuffer.baseAddress,
                                          let auxiliaryV = auxiliaryVBuffer.baseAddress,
                                          let mask = maskBuffer.bindMemory(to: UInt8.self).baseAddress,
                                          let output = outputBuffer.bindMemory(to: UInt8.self).baseAddress
                                    else {
                                        return
                                    }
                                    RDPAVC444PixelWriter(
                                        mainY: mainY,
                                        mainU: mainU,
                                        mainV: mainV,
                                        auxiliaryY: auxiliaryY,
                                        auxiliaryU: auxiliaryU,
                                        auxiliaryV: auxiliaryV,
                                        chromaMask: mask,
                                        width: main.width,
                                        height: main.height,
                                        usesV2Layout: usesV2Layout,
                                        output: output
                                    ).write()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RDPYUV420PixelWriter: @unchecked Sendable {
    var yPlane: UnsafePointer<UInt8>
    var uPlane: UnsafePointer<UInt8>
    var vPlane: UnsafePointer<UInt8>
    var width: Int
    var height: Int
    var output: UnsafeMutablePointer<UInt8>

    func write() {
        rdpConcurrentlyProcessRows(height: height) { rows in
            let chromaWidth = width / 2
            for y in rows {
                let lumaRow = y * width
                let chromaRow = (y / 2) * chromaWidth
                for x in 0 ..< width {
                    let chromaIndex = chromaRow + x / 2
                    writeBGRAPixel(
                        y: Int(yPlane[lumaRow + x]),
                        u: Int(uPlane[chromaIndex]),
                        v: Int(vPlane[chromaIndex]),
                        to: output.advanced(by: (lumaRow + x) * 4)
                    )
                }
            }
        }
    }
}

private struct RDPAVC444PixelWriter: @unchecked Sendable {
    var mainY: UnsafePointer<UInt8>
    var mainU: UnsafePointer<UInt8>
    var mainV: UnsafePointer<UInt8>
    var auxiliaryY: UnsafePointer<UInt8>
    var auxiliaryU: UnsafePointer<UInt8>
    var auxiliaryV: UnsafePointer<UInt8>
    var chromaMask: UnsafePointer<UInt8>
    var width: Int
    var height: Int
    var usesV2Layout: Bool
    var output: UnsafeMutablePointer<UInt8>

    func write() {
        rdpConcurrentlyProcessRows(height: height) { rows in
            let chromaWidth = width / 2
            for y in rows {
                let lumaRow = y * width
                let chromaRow = (y / 2) * chromaWidth
                for x in 0 ..< width {
                    let pixelIndex = lumaRow + x
                    let mainChromaIndex = chromaRow + x / 2
                    let chroma = chromaMask[pixelIndex] == 0
                        ? (Int(mainU[mainChromaIndex]), Int(mainV[mainChromaIndex]))
                        : recoveredAVC444Chroma(
                            x: x,
                            y: y,
                            mainU: mainU,
                            mainV: mainV,
                            auxiliaryY: auxiliaryY,
                            auxiliaryU: auxiliaryU,
                            auxiliaryV: auxiliaryV,
                            width: width,
                            usesV2Layout: usesV2Layout
                        )
                    writeBGRAPixel(
                        y: Int(mainY[pixelIndex]),
                        u: chroma.0,
                        v: chroma.1,
                        to: output.advanced(by: pixelIndex * 4)
                    )
                }
            }
        }
    }
}

func rdpConcurrentlyProcessRows(
    height: Int,
    operation: @escaping @Sendable (Range<Int>) -> Void
) {
    let workerCount = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount))
    DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
        let start = height * workerIndex / workerCount
        let end = height * (workerIndex + 1) / workerCount
        operation(start ..< end)
    }
}

private func recoveredAVC444Chroma(
    x: Int,
    y: Int,
    mainU: UnsafePointer<UInt8>,
    mainV: UnsafePointer<UInt8>,
    auxiliaryY: UnsafePointer<UInt8>,
    auxiliaryU: UnsafePointer<UInt8>,
    auxiliaryV: UnsafePointer<UInt8>,
    width: Int,
    usesV2Layout: Bool
) -> (Int, Int) {
    let chromaWidth = width / 2
    let mainIndex = (y / 2) * chromaWidth + x / 2
    if x.isMultiple(of: 2), y.isMultiple(of: 2) {
        let filteredU = Int(mainU[mainIndex])
        let filteredV = Int(mainV[mainIndex])
        let right: (Int, Int)
        let below: (Int, Int)
        let belowRight: (Int, Int)
        if usesV2Layout {
            right = (
                Int(auxiliaryY[y * width + x / 2]),
                Int(auxiliaryY[y * width + width / 2 + x / 2])
            )
            let belowChromaRow = ((y + 1) / 2) * chromaWidth
            let planeX = x / 4
            let planeOffset = width / 4
            if x.isMultiple(of: 4) {
                below = (
                    Int(auxiliaryU[belowChromaRow + planeX]),
                    Int(auxiliaryU[belowChromaRow + planeOffset + planeX])
                )
            } else {
                below = (
                    Int(auxiliaryV[belowChromaRow + planeX]),
                    Int(auxiliaryV[belowChromaRow + planeOffset + planeX])
                )
            }
            belowRight = (
                Int(auxiliaryY[(y + 1) * width + x / 2]),
                Int(auxiliaryY[(y + 1) * width + width / 2 + x / 2])
            )
        } else {
            right = (Int(auxiliaryU[mainIndex]), Int(auxiliaryV[mainIndex]))
            let auxiliaryRow = (y / 16) * 16 + (y + 1) % 16 / 2
            below = (
                Int(auxiliaryY[auxiliaryRow * width + x]),
                Int(auxiliaryY[(auxiliaryRow + 8) * width + x])
            )
            belowRight = (
                Int(auxiliaryY[auxiliaryRow * width + x + 1]),
                Int(auxiliaryY[(auxiliaryRow + 8) * width + x + 1])
            )
        }
        return (
            filteredValue(filteredU, recovered: 4 * filteredU - right.0 - below.0 - belowRight.0),
            filteredValue(filteredV, recovered: 4 * filteredV - right.1 - below.1 - belowRight.1)
        )
    }
    if usesV2Layout {
        if x.isMultiple(of: 2) {
            let planeX = x / 4
            let planeOffset = width / 4
            let auxiliaryIndex = (y / 2) * chromaWidth + planeX
            if x.isMultiple(of: 4) {
                return (
                    Int(auxiliaryU[auxiliaryIndex]),
                    Int(auxiliaryU[auxiliaryIndex + planeOffset])
                )
            }
            return (
                Int(auxiliaryV[auxiliaryIndex]),
                Int(auxiliaryV[auxiliaryIndex + planeOffset])
            )
        }
        return (
            Int(auxiliaryY[y * width + x / 2]),
            Int(auxiliaryY[y * width + width / 2 + x / 2])
        )
    }
    if y.isMultiple(of: 2) {
        return (Int(auxiliaryU[mainIndex]), Int(auxiliaryV[mainIndex]))
    }
    let auxiliaryRow = (y / 16) * 16 + y % 16 / 2
    return (
        Int(auxiliaryY[auxiliaryRow * width + x]),
        Int(auxiliaryY[(auxiliaryRow + 8) * width + x])
    )
}

@inline(__always)
private func writeBGRAPixel(y: Int, u: Int, v: Int, to output: UnsafeMutablePointer<UInt8>) {
    let r = (256 * y + 403 * (v - 128)) >> 8
    let g = (256 * y - 48 * (u - 128) - 120 * (v - 128)) >> 8
    let b = (256 * y + 475 * (u - 128)) >> 8
    output[0] = UInt8(clampedByte(b))
    output[1] = UInt8(clampedByte(g))
    output[2] = UInt8(clampedByte(r))
    output[3] = 255
}

private func filteredValue(_ filtered: Int, recovered: Int) -> Int {
    abs(filtered - recovered) > 30 ? clampedByte(recovered) : filtered
}

private func clampedByte(_ value: Int) -> Int {
    min(max(value, 0), 255)
}

enum RDPAVC444DecodeError: Error, Equatable, CustomStringConvertible {
    case invalidYUV420Layout
    case unsupportedCodec(UInt16)
    case unsupportedPixelFormat(UInt32)
    case missingPixelBufferPlane
    case missingLumaSubframe
    case missingChromaSubframe
    case mismatchedSubframeDimensions
    case coreVideo(operation: String, status: CVReturn)

    var description: String {
        switch self {
        case .invalidYUV420Layout:
            "The decoded AVC444 subframe has an invalid YUV420 layout."
        case let .unsupportedCodec(codecID):
            "Codec \(codecID) does not use an AVC444 subframe layout."
        case let .unsupportedPixelFormat(pixelFormat):
            "The decoded AVC444 subframe has unsupported pixel format \(pixelFormat)."
        case .missingPixelBufferPlane:
            "Core Video did not expose an AVC444 pixel-buffer plane."
        case .missingLumaSubframe:
            "An AVC444 chroma-only update arrived before a luma subframe."
        case .missingChromaSubframe:
            "A combined AVC444 update is missing its chroma subframe."
        case .mismatchedSubframeDimensions:
            "The AVC444 luma and chroma subframes have different dimensions."
        case let .coreVideo(operation, status):
            "Core Video failed to \(operation): \(status)."
        }
    }
}
