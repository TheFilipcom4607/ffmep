import Foundation

/// The app's saved preferences, read (never written) by the command line: presets, the inspector's
/// settings, the ffmpeg choice and the queue limits.
struct StoredPreferences {
    var presets: [Preset] = []
    var batch = BatchSettings()
    var limits = ConcurrencyLimits.default
    var ffmpegSource = FFmpegSource.bundled
    var customFFmpegPath = ""

    static let bundleIdentifier = "com.filip.ffmep"

    /// Inside the app the standard defaults are the app's. Run unbundled (`swift run ffmep convert …`),
    /// they'd belong to a bare `ffmep` domain, so the app's domain is named instead.
    static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == bundleIdentifier { return .standard }
        return UserDefaults(suiteName: bundleIdentifier) ?? .standard
    }

    static func load(from defaults: UserDefaults = Self.defaults) -> StoredPreferences {
        typealias Keys = AppState.Keys
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        var prefs = StoredPreferences()
        // Before the app's first launch there's no saved list yet, and the app would start with the examples.
        prefs.presets = decode([Preset].self, Keys.presets) ?? Preset.examples
        prefs.batch = decode(BatchSettings.self, Keys.batch) ?? prefs.batch
        prefs.limits = decode(ConcurrencyLimits.self, Keys.limits) ?? prefs.limits
        prefs.ffmpegSource = defaults.string(forKey: Keys.ffmpegSource).flatMap(FFmpegSource.init(rawValue:)) ?? .bundled
        prefs.customFFmpegPath = defaults.string(forKey: Keys.customPath) ?? ""
        return prefs
    }

    /// Presets with this name, matched like the app's save does: ignoring case.
    func presets(named name: String) -> [Preset] {
        presets.filter { $0.name.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}
