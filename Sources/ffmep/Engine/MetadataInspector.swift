import Foundation
import ImageIO

/// Sorts image properties and ffprobe tags into `MetadataCategory`s, so a conversion can report
/// what was in the original but isn't in the result.
enum MetadataInspector {
    // MARK: Images

    static func categories(ofImageAt url: URL) -> Set<MetadataCategory>? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any]
        else { return nil }
        return categories(ofImage: props)
    }

    static func categories(ofImage props: [CFString: Any]) -> Set<MetadataCategory> {
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        func any(_ dict: [CFString: Any], _ keys: [CFString]) -> Bool {
            keys.contains { hasValue(dict[$0]) }
        }

        var found = Set<MetadataCategory>()
        if any(gps, [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitude])
            || any(iptc, [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                          kCGImagePropertyIPTCCountryPrimaryLocationName]) {
            found.insert(.location)
        }
        if any(exif, [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized])
            || any(tiff, [kCGImagePropertyTIFFDateTime]) || any(iptc, [kCGImagePropertyIPTCDateCreated]) {
            found.insert(.date)
        }
        if any(tiff, [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel])
            || any(exif, [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel])
            || any(aux, [kCGImagePropertyExifAuxLensModel]) {
            found.insert(.camera)
        }
        if any(exif, [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber])
            || any(aux, [kCGImagePropertyExifAuxSerialNumber, kCGImagePropertyExifAuxLensSerialNumber]) {
            found.insert(.serialNumber)
        }
        if any(tiff, [kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright])
            || any(exif, [kCGImagePropertyExifCameraOwnerName])
            || any(iptc, [kCGImagePropertyIPTCByline, kCGImagePropertyIPTCCopyrightNotice]) {
            found.insert(.owner)
        }
        return found
    }

    /// IPTC fields that describe where a photo was taken, dropped along with GPS by Remove Location.
    static let iptcLocationKeys: [CFString] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
    ]

    private static func hasValue(_ value: Any?) -> Bool {
        switch value {
        case nil: false
        case let string as String: !string.trimmingCharacters(in: .whitespaces).isEmpty
        case let array as [Any]: !array.isEmpty
        default: true
        }
    }

    // MARK: Video & audio

    /// The category of one ffprobe tag, or nil for technical tags like `encoder` or `handler_name`.
    /// Handles QuickTime keys (`com.apple.quicktime.location.ISO6709`) and language suffixes (`location-eng`).
    static func category(forTag key: String) -> MetadataCategory? {
        var name = key.lowercased()
        if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) == 4 {
            name = String(name[..<dash])
        }
        if name.contains("location") || name.contains("gps") || name.contains("iso6709") { return .location }
        if name.contains("serial") { return .serialNumber }
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        switch leaf {
        case "creation_time", "creationdate", "date", "date_recorded":
            return .date
        case "make", "model", "manufacturer", "lens_model", "camera":
            return .camera
        case "author", "copyright", "owner":
            return .owner
        case "title", "artist", "album", "album_artist", "genre", "composer":
            return .trackInfo
        default:
            return nil
        }
    }

    static func categories(ofTags keys: some Sequence<String>) -> Set<MetadataCategory> {
        Set(keys.compactMap(category(forTag:)))
    }
}
