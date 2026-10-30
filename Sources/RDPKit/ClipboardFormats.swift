import CoreGraphics
import Foundation
import ImageIO

/// Clipboard content in the formats RDPKit exchanges with the server besides files:
/// Unicode text, HTML, RTF and a bitmap ([MS-RDPECLIP] 1.3.1.2, Standard Clipboard
/// Formats). A copy offers every format it has, and the other side picks one.
public struct RDPClipboardContent: Equatable, Sendable {
    public var text: String?
    /// An HTML document or fragment. It travels in the Windows "HTML Format"
    /// (CF_HTML) envelope, which RDPKit adds and removes.
    public var html: String?
    /// Rich Text Format bytes, as Windows' "Rich Text Format" and Apple's RTF hold them.
    public var richText: Data?
    /// A device-independent bitmap (CF_DIB): a BITMAPINFO and the pixels, with no
    /// BITMAPFILEHEADER. `RDPClipboardBitmap` converts it to and from `CGImage`.
    public var bitmap: Data?

    public init(text: String? = nil, html: String? = nil, richText: Data? = nil, bitmap: Data? = nil) {
        self.text = text
        self.html = html
        self.richText = richText
        self.bitmap = bitmap
    }

    public var isEmpty: Bool {
        text == nil && html == nil && richText == nil && bitmap == nil
    }
}

/// Converts between `CGImage` and the CF_DIB clipboard format.
public enum RDPClipboardBitmap {
    private static let infoHeaderByteCount = 40
    private static let fileHeaderByteCount = 14

    /// A 32-bit BI_RGB DIB of the image, bottom-up, with premultiplied alpha in the
    /// fourth byte; Windows apps that ignore alpha read the same pixels. Nil for an image
    /// of 4 GiB or more, whose size biSizeImage cannot hold.
    public static func deviceIndependentBitmap(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              height <= Int(UInt32.max) / bytesPerRow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let pixels = context.data
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var data = Data()
        data.reserveCapacity(infoHeaderByteCount + bytesPerRow * height)
        data.appendLittleEndianUInt32(UInt32(infoHeaderByteCount))
        data.appendLittleEndianUInt32(UInt32(width))
        // A positive height is a bottom-up DIB, which every reader handles.
        data.appendLittleEndianUInt32(UInt32(height))
        data.appendLittleEndianUInt16(1) // biPlanes
        data.appendLittleEndianUInt16(32) // biBitCount
        data.appendLittleEndianUInt32(0) // BI_RGB
        data.appendLittleEndianUInt32(UInt32(bytesPerRow * height))
        data.appendLittleEndianUInt32(2835) // 72 DPI
        data.appendLittleEndianUInt32(2835)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        // CGContext rows run top-down, so they are written last to first.
        let rows = UnsafeRawBufferPointer(start: pixels, count: bytesPerRow * height)
        for row in stride(from: height - 1, through: 0, by: -1) {
            data.append(contentsOf: rows[row * bytesPerRow ..< (row + 1) * bytesPerRow])
        }
        return data
    }

    /// The image in a CF_DIB or CF_DIBV5, read by ImageIO's BMP decoder. Nil when the
    /// data is not a bitmap ImageIO can decode.
    public static func image(fromDeviceIndependentBitmap data: Data) -> CGImage? {
        guard let pixelOffset = pixelOffset(of: data) else {
            return nil
        }
        // A DIB is a BMP file without its BITMAPFILEHEADER.
        var file = Data("BM".utf8)
        file.appendLittleEndianUInt32(UInt32(fileHeaderByteCount + data.count))
        file.appendLittleEndianUInt32(0)
        file.appendLittleEndianUInt32(UInt32(fileHeaderByteCount + pixelOffset))
        file.append(data)
        guard let source = CGImageSourceCreateWithData(file as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Where the pixels start: after the header, the color masks of a BI_BITFIELDS
    /// BITMAPINFOHEADER, and the color table.
    private static func pixelOffset(of data: Data) -> Int? {
        var cursor = ByteCursor(data)
        guard let headerSize = try? Int(cursor.readLittleEndianUInt32()),
              headerSize >= infoHeaderByteCount, headerSize <= data.count,
              (try? cursor.readData(count: 10)) != nil,
              let bitCount = try? Int(cursor.readLittleEndianUInt16()),
              let compression = try? cursor.readLittleEndianUInt32(),
              (try? cursor.readData(count: 12)) != nil,
              let colorsUsed = try? Int(cursor.readLittleEndianUInt32()),
              colorsUsed <= 256
        else {
            return nil
        }
        var offset = headerSize
        if headerSize == infoHeaderByteCount {
            switch compression {
            case 3: offset += 12 // BI_BITFIELDS
            case 6: offset += 16 // BI_ALPHABITFIELDS
            default: break
            }
        }
        if bitCount <= 8 {
            offset += (colorsUsed == 0 ? 1 << bitCount : colorsUsed) * 4
        } else {
            offset += colorsUsed * 4
        }
        return offset <= data.count ? offset : nil
    }
}

/// The Windows "HTML Format" clipboard envelope (CF_HTML): a header of byte offsets,
/// then UTF-8 HTML with the copied fragment between comment markers.
enum RDPClipboardHTML {
    private static let startFragmentMarker = "<!--StartFragment-->"
    private static let endFragmentMarker = "<!--EndFragment-->"

    /// `html` in the envelope. A whole document keeps its head, with the body as the
    /// fragment; anything else is wrapped in `<html><body>`.
    static func encoded(_ html: String) -> Data {
        let document: String
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive),
           let bodyOpenEnd = html.range(of: ">", range: bodyStart.upperBound ..< html.endIndex),
           let bodyEnd = html.range(of: "</body", options: [.caseInsensitive, .backwards]),
           bodyOpenEnd.upperBound <= bodyEnd.lowerBound
        {
            document = String(html[..<bodyOpenEnd.upperBound]) + startFragmentMarker
                + html[bodyOpenEnd.upperBound ..< bodyEnd.lowerBound] + endFragmentMarker
                + html[bodyEnd.lowerBound...]
        } else {
            document = "<html><body>" + startFragmentMarker + html + endFragmentMarker + "</body></html>"
        }
        let documentBytes = Data(document.utf8)
        let fragmentStart = document.utf8.count - (document.range(of: startFragmentMarker).map {
            document[$0.upperBound...].utf8.count
        } ?? 0)
        let fragmentEnd = document.range(of: endFragmentMarker, options: .backwards).map {
            document[..<$0.lowerBound].utf8.count
        } ?? documentBytes.count

        // Every offset is ten digits, so the header has the same length whatever they are.
        func header(startHTML: Int) -> String {
            "Version:0.9\r\n"
                + "StartHTML:\(digits(startHTML))\r\n"
                + "EndHTML:\(digits(startHTML + documentBytes.count))\r\n"
                + "StartFragment:\(digits(startHTML + fragmentStart))\r\n"
                + "EndFragment:\(digits(startHTML + fragmentEnd))\r\n"
        }
        let startHTML = header(startHTML: 0).utf8.count
        var data = Data(header(startHTML: startHTML).utf8)
        data.append(documentBytes)
        data.appendUInt8(0)
        return data
    }

    /// The HTML in an envelope: the document between StartHTML and EndHTML, else the
    /// fragment, else everything after the header. Nil when it is not UTF-8.
    static func decoded(_ data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        var offsets: [String: Int] = [:]
        var headerEnd = bytes.startIndex
        // Header lines are "Name:value" and end in CRLF; the first line that is not
        // one, such as the "<html>" that follows, ends the header.
        while headerEnd < bytes.endIndex {
            let lineEnd = bytes[headerEnd...].firstIndex { $0 == 0x0D || $0 == 0x0A } ?? bytes.endIndex
            guard let line = String(data: bytes[headerEnd ..< lineEnd], encoding: .utf8),
                  !line.hasPrefix("<"),
                  let colon = line.firstIndex(of: ":")
            else {
                break
            }
            if let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                offsets[String(line[..<colon])] = value
            }
            headerEnd = bytes[lineEnd...].firstIndex { $0 != 0x0D && $0 != 0x0A } ?? bytes.endIndex
        }
        for (start, end) in [("StartHTML", "EndHTML"), ("StartFragment", "EndFragment")] {
            if let lower = offsets[start], let upper = offsets[end], lower >= 0, lower <= upper, upper <= bytes.count,
               let html = String(data: bytes[bytes.startIndex + lower ..< bytes.startIndex + upper], encoding: .utf8)
            {
                return html
            }
        }
        return String(data: bytes[headerEnd...], encoding: .utf8)
    }

    private static func digits(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 10 - text.count)) + text
    }
}

/// RTF on the wire is NUL-terminated, as Windows apps write it.
enum RDPClipboardRichText {
    static func encoded(_ rtf: Data) -> Data {
        var data = rtf
        if data.last != 0 {
            data.appendUInt8(0)
        }
        return data
    }

    static func decoded(_ data: Data) -> Data {
        Data(data.prefix { $0 != 0 })
    }
}
