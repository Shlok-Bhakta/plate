// Meal photos for AI logging, prepared on the phone: scaled to a 1024 px long edge, upright, and
// re-encoded as a fresh JPEG (quality 0.7, about 150 to 250 KB) with no metadata, so no EXIF, GPS, maker notes or
// thumbnails leave the phone. Also the digit filter for barcodes Vision finds in the photo.
// ImageIO and CoreGraphics only (both on macOS too), so the logic tests run these on the Mac.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AgentImage {
    static let maxEdge = 1024
    /// 1024 px at 0.7 is usually 150 to 250 KB: plenty for a model to read a plate, and quick to send.
    static let quality = 0.7
    /// A busy photo past this is encoded again a little lower (down to `floorQuality`), to keep uploads small.
    static let targetBytes = 300_000
    static let floorQuality = 0.5
    /// The server takes at most 1.5 MB decoded.
    static let maxBytes = 1_500_000

    /// The size an image of `width` × `height` scales to so its long edge is at most `maxEdge`; smaller
    /// images keep their size. Never zero.
    static func fittedSize(width: Int, height: Int, maxEdge: Int = maxEdge) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let long = max(width, height)
        guard long > maxEdge else { return (width, height) }
        let scale = Double(maxEdge) / Double(long)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// An upright CGImage of any ImageIO format (JPEG, HEIC, PNG), at most `maxEdge` on its long side. The
    /// EXIF orientation is applied to the pixels, so the result needs no orientation tag.
    static func uprightImage(_ data: Data, maxEdge: Int = maxEdge) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A JPEG of `image` with nothing but pixels: no properties are passed, so ImageIO writes no EXIF, GPS
    /// or TIFF dictionaries.
    static func encodeJPEG(_ image: CGImage, quality: Double = quality) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The photo the server gets: 1024 px long edge, upright, re-encoded without metadata, under 1.5 MB.
    static func prepare(_ data: Data, maxEdge: Int = maxEdge, quality: Double = quality) -> Data? {
        guard let image = uprightImage(data, maxEdge: maxEdge) else { return nil }
        return prepare(image: image, quality: quality)
    }

    static func prepare(image: CGImage, quality: Double = quality) -> Data? {
        var image = image
        if max(image.width, image.height) > maxEdge, let data = encodeJPEG(image, quality: 1),
           let smaller = uprightImage(data, maxEdge: maxEdge) {
            image = smaller
        }
        var q = quality
        while let jpeg = encodeJPEG(image, quality: q) {
            if jpeg.count <= targetBytes || (q <= floorQuality + 0.001 && jpeg.count <= maxBytes) || q <= 0.3 { return jpeg }
            q -= q > floorQuality + 0.001 ? 0.1 : 0.15
        }
        return nil
    }

    /// The metadata dictionaries ImageIO reads back (for tests and debugging): "{Exif}", "{GPS}", ….
    static func metadataKeys(_ data: Data) -> Set<String> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        return Set(props.keys)
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    /// Product barcodes worth sending: digits only, 6 to 14 long (what `GET /v1/barcode` takes), deduped
    /// in order. QR codes, URLs and short numbers on labels are dropped.
    static func barcodeDigits(_ payloads: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in payloads {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (6...14).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }), !seen.contains(p) else { continue }
            seen.insert(p)
            out.append(p)
        }
        return out
    }
}
