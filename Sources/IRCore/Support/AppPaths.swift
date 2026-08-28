import Foundation

/// Where everything lives on disk.
///
/// The split matters and is visible to the user: documents go somewhere they
/// chose and can open in Finder, while the index, the installed plugins and the
/// logs go in Application Support where they belong. Nothing here is secret —
/// secrets are in the keychain — so this whole tree can be backed up or
/// inspected without exposing anything.
public struct AppPaths: Sendable {
    public let supportDirectory: URL
    public let libraryRoot: URL

    public static let bundleIdentifier = "app.invoicesretriever"

    public init(supportDirectory: URL, libraryRoot: URL) {
        self.supportDirectory = supportDirectory
        self.libraryRoot = libraryRoot
    }

    public static func standard(libraryRoot: URL? = nil) -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Invoices Retriever", isDirectory: true)
        return AppPaths(supportDirectory: support, libraryRoot: libraryRoot ?? documents)
    }

    public var databaseURL: URL { supportDirectory.appendingPathComponent("index.sqlite") }
    public var installedPluginsDirectory: URL { supportDirectory.appendingPathComponent("plugins", isDirectory: true) }
    public var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }

    public func ensureDirectoriesExist() throws {
        for url in [supportDirectory, installedPluginsDirectory, logsDirectory, libraryRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

/// User-facing settings that are not secrets. Stored in the database rather
/// than UserDefaults so that the whole configuration travels with the index.
public struct Preferences: Codable, Sendable, Hashable {
    public var libraryPath: String?
    public var fileNamePattern: String
    public var folderPattern: String
    public var maximumConcurrency: Int
    public var schedulerEnabled: Bool
    public var enableOCR: Bool
    public var enableLLMFallback: Bool
    public var llmProvider: String?
    public var interfaceLanguage: String?
    public var pluginIndexURL: String
    public var lastIndexRevision: Int

    public static let `default` = Preferences(
        libraryPath: nil,
        fileNamePattern: NamingTemplate.default.pattern,
        folderPattern: NamingTemplate.folderDefault.pattern,
        maximumConcurrency: 2,
        schedulerEnabled: false,
        enableOCR: true,
        // F6.4 and M4: off. Turning this on is a decision the user makes with
        // full sight of what would be sent, not a default they inherit.
        enableLLMFallback: false,
        llmProvider: nil,
        interfaceLanguage: nil,
        pluginIndexURL: "https://raw.githubusercontent.com/Invoices-Retriever/plugins/main/dist/index.json",
        lastIndexRevision: 0)

    public static let settingKey = "preferences"

    public static func load(from store: Store) async -> Preferences {
        guard let raw = try? await store.setting(settingKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save(to store: Store) async throws {
        let data = try JSONEncoder().encode(self)
        try await store.setSetting(Self.settingKey, String(decoding: data, as: UTF8.self))
    }
}

/// Resources compiled into IRCore: the JSON Schema contributors validate
/// against, and the plugins that ship with a release.
public enum BundledResources {
    public static var schemaURL: URL? {
        Bundle.module.url(forResource: "Resources/plugin-v1.schema", withExtension: "json")
            ?? Bundle.module.url(forResource: "plugin-v1.schema", withExtension: "json")
    }

    public static var bundledPluginsDirectory: URL? {
        Bundle.module.url(forResource: "Resources/bundled-plugins", withExtension: nil)
            ?? Bundle.module.url(forResource: "bundled-plugins", withExtension: nil)
    }
}
