import Foundation

/// What to do with the area around the photo's subject.
enum BackgroundStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, white, transparent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: "Keep"
        case .white: "White"
        case .transparent: "Transparent"
        }
    }

    var removesBackground: Bool { self != .keep }

    /// Formats without an alpha channel fall back to white.
    func resolved(for format: OutputFormat) -> BackgroundStyle {
        self == .transparent && !format.supportsAlpha ? .white : self
    }
}

/// Which model finds the subject when a background is removed.
enum SubjectDetector: String, Codable, CaseIterable, Identifiable, Sendable {
    /// BiRefNet when it's downloaded, Apple Vision otherwise.
    case biRefNet
    /// Always Apple Vision: faster, with softer edges.
    case vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .biRefNet: "BiRefNet"
        case .vision: "Apple Vision"
        }
    }
}
