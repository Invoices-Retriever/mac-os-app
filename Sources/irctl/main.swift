import Foundation
import AppKit
import IRCore
import IRBrowser

/// `irctl` — the plugin author's tool.
///
/// The specification puts a number on contributor experience: a simple plugin
/// in under thirty minutes. A graphical debugger is part of that, but a command
/// you can run in a loop while editing JSON in your own editor is what actually
/// makes the iteration fast, and it is what CI runs too. Same validator, same
/// engine, same errors as the app.
@main
@MainActor
struct IRCTL {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(2)
        }

        do {
            switch command {
            case "validate":
                try await validate(Array(arguments.dropFirst()))
            case "lint":
                try await validate(Array(arguments.dropFirst()), strict: true)
            case "run":
                try await run(Array(arguments.dropFirst()))
            case "index":
                try await buildIndex(Array(arguments.dropFirst()))
            case "extract":
                try await extract(Array(arguments.dropFirst()))
            case "catalog":
                try await catalog(Array(arguments.dropFirst()))
            case "keygen":
                try keygen()
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("unknown command '\(command)'\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    static func printUsage() {
        print("""
        irctl — Invoices Retriever plugin tools

        USAGE
          irctl validate <file.json|directory>...   Check plugins against the schema rules
          irctl lint <file.json|directory>...       Same, but warnings are failures (used by CI)
          irctl run <file.json> [options]           Execute a plugin against the real portal
          irctl extract <file.pdf>                  Show what the metadata extractor reads
          irctl index <directory> [--key <file>]    Build (and optionally sign) a plugin index
          irctl catalog [--url <index.json>]        Fetch and verify the published index
          irctl keygen                              Generate a signing key pair for the index

        RUN OPTIONS
          --config key=value        A configSchema field. Repeatable.
          --secret key=value        A password or TOTP seed. Repeatable. Never logged.
          --section <name>          checkAuth | startAuth | getConfigOptions | getDocuments
          --out <directory>         Where to write collected documents (default ./out)
          --step                    Pause before each step and print the current URL
          --headless                Never show the browser window (collection will fail
                                    rather than wait for an interactive sign-in)

        Engine version \(PluginManifest.engineVersion)
        """)
    }

    // MARK: - validate

    static func validate(_ arguments: [String], strict: Bool = false) async throws {
        let files = try expand(arguments)
        guard !files.isEmpty else {
            throw IRError.invalidPlugin("no plugin files found")
        }

        var failures = 0
        var seenIDs: [String: String] = [:]

        for file in files.sorted(by: { $0.path < $1.path }) {
            let name = file.lastPathComponent
            do {
                let manifest = try PluginManifest.decode(from: Data(contentsOf: file))

                // CI check 2: two plugins claiming the same id would make the
                // catalogue non-deterministic.
                if let previous = seenIDs[manifest.id] {
                    print("✗ \(name): id '\(manifest.id)' is already used by \(previous)")
                    failures += 1
                    continue
                }
                seenIDs[manifest.id] = name

                // The filename must match the id, so a reviewer can find a
                // plugin without opening every file.
                let expected = "\(manifest.id).json"
                if name != expected {
                    print("✗ \(name): should be named \(expected)")
                    failures += 1
                }

                let report = PluginValidator.validate(manifest)
                for issue in report.issues.sorted(by: { $0.severity < $1.severity }) {
                    let marker: String
                    switch issue.severity {
                    case .error: marker = "✗"
                    case .warning: marker = "⚠"
                    case .info: marker = "ℹ"
                    }
                    print("\(marker) \(name) [\(issue.path)] \(issue.message)")
                    if let hint = issue.hint { print("    → \(hint)") }
                }

                if !report.isValid || (strict && !report.warnings.isEmpty) {
                    failures += 1
                } else {
                    print("✓ \(name) — \(manifest.name) \(manifest.version)"
                          + (report.requiresHumanReview ? " (needs human review: uses runJs)" : ""))
                }
            } catch {
                print("✗ \(name): \(error.localizedDescription)")
                failures += 1
            }
        }

        print("\n\(files.count) plugin(s) checked, \(failures) failing")
        if failures > 0 { exit(1) }
    }

    // MARK: - run

    static func run(_ arguments: [String]) async throws {
        guard let path = arguments.first, !path.hasPrefix("--") else {
            throw IRError.invalidPlugin("usage: irctl run <file.json> [options]")
        }
        let options = Options(Array(arguments.dropFirst()))
        let file = URL(fileURLWithPath: path)
        let manifest = try PluginManifest.decode(from: Data(contentsOf: file))

        let report = PluginValidator.validate(manifest)
        guard report.isValid else {
            for issue in report.errors { print("✗ [\(issue.path)] \(issue.message)") }
            throw IRError.invalidPlugin("fix the errors above first")
        }

        // The CLI needs an event loop for WebKit, so it runs as a real (if
        // invisible) application.
        let app = NSApplication.shared
        app.setActivationPolicy(options.flag("headless") ? .prohibited : .accessory)

        var source = Source(entityID: UUID(), pluginID: manifest.id,
                            pluginVersion: manifest.version,
                            displayName: manifest.name)
        source.config = options.pairs("config")
        source.rememberCredentials = false

        // Secrets come in on the command line here, which is a development
        // convenience and not how the app works. They still go through the
        // redacting logger so that nothing prints them back out.
        let secrets = options.pairs("secret")
        for value in secrets.values { RedactingLogger.shared.registerSecret(value) }

        var totpCodes: [String: String] = [:]
        for (key, field) in manifest.configSchema ?? [:] where field.type == .totp {
            if let seed = secrets[key], let parsed = TOTP.normaliseSecret(seed) {
                totpCodes[key] = try TOTP.code(secret: parsed.secret, digits: parsed.digits,
                                               period: parsed.period, algorithm: parsed.algorithm)
            }
        }

        RedactingLogger.shared.addSink { record in
            let time = ISO8601DateFormatter().string(from: record.timestamp)
            print("[\(record.level.rawValue)] \(time.suffix(9).prefix(8)) \(record.message)")
        }

        let runID = UUID()
        let context = ExecutionContext(
            source: source, manifest: manifest, runID: runID,
            config: source.config, secrets: secrets, totpCodes: totpCodes,
            incrementalCutoff: source.incrementalCutoff())

        let factory = WebKitSessionFactory(sourceNames: { _ in manifest.name })
        let policy = manifest.domainPolicy
        let session = try await factory.makeSession(sourceID: source.id, policy: policy)
        await session.setVisible(!options.flag("headless"))

        let observer: (any StepObserver)? = options.flag("step") ? ConsoleStepObserver() : nil
        let executor = StepExecutor(session: session, context: context, policy: policy,
                                    deadline: Date().addingTimeInterval(600), observer: observer)

        let section = options.value("section") ?? "getDocuments"
        print("→ \(manifest.name) \(manifest.version), section '\(section)'")
        print("→ sandbox: \(manifest.allowedDomains.joined(separator: ", "))")

        do {
            switch section {
            case "checkAuth":
                try await executor.run(manifest.checkAuth, section: section)
                print("✓ the stored session is valid")
            case "startAuth":
                try await executor.run(manifest.startAuth ?? [], section: section)
                print("✓ startAuth finished")
            case "getConfigOptions":
                try await executor.run(manifest.getConfigOptions ?? [], section: section)
                for option in context.exposedOptions {
                    print("• \(option.key) (\(option.label)): "
                          + option.choices.map { "\($0.value)=\($0.label)" }.joined(separator: ", "))
                }
            default:
                // Sign in first, exactly as the app would, so the run is
                // representative rather than a special case.
                do {
                    try await executor.run(manifest.checkAuth, section: "checkAuth")
                } catch {
                    guard !options.flag("headless") else {
                        throw IRError.authenticationRequired(manifest.name)
                    }
                    print("→ not signed in; opening the browser. Sign in, then leave the window alone.")
                    await session.setVisible(true)
                    if let startAuth = manifest.startAuth {
                        try? await executor.run(startAuth, section: "startAuth")
                    }
                    let ok = await session.waitForUserSignIn(until: Date().addingTimeInterval(300)) {
                        (try? await executor.run(manifest.checkAuth, section: "checkAuth")) != nil
                    }
                    guard ok else { throw IRError.authenticationFailed("sign-in was not completed") }
                    print("✓ signed in")
                }

                try await executor.run(manifest.getDocuments, section: "getDocuments")

                let outputDirectory = URL(fileURLWithPath: options.value("out") ?? "./out")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

                print("\n\(context.documents.count) document(s):")
                for document in context.documents {
                    let name = NamingTemplate.sanitise(document.pluginDocumentID) + ".pdf"
                    try document.data.write(to: outputDirectory.appendingPathComponent(name))
                    let date = document.issuedOn.map(InvoiceDateParser.isoString) ?? "no date"
                    let total = document.total?.formatted() ?? "no total"
                    print("  • \(document.pluginDocumentID)  \(date)  \(total)  \(document.data.count) bytes")
                }
                print("→ written to \(outputDirectory.path)")
            }
        } catch {
            if let screenshot = try? await session.captureScreenshot() {
                let url = URL(fileURLWithPath: "./irctl-failure.png")
                try? screenshot.write(to: url)
                print("→ screenshot of the failure: \(url.path)")
            }
            await session.close()
            throw error
        }
        await session.close()
    }

    // MARK: - catalog

    /// Fetches the published index exactly as the application does, so a
    /// maintainer can tell "the index is broken" from "the app is broken"
    /// without launching the app.
    static func catalog(_ arguments: [String]) async throws {
        let options = Options(arguments)
        let address = options.value("url") ?? Preferences.default.pluginIndexURL
        guard let url = URL(string: address) else {
            throw IRError.invalidPlugin("'\(address)' is not a URL")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("irctl-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = PluginCatalog(installedDirectory: directory)
        let key = options.value("key") ?? PluginCatalog.indexPublicKeyBase64
        print("→ index:  \(url.absoluteString)")
        print("→ key:    \(key == PluginCatalog.placeholderPublicKey ? "none compiled in" : String(key.prefix(16)) + "…")")

        let update = try await PluginIndexUpdater(indexURL: url, publicKeyBase64: key).update(catalog)
        print("✓ signature verified")

        let entries = await catalog.all()
        print("\n\(entries.count) plugin(s) in the index:")
        for entry in entries {
            let flags = entry.manifest.containsArbitraryJavaScript ? "  [runJs]" : ""
            print("  • \(entry.manifest.id) \(entry.manifest.version)  \(entry.manifest.name)\(flags)")
        }
        if entries.isEmpty {
            print("  (none — no plugin has been verified against a live account yet)")
        }
        for (id, reason) in update.skipped.sorted(by: { $0.key < $1.key }) {
            print("⚠ \(id) skipped: \(reason)")
        }
    }

    // MARK: - extract

    static func extract(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            throw IRError.invalidPlugin("usage: irctl extract <file.pdf>")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let document = InvoiceDocument(entityID: UUID(),
                                       sha256: DocumentLibrary.sha256(data),
                                       relativePath: path, byteSize: data.count)
        let result = await MetadataExtractor().enrich(document, pdf: data)
        let d = result.document

        print("source of text: \(result.usedOCR ? "OCR (Vision)" : "embedded PDF text")")
        func line(_ label: String, _ value: String?, _ field: String) {
            let confidence = d.fieldConfidence[field].map { String(format: " (%.0f%%)", $0 * 100) } ?? ""
            print(String(format: "  %-12@ %@%@", label as NSString,
                         (value ?? "—") as NSString, confidence as NSString))
        }
        line("issuer", d.issuer, "issuer")
        line("number", d.number, "number")
        line("date", d.issuedOn.map(InvoiceDateParser.isoString), "issuedOn")
        line("total", d.total?.formatted(), "total")
        line("net", d.net?.formatted(), "net")
        line("VAT", d.vat?.formatted(), "vat")
        line("VAT no.", d.vatNumber, "vatNumber")
        line("kind", d.kind.rawValue, "kind")
        if d.needsReview { print("\n⚠ low confidence — a human should check this one") }
    }

    // MARK: - index

    static func buildIndex(_ arguments: [String]) async throws {
        guard let path = arguments.first, !path.hasPrefix("--") else {
            throw IRError.invalidPlugin("usage: irctl index <directory> [--key <private-key.b64>] [--out <dir>]")
        }
        let options = Options(Array(arguments.dropFirst()))
        let directory = URL(fileURLWithPath: path)
        let outputDirectory = URL(fileURLWithPath: options.value("out") ?? "./dist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var items: [PluginCatalog.SignedIndex.Item] = []
        for file in try expand([path]).sorted(by: { $0.path < $1.path }) {
            let data = try Data(contentsOf: file)
            let manifest = try PluginManifest.decode(from: data)
            guard PluginValidator.validate(manifest).isValid else {
                print("✗ skipping \(file.lastPathComponent): does not validate")
                continue
            }
            items.append(.init(id: manifest.id, version: manifest.version, name: manifest.name,
                               country: manifest.country, tags: manifest.tags,
                               status: manifest.effectiveStatus,
                               usesJs: manifest.containsArbitraryJavaScript,
                               sha256: DocumentLibrary.sha256(data),
                               path: "plugins/\(file.lastPathComponent)"))
        }

        let revision = Int(options.value("revision") ?? "") ?? Int(Date().timeIntervalSince1970)
        let index = PluginCatalog.SignedIndex(
            revision: revision, generatedAt: Date(),
            engine: PluginManifest.engineVersion.description, plugins: items)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let indexData = try encoder.encode(index)
        try indexData.write(to: outputDirectory.appendingPathComponent("index.json"))
        print("✓ \(items.count) plugin(s) in \(outputDirectory.path)/index.json (revision \(revision))")

        if let keyPath = options.value("key") {
            let raw = try String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let signature = try Signing.sign(indexData, privateKeyBase64: raw)
            try signature.write(to: outputDirectory.appendingPathComponent("index.json.sig"))
            print("✓ signed: index.json.sig")
        } else {
            print("⚠ unsigned. The app refuses an unsigned index; sign it before publishing.")
        }
        _ = directory
    }

    static func keygen() throws {
        let pair = Signing.generateKeyPair()
        print("private key (keep this secret, it belongs in a CI secret):")
        print(pair.privateKeyBase64)
        print("\npublic key (compile this into the app as PluginCatalog.indexPublicKeyBase64):")
        print(pair.publicKeyBase64)
    }

    // MARK: - Helpers

    static func expand(_ paths: [String]) throws -> [URL] {
        var files: [URL] = []
        for path in paths where !path.hasPrefix("--") {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw IRError.invalidPlugin("no such file: \(path)")
            }
            if isDirectory.boolValue {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                files += contents.filter { $0.pathExtension.lowercased() == "json" }
            } else {
                files.append(url)
            }
        }
        return files
    }
}

/// Minimal argument parsing. Adding a dependency for this would be a poor
/// trade in a project that ships none.
struct Options {
    private var flags: Set<String> = []
    private var values: [String: [String]] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { index += 1; continue }
            let name = String(argument.dropFirst(2))
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                values[name, default: []].append(next)
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name]?.first }

    /// `--config key=value`, repeatable.
    func pairs(_ name: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in values[name] ?? [] {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }
}

/// F10.5's step-by-step execution, in the terminal.
struct ConsoleStepObserver: StepObserver {
    func willRun(step: PluginStep, path: String, context: ExecutionContext) async {
        print("\n── \(path)")
        print("   \(step.action.rawValue)"
              + (step.selector.map { " selector=\($0)" } ?? "")
              + (step.url.map { " url=\($0)" } ?? ""))
        print("   press return to run, or 'v' then return to dump variables…")
        if let line = readLine(), line.trimmingCharacters(in: .whitespaces) == "v" {
            for (name, value) in context.snapshot().sorted(by: { $0.key < $1.key }) {
                print("     \(name) = \(String((value.stringValue ?? "—").prefix(120)))")
            }
        }
    }

    func didRun(step: PluginStep, path: String, error: (any Error)?) async {
        if let error { print("   ✗ \(error.localizedDescription)") }
        else { print("   ✓") }
    }
}
