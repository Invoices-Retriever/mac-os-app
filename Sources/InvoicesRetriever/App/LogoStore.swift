import SwiftUI
import AppKit
import IRCore

/// Suppliers' logos, fetched once and kept.
///
/// A list of grey rectangles all named in the same typeface is genuinely hard
/// to scan; a logo is recognised before it is read, which is most of what makes
/// an interface feel easy to someone who has not used it before.
///
/// **What this does not do is tell anyone which suppliers you use.** Logos are
/// fetched for every plugin in the *catalogue* — a public list, identical for
/// everybody — and never for the sources you happen to have added. The request
/// pattern therefore carries no information about you. They are cached on disk
/// permanently, so the fetch happens once per plugin per machine, and the whole
/// thing can be switched off in Settings.
@Observable
@MainActor
final class LogoStore {

    /// The public logo service. No key, no account, and it answers with a
    /// generated placeholder rather than a 404 for a domain it does not know —
    /// which is why `isGenerated` below exists.
    nonisolated static let endpoint = "https://api.companyenrich.com/logo/"

    private var images: [String: NSImage] = [:]
    /// Domains the service has no logo for. Kept so a miss is not re-fetched on
    /// every launch, and re-checked after a while in case one is added.
    private var misses: [String: Date] = [:]
    private var inFlight: Set<String> = []

    private let directory: URL
    private let session: URLSession
    nonisolated static let missRetryInterval: TimeInterval = 30 * 24 * 60 * 60

    var isEnabled = true

    init(directory: URL = AppPaths.standard().logosDirectory) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    // MARK: - Reading

    /// The logo, if one is already in hand. Never blocks and never fetches:
    /// views call this while drawing, and a view that triggers network traffic
    /// as a side effect of laying out is a view that fetches unpredictably.
    func image(for domain: String?) -> NSImage? {
        guard isEnabled, let domain, !domain.isEmpty else { return nil }
        return images[domain]
    }

    // MARK: - Fetching

    /// Fetches whatever is missing, for the whole catalogue at once.
    ///
    /// Deliberately takes the full list rather than one domain at a time: the
    /// point is that these requests are the same for every user, and asking
    /// lazily as sources appear on screen would leak exactly what asking in a
    /// batch avoids.
    func prefetch(_ domains: [String]) async {
        guard isEnabled else { return }
        let wanted = Set(domains.filter { !$0.isEmpty })
            .filter { images[$0] == nil && !inFlight.contains($0) }
            .filter { miss in
                guard let seen = misses[miss] else { return true }
                return Date().timeIntervalSince(seen) > Self.missRetryInterval
            }
        guard !wanted.isEmpty else { return }

        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }

        await withTaskGroup(of: (String, NSImage?).self) { group in
            for domain in wanted {
                group.addTask { [session] in
                    (domain, await Self.download(domain, session: session))
                }
            }
            for await (domain, image) in group {
                if let image {
                    images[domain] = image
                    misses.removeValue(forKey: domain)
                } else {
                    misses[domain] = Date()
                    try? Data().write(to: missMarker(for: domain))
                }
            }
        }
    }

    private nonisolated static func download(_ domain: String, session: URLSession) async -> NSImage? {
        guard let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: endpoint + encoded) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !isGenerated(response: http, data: data),
              let image = NSImage(data: data), image.size.width > 0 else {
            return nil
        }
        return image
    }

    /// Whether the service made up a placeholder instead of returning a logo.
    ///
    /// It answers 200 either way, so the status code says nothing. A stored
    /// logo carries an `ETag`; a placeholder is rendered on the spot and has
    /// none — that is the signal, checked across known-good and known-bad
    /// domains. The 128×128 PNG check is a second line in case the service
    /// starts sending an entity tag for generated images too: every real logo
    /// seen came back larger than that, and the placeholder is always exactly
    /// that size.
    nonisolated static func isGenerated(response: HTTPURLResponse, data: Data) -> Bool {
        let etag = response.value(forHTTPHeaderField: "ETag")?  // not prose
            .trimmingCharacters(in: .whitespaces) ?? ""
        if etag.isEmpty { return true }
        if let rep = NSBitmapImageRep(data: data),
           rep.pixelsWide == 128, rep.pixelsHigh == 128,
           data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return true
        }
        return false
    }

    // MARK: - Disk

    private func file(for domain: String) -> URL {
        directory.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_") + ".img")
    }

    private func missMarker(for domain: String) -> URL {
        directory.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_") + ".miss")
    }

    private func loadFromDisk() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let domain = entry.deletingPathExtension().lastPathComponent
            switch entry.pathExtension {
            case "img":
                if let data = try? Data(contentsOf: entry), let image = NSImage(data: data) {
                    images[domain] = image
                }
            case "miss":
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                misses[domain] = modified ?? Date()
            default:
                break
            }
        }
    }

    /// Writes what was fetched, so the next launch draws immediately and asks
    /// for nothing.
    func persist() {
        for (domain, image) in images {
            let url = file(for: domain)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: url)
        }
    }

    /// Removes every cached logo, for the Settings switch.
    func clear() {
        images.removeAll()
        misses.removeAll()
        if let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil) {
            for entry in entries { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
