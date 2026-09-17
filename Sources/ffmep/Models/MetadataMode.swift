import Foundation

enum MetadataMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, removeLocation, removeAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: "Keep"
        case .removeLocation: "Remove Location"
        case .removeAll: "Remove All"
        }
    }

    static func choices(for kind: MediaKind) -> [MetadataMode] {
        kind == .audio ? [.keep, .removeAll] : allCases
    }
}

/// The kinds of metadata ffmep can tell apart, used to report what a conversion left out.
enum MetadataCategory: String, CaseIterable, Sendable {
    case location, date, camera, serialNumber, owner, trackInfo, artwork

    var title: String {
        switch self {
        case .location: "location"
        case .date: "date"
        case .camera: "camera"
        case .serialNumber: "serial number"
        case .owner: "owner"
        case .trackInfo: "track info"
        case .artwork: "artwork"
        }
    }

    /// "Removed location, date and serial number", in `allCases` order.
    static func removedSummary(_ categories: [MetadataCategory]) -> String? {
        let ordered = allCases.filter(categories.contains)
        guard !ordered.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: ordered.map(\.title))
        return "Removed \(list)"
    }
}
