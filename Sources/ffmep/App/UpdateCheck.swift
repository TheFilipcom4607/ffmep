import Foundation
import Observation

/// Asks GitHub once a day whether a newer release exists. The only thing that leaves the machine is
/// the request itself, and Settings › General › Check Automatically stops even that.
@MainActor
@Observable
final class UpdateCheck {
    struct Release: Equatable, Sendable {
        /// The tag without its leading "v", e.g. "1.1.0".
        var version: String
    }

    enum Outcome: Equatable {
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// Set when GitHub's newest release is newer than the copy that's running.
    private(set) var available: Release?
    private(set) var isChecking = false

    /// Always the newest release, whatever it turns out to be by the time the link is clicked.
    static let releasePage = URL(string: "https://github.com/TheFilipcom4607/ffmep/releases/latest")!
    private static var endpoint: URL {
        var repo = "TheFilipcom4607/ffmep"
        #if DEBUG
        // `--args -FFMEPUpdateRepo owner/name` tries the check against a repository that has releases.
        if let override = UserDefaults.standard.string(forKey: "FFMEPUpdateRepo") { repo = override }
        #endif
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }
    private static let interval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let lastCheck = "lastUpdateCheck"
        static let lastSeen = "lastSeenRelease"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Settings can be opened before the day's check has run, so start from what the last one found.
        if let seen = defaults.string(forKey: Keys.lastSeen), Self.isNewer(seen, than: Bundle.ffmepShortVersion) {
            available = Release(version: seen)
        }
    }

    /// The background check, at most once a day. Silent either way: the answer only ever shows up as
    /// a row in Settings › About.
    func checkIfDue(enabled: Bool) {
        guard enabled, !isChecking else { return }
        let last = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { _ = await check() }
    }

    /// Asks GitHub now, whatever the toggle and the clock say. The menu item goes through here.
    @discardableResult
    func check() async -> Outcome {
        isChecking = true
        defer { isChecking = false }
        do {
            let tag = try await fetchLatestTag()
            // Only a real answer resets the clock, so a check made offline tries again next launch.
            defaults.set(Date(), forKey: Keys.lastCheck)
            guard let tag else {
                defaults.removeObject(forKey: Keys.lastSeen)
                available = nil
                return .upToDate
            }
            defaults.set(tag, forKey: Keys.lastSeen)
            guard Self.isNewer(tag, than: Bundle.ffmepShortVersion) else {
                available = nil
                return .upToDate
            }
            let release = Release(version: tag)
            available = release
            return .available(release)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Nil when the repository has no releases at all, which is not a failure: nothing is newer.
    private func fetchLatestTag() async throws -> String? {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub turns away requests that don't introduce themselves.
        request.setValue("ffmep/\(Bundle.ffmepShortVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.unreachable }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.unreachable }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError.unreachable
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: Comparing versions

    /// Compares dotted numbers, so 1.10.0 lands above 1.9.0 where a string comparison wouldn't.
    /// Anything that isn't a plain run of numbers — "dev", or a tag like 1.1.0-beta — counts as not
    /// newer, which errs towards staying quiet.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(current) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
}

enum UpdateError: LocalizedError {
    case unreachable

    var errorDescription: String? {
        switch self {
        case .unreachable: "GitHub didn’t answer."
        }
    }
}
