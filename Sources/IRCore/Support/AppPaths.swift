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
    /// nil follows the system. Kept as a string rather than the enum so an
    /// unknown value from a newer build degrades to "follow the system"
    /// instead of failing to decode the whole preferences record.
    public var interfaceLanguage: String?
    public var pluginIndexURL: String
    public var lastIndexRevision: Int

    public init(libraryPath: String?, fileNamePattern: String, folderPattern: String,
                maximumConcurrency: Int, schedulerEnabled: Bool, enableOCR: Bool,
                enableLLMFallback: Bool, llmProvider: String?, interfaceLanguage: String?,
                pluginIndexURL: String, lastIndexRevision: Int) {
        self.libraryPath = libraryPath
        self.fileNamePattern = fileNamePattern
        self.folderPattern = folderPattern
        self.maximumConcurrency = maximumConcurrency
        self.schedulerEnabled = schedulerEnabled
        self.enableOCR = enableOCR
        self.enableLLMFallback = enableLLMFallback
        self.llmProvider = llmProvider
        self.interfaceLanguage = interfaceLanguage
        self.pluginIndexURL = pluginIndexURL
        self.lastIndexRevision = lastIndexRevision
    }

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

    /// Decoding fills in anything the stored record does not carry.
    ///
    /// Without this, adding a preference in a later version would make every
    /// existing record fail to decode, and the user would silently lose every
    /// setting they had ever changed. Tolerating absent keys is what makes a
    /// new field a non-event.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences.default

        libraryPath = try c.decodeIfPresent(String.self, forKey: .libraryPath)
        fileNamePattern = try c.decodeIfPresent(String.self, forKey: .fileNamePattern) ?? fallback.fileNamePattern
        folderPattern = try c.decodeIfPresent(String.self, forKey: .folderPattern) ?? fallback.folderPattern
        maximumConcurrency = try c.decodeIfPresent(Int.self, forKey: .maximumConcurrency) ?? fallback.maximumConcurrency
        schedulerEnabled = try c.decodeIfPresent(Bool.self, forKey: .schedulerEnabled) ?? fallback.schedulerEnabled
        enableOCR = try c.decodeIfPresent(Bool.self, forKey: .enableOCR) ?? fallback.enableOCR
        // Note the fallback: a record that predates this setting must not turn
        // the language-model fallback on by accident.
        enableLLMFallback = try c.decodeIfPresent(Bool.self, forKey: .enableLLMFallback) ?? false
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider)
        interfaceLanguage = try c.decodeIfPresent(String.self, forKey: .interfaceLanguage)
        pluginIndexURL = try c.decodeIfPresent(String.self, forKey: .pluginIndexURL) ?? fallback.pluginIndexURL
        lastIndexRevision = try c.decodeIfPresent(Int.self, forKey: .lastIndexRevision) ?? fallback.lastIndexRevision
    }

    private enum CodingKeys: String, CodingKey {
        case libraryPath, fileNamePattern, folderPattern, maximumConcurrency
        case schedulerEnabled, enableOCR, enableLLMFallback, llmProvider
        case interfaceLanguage, pluginIndexURL, lastIndexRevision
    }

    public static func load(from store: Store) async -> Preferences {
        guard let raw = try? await store.setting(settingKey),
              let data = raw.data(using: .utf8) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            // Should not happen — every field has a default and decoding is
            // tolerant of missing ones — so if it does, say so rather than
            // silently handing the user a fresh set of defaults and letting
            // them wonder where their settings went.
            RedactingLogger.shared.error(
                "could not read saved preferences, falling back to defaults: \(error)")
            return .default
        }
    }

    public func save(to store: Store) async throws {
        let data = try JSONEncoder().encode(self)
        try await store.setSetting(Self.settingKey, String(decoding: data, as: UTF8.self))
    }
}

/// Resources compiled into IRCore: the JSON Schema contributors validate
/// against, and the plugins that ship with a release.
public enum BundledResources {
    /// IRCore's own resource bundle. `Bundle.module` is internal to the module
    /// that owns it, so anything outside — the test suite checking the string
    /// catalogues, for one — needs this door.
    public static var bundle: Bundle { .module }

    public static var schemaURL: URL? {
        Bundle.module.url(forResource: "Resources/plugin-v1.schema", withExtension: "json")
            ?? Bundle.module.url(forResource: "plugin-v1.schema", withExtension: "json")
    }

    public static var bundledPluginsDirectory: URL? {
        Bundle.module.url(forResource: "Resources/bundled-plugins", withExtension: nil)
            ?? Bundle.module.url(forResource: "bundled-plugins", withExtension: nil)
    }
}
