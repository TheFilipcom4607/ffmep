import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageIOError: LocalizedError {
    case unreadable
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "macOS can't read this image"
        case .encodeFailed(let format): "Couldn't encode \(format)"
        }
    }
}

/// A decoded image that is already oriented, resized and rotated, plus the source metadata.
struct PreparedImage: @unchecked Sendable {
    var image: CGImage
    var properties: [CFString: Any]
}

/// Native Apple ImageIO path: fast HEIC/JPEG/PNG decode and JPEG/PNG/HEIC encode.
enum ImageIOConverter {
    static func canRead(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    static let canWriteHEIC: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }()

    /// Display dimensions (EXIF orientation applied).
    static func displaySize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// `applyResize: false` decodes at full size, for callers that resize after processing
    /// (background removal needs the original pixels).
    static func prepare(url: URL, settings: ConversionSettings, applyResize: Bool = true) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ImageIOError.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let pixelW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let (displayW, displayH) = orientation >= 5 ? (pixelH, pixelW) : (pixelW, pixelH)
        let targetSize = applyResize ? ResizeMath.target(width: displayW, height: displayH, settings: settings, even: false) : nil

        var image: CGImage?
        if orientation == 1, targetSize == nil {
            // Full decode keeps bit depth (e.g. 16-bit PNG).
            image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            // The thumbnail API applies orientation and downsamples during decode (fast for HEIC/JPEG).
            let maxEdge = targetSize.map { max($0.width, $0.height) } ?? max(displayW, displayH)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxEdge, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
        guard var result = image else { throw ImageIOError.unreadable }

        if settings.rotation != .none || settings.flipHorizontal || settings.flipVertical {
            result = try transform(result, rotation: settings.rotation, flipH: settings.flipHorizontal, flipV: settings.flipVertical)
        }
        return PreparedImage(image: result, properties: props)
    }

    /// High-quality downscale, used after background removal.
    static func resize(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage {
        guard let context = context(width: size.width, height: size.height, like: image, forceSRGB: false) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }

    /// Rotation first, then flips — same order as the ffmpeg filter chain.
    static func transform(_ image: CGImage, rotation: Rotation, flipH: Bool, flipV: Bool) throws -> CGImage {
        let w = image.width, h = image.height
        let (outW, outH) = rotation.swapsDimensions ? (h, w) : (w, h)
        guard let ctx = context(width: outW, height: outH, like: image, forceSRGB: false) else {
            throw ImageIOError.encodeFailed("rotated image")
        }
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CoreGraphics is y-up: positive angles turn counter-clockwise on screen.
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        switch rotation {
        case .none: break
        case .cw90: ctx.rotate(by: -.pi / 2)
        case .ccw90: ctx.rotate(by: .pi / 2)
        case .r180: ctx.rotate(by: .pi)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { throw ImageIOError.encodeFailed("rotated image") }
        return out
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func context(width: Int, height: Int, like image: CGImage, forceSRGB: Bool) -> CGContext? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = forceSRGB ? sRGB : (image.colorSpace ?? sRGB)
        if space.model != .rgb { space = sRGB }
        let alpha: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: alpha.rawValue)
    }

    /// Encodes to JPEG/PNG/HEIC in memory. `quality` is 0…1 for lossy formats.
    static func encode(_ prepared: PreparedImage, format: OutputFormat, quality: Double?, stripMetadata: Bool) throws -> Data {
        let type: UTType
        switch format {
        case .jpeg: type = .jpeg
        case .png: type = .png
        case .heic: type = .heic
        default: throw ImageIOError.encodeFailed(format.title)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageIOError.encodeFailed(format.title)
        }
        var props: [CFString: Any] = [:]
        if !stripMetadata {
            props = metadata(from: prepared.properties, width: prepared.image.width, height: prepared.image.height)
        }
        if let quality, format != .png {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, prepared.image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageIOError.encodeFailed(format.title) }
        return data as Data
    }

    /// Keeps EXIF/GPS/TIFF/IPTC; orientation is reset because pixels are already upright.
    private static func metadata(from source: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = source[key] { props[key] = value }
        }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            props[kCGImagePropertyExifDictionary] = exif
        }
        return props
    }

    /// Uncompressed 8-bit sRGB TIFF for ffmpeg (which ignores ICC profiles, so colours are converted here).
    static func writeBitmapForFFmpeg(_ prepared: PreparedImage, to url: URL) throws {
        let src = prepared.image
        guard let ctx = context(width: src.width, height: src.height, like: src, forceSRGB: true) else {
            throw ImageIOError.encodeFailed("bitmap")
        }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ImageIOError.encodeFailed("bitmap")
        }
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageIOError.encodeFailed("bitmap") }
    }
}
