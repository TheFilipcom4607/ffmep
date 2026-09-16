import SwiftUI

extension View {
    /// Liquid Glass button on macOS 26, bordered button on macOS 14–15.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

extension Bundle {
    /// Shown in Settings › About, e.g. "Version 1.0.0 (20260916.1612)".
    static var ffmepVersion: String {
        let version = main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }
}
