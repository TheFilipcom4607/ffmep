import Foundation

enum SaveLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `replaceOriginal` writes next to the original, then moves the original to the Trash.
    case nextToOriginal, folder, replaceOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextToOriginal: "Next to Originals"
        case .folder: "Folder"
        case .replaceOriginal: "Replace Originals"
        }
    }
}

enum OutputNaming {
    static func directory(for source: URL, location: SaveLocation, folder: URL?) -> URL {
        if location == .folder, let folder { return folder }
        return source.deletingLastPathComponent()
    }

    /// `name.ext`, then `name (1).ext`, `name (2).ext`… until `isTaken` says the slot is free.
    static func uniqueURL(in directory: URL, baseName: String, ext: String, isTaken: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var n = 1
        while isTaken(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Hidden sibling the encoder writes into; renamed to the final name on success.
    static func partialURL(for final: URL) -> URL {
        let base = final.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        return final.deletingLastPathComponent()
            .appendingPathComponent(".\(base).ffmep-\(token).\(final.pathExtension)")
    }
}

/// Hands out output names so concurrent jobs never pick the same file,
/// and nothing (including the source) is ever overwritten.
actor OutputReservations {
    private var reserved: Set<String> = []

    func reserve(source: URL, directory: URL, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let url = OutputNaming.uniqueURL(in: directory, baseName: base, ext: ext) { candidate in
            // APFS is case-insensitive by default, so compare lowercased paths.
            reserved.contains(candidate.path.lowercased())
                || FileManager.default.fileExists(atPath: candidate.path)
        }
        reserved.insert(url.path.lowercased())
        return url
    }

    func release(_ url: URL) {
        reserved.remove(url.path.lowercased())
    }

    /// Once the original is gone, renames the output to the original's name if that slot is free,
    /// so replacing IMG_1.jpg yields IMG_1.jpg rather than IMG_1 (1).jpg.
    func takeOriginalName(of source: URL, output: URL) -> URL {
        let desired = output.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(output.pathExtension)
        guard desired.path.lowercased() != output.path.lowercased(),
              !reserved.contains(desired.path.lowercased()),
              !FileManager.default.fileExists(atPath: desired.path)
        else { return output }
        do {
            try FileManager.default.moveItem(at: output, to: desired)
            return desired
        } catch {
            return output
        }
    }

    /// Moves a finished partial file into place, picking a new name if the slot got taken meanwhile.
    func commit(partial: URL, to final: URL, source: URL) throws -> URL {
        var destination = final
        if FileManager.default.fileExists(atPath: destination.path) {
            reserved.remove(final.path.lowercased())
            destination = reserve(source: source, directory: final.deletingLastPathComponent(), ext: final.pathExtension)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        reserved.remove(destination.path.lowercased())
        return destination
    }
}
