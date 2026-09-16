import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, audio, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        }
    }

    var pluralTitle: String {
        switch self {
        case .video: "Videos"
        case .audio: "Audio"
        case .image: "Images"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }
}
