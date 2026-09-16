import Foundation
import ImageIO

/// Detects Live Photos: a still image plus a video of the same name, written by Apple devices.
enum LivePhoto {
    static let videoExtensions: Set<String> = ["mov", "mp4"]

    /// Apple stores a content identifier in the MakerApple dictionary of a Live Photo still.
    static func isLivePhotoStill(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return false }
        return maker["17"] != nil
    }

    /// Directory + file name without extension, lowercased, used to match the pair.
    static func pairingKey(_ url: URL) -> String {
        url.deletingPathExtension().path.lowercased()
    }

    static func isPairableVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
