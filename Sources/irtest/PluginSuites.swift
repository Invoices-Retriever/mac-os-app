import Foundation
import IRCore

/// A minimal well-formed plugin, used as the baseline the validator tests
/// mutate. Keeping it here rather than as a fixture file means a change to the
/// format breaks compilation rather than silently passing.
let goodPluginJSON = """
{
  "id": "example-portal",
  "name": "Example Portal",
  "version": "1.0.0",
  "description": "Invoices from the example portal.",
  "homepage": "https://example.com",
  "maintainers": ["@someone"],
  "country": ["FR"],
  "tags": ["hosting"],
  "engine": ">=1.0.0",
  "allowedDomains": ["example.com", "*.example.com"],
  "configSchema": {
    "username": { "type": "string", "label": "Customer number", "required": true },
    "password": { "type": "password", "label": "Password", "required": true }
  },
  "autofill": true,
  "checkAuth": [
    { "action": "navigate", "url": "https://example.com/account" },
    { "action": "checkElementExists", "selector": "#billing-table" }
  ],
  "startAuth": [
    { "action": "navigate", "url": "https://example.com/login" },
    { "action": "type", "selector": "#user", "value": "{{config.username}}" },
    { "action": "type", "selector": "#pass", "value": "{{secret.password}}" },
    { "action": "click", "selector": "#submit" }
  ],
  "getDocuments": [
    { "action": "navigate", "url": "https://example.com/account" },
    {
      "action": "extractAll",
      "selector": ".invoice-row",
      "fields": {
        "number": { "selector": ".number" },
        "date": { "selector": ".date" },
        "total": { "selector": ".total" },
        "link": { "selector": "a.pdf", "attribute": "href" }
      },
      "forEach": [
        {
          "action": "downloadPdf",
          "url": "{{item.link}}",
          "document": {
            "id": "{{item.number}}",
            "date": "{{item.date}}",
            "total": "{{item.total}}",
            "number": "{{item.number}}"
          }
        }
      ]
    }
  ]
}
"""

func decodeGoodPlugin() throws -> PluginManifest {
    try PluginManifest.decode(from: Data(goodPluginJSON.utf8))
}

/// Rewrites one top-level key of the baseline plugin, so each test states only
/// what it is changing.
func mutatedPlugin(_ changes: [String: Any]) throws -> PluginManifest {
    var object = try JSONSerialization.jsonObject(with: Data(goodPluginJSON.utf8)) as! [String: Any]
    for (key, value) in changes {
        if value is NSNull { object.removeValue(forKey: key) } else { object[key] = value }
    }
    return try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
}

@MainActor
func runPluginSuites() async {

    await suite("Plugin decoding") {
        await test("The baseline plugin decodes and validates") {
            let manifest = try decodeGoodPlugin()
            expectEqual(manifest.id, "example-portal")
            expectEqual(manifest.allowedDomains.count, 2)
            expectEqual(manifest.getDocuments.count, 2)
            expect(PluginValidator.validate(manifest).isValid)
        }
        await test("Secret and plain config keys are separated") {
            let manifest = try decodeGoodPlugin()
            expectEqual(manifest.secretConfigKeys, ["password"])
            expectEqual(manifest.plainConfigKeys, ["username"])
        }
        await test("A missing mandatory key produces a readable error, not a crash") {
            await expectThrows {
                _ = try PluginManifest.decode(from: Data(#"{"id":"x","name":"X"}"#.utf8))
            }
        }
        await test("Conditions decode from their single-key form") {
            let step = try JSONDecoder().decode(PluginStep.self, from: Data("""
            { "action": "if", "condition": { "elementExists": ".cookie-banner" },
              "then": [ { "action": "click", "selector": ".accept" } ] }
            """.utf8))
            expect(step.action == .ifStep)
            if case .elementExists(let selector)? = step.condition {
                expectEqual(selector, ".cookie-banner")
            } else {
                expect(false, "the condition did not decode")
            }
        }
    }

    await suite("Plugin validation") {
        await test("An empty allowedDomains is refused") {
            let manifest = try mutatedPlugin(["allowedDomains": [String]()])
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.path == "allowedDomains" })
        }
        await test("Navigating outside allowedDomains is caught statically") {
            let manifest = try mutatedPlugin([
                "getDocuments": [
                    ["action": "navigate", "url": "https://cdn.other-site.net/invoices"],
                    ["action": "printPdf", "document": ["id": "x", "date": "2026-01-01"]],
                ]
            ])
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("cdn.other-site.net") })
        }
        await test("runJs without usesJs is an error, and the badge follows the steps") {
            let manifest = try mutatedPlugin([
                "getDocuments": [
                    ["action": "runJs", "code": "return 1", "assignTo": "one"],
                    ["action": "printPdf", "document": ["id": "x", "date": "2026-01-01"]],
                ]
            ])
            expect(manifest.containsArbitraryJavaScript)
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.requiresHumanReview)
            expect(report.errors.contains { $0.path == "usesJs" })
        }
        await test("checkAuth must end in a verification step") {
            let manifest = try mutatedPlugin([
                "checkAuth": [["action": "navigate", "url": "https://example.com/account"]]
            ])
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.path == "checkAuth" })
        }
        await test("getDocuments that emits nothing is refused") {
            let manifest = try mutatedPlugin([
                "getDocuments": [["action": "navigate", "url": "https://example.com/account"]]
            ])
            expect(!PluginValidator.validate(manifest).isValid)
        }
        await test("A config key used but not declared is an error") {
            let manifest = try mutatedPlugin([
                "configSchema": ["username": ["type": "string", "label": "User"]]
            ])
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("password") })
        }
        await test("A config key declared but unused is a warning, not an error") {
            let manifest = try mutatedPlugin([
                "configSchema": [
                    "username": ["type": "string", "label": "User"],
                    "password": ["type": "password", "label": "Password"],
                    "unused": ["type": "string", "label": "Nobody reads this"],
                ]
            ])
            let report = PluginValidator.validate(manifest)
            expect(report.isValid)
            expect(report.warnings.contains { $0.path.contains("unused") })
        }
        await test("A hard-coded password is caught before review") {
            let manifest = try mutatedPlugin([
                "startAuth": [
                    ["action": "navigate", "url": "https://example.com/login"],
                    ["action": "type", "selector": "#pass", "value": "password=Tr0ub4dor&3"],
                ]
            ])
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("hard-coded") })
        }
        await test("A contributor's own e-mail left in a step is caught") {
            let manifest = try mutatedPlugin([
                "startAuth": [
                    ["action": "navigate", "url": "https://example.com/login"],
                    ["action": "type", "selector": "#user", "value": "someone@example.org"],
                ]
            ])
            expect(!PluginValidator.validate(manifest).isValid)
        }
        await test("http instead of https is refused") {
            let manifest = try mutatedPlugin([
                "checkAuth": [
                    ["action": "navigate", "url": "http://example.com/account"],
                    ["action": "checkURL", "url": "*/account"],
                ],
                "allowedDomains": ["example.com", "*.example.com"],
            ])
            expect(!PluginValidator.validate(manifest).isValid)
        }
        await test("A plugin demanding a newer engine is refused") {
            let manifest = try mutatedPlugin(["engine": ">=99.0.0"])
            expect(!manifest.isSupportedByEngine())
            expect(!PluginValidator.validate(manifest).isValid)
        }
        await test("A wildcard covering a whole TLD is refused") {
            let manifest = try mutatedPlugin(["allowedDomains": ["*.com"]])
            expect(!PluginValidator.validate(manifest).isValid)
        }
    }

    await suite("Plugin catalogue") {
        await test("Sideloaded and local plugins carry a warning; bundled ones do not") {
            let manifest = try decodeGoodPlugin()
            let sideloaded = PluginCatalog.Entry(manifest: manifest, provenance: .sideloaded)
            expect(sideloaded.warnings.contains { $0.contains("not come from the official index") })

            let bundled = PluginCatalog.Entry(manifest: manifest, provenance: .bundled)
            expect(bundled.warnings.isEmpty)
        }
        await test("The capability summary names the domains and nothing else") {
            let entry = PluginCatalog.Entry(manifest: try decodeGoodPlugin(), provenance: .official)
            expect(entry.capabilitySummary.contains("example.com"))
            expect(entry.capabilitySummary.contains("cannot reach anywhere else"))
        }
        await test("Installing refuses an invalid plugin before writing anything") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let bad = directory.appendingPathComponent("bad.json")
            try Data(#"{"id":"bad","name":"Bad","version":"1.0.0","engine":">=1.0.0","allowedDomains":[],"checkAuth":[],"getDocuments":[]}"#.utf8)
                .write(to: bad)

            let installDirectory = directory.appendingPathComponent("installed")
            let catalog = PluginCatalog(installedDirectory: installDirectory)
            await expectThrows { _ = try await catalog.install(from: bad) }
            expect(!FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent("bad.json").path))
        }
        await test("An index with a bad signature installs nothing") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let catalog = PluginCatalog(installedDirectory: directory)

            let index = Data(#"{"revision":1,"generatedAt":"2026-01-01T00:00:00Z","engine":"1.0.0","plugins":[]}"#.utf8)
            let wrongKey = Signing.generateKeyPair()
            let signature = try Signing.sign(index, privateKeyBase64: wrongKey.privateKeyBase64)

            await expectThrows {
                _ = try await catalog.applyIndex(index, signature: signature,
                                                 publicKeyBase64: Signing.generateKeyPair().publicKeyBase64,
                                                 fetch: { _ in Data() })
            }
        }
    }

    await suite("File naming") {
        await test("The default pattern produces a sortable, legible name") {
            var document = InvoiceDocument(entityID: UUID(), sha256: "x", relativePath: "", byteSize: 1)
            document.issuedOn = InvoiceDateParser.parse("2026-03-31")
            document.issuer = "OVHcloud"
            document.number = "FR-12345"
            document.total = Money(cents: 123456, currency: "EUR")
            expectEqual(NamingTemplate.default.render(document: document, sourceName: nil),
                        "2026-03-31_OVHcloud_FR-12345_1234.56")
        }
        await test("Missing fields do not leave a trail of separators") {
            var document = InvoiceDocument(entityID: UUID(), sha256: "x", relativePath: "", byteSize: 1)
            document.issuedOn = InvoiceDateParser.parse("2026-03-31")
            document.issuer = "OVHcloud"
            expectEqual(NamingTemplate.default.render(document: document, sourceName: nil),
                        "2026-03-31_OVHcloud")
        }
        await test("Path separators in a scraped issuer cannot escape the folder") {
            expectEqual(NamingTemplate.sanitise("../../etc/passwd"), "etc-passwd")
            expectEqual(NamingTemplate.sanitise("A/B:C*D?"), "A-B-C-D")
        }
        await test("The folder pattern gives year/month directories") {
            var document = InvoiceDocument(entityID: UUID(), sha256: "x", relativePath: "", byteSize: 1)
            document.issuedOn = InvoiceDateParser.parse("2026-03-31")
            expectEqual(NamingTemplate.folderDefault.render(document: document, sourceName: nil), "2026/03")
        }
    }
}

@MainActor
func runIndexUpdaterSuites() async {

    await suite("Plugin index updater") {
        let base = URL(string: "https://invoices-retriever.github.io/plugins/")!

        await test("An ordinary relative path resolves under the index") {
            let url = try PluginIndexUpdater.resolve(path: "plugins/ovh.json", against: base)
            expectEqual(url.absoluteString, "https://invoices-retriever.github.io/plugins/plugins/ovh.json")
        }

        await test("A tampered index cannot point the downloader elsewhere") {
            // The signature makes this unlikely; the check makes it harmless.
            for hostile in ["https://evil.example.com/payload.json",
                            "//evil.example.com/payload.json",
                            "/etc/passwd",
                            "../../../../etc/passwd",
                            "plugins/../../../secrets.json",
                            ""] {
                var refused = false
                do { _ = try PluginIndexUpdater.resolve(path: hostile, against: base) }
                catch { refused = true }
                expect(refused, "'\(hostile)' should have been refused")
            }
        }

        await test("The signature URL sits next to the index") {
            let updater = PluginIndexUpdater(indexURL: base.appendingPathComponent("index.json"),
                                             publicKeyBase64: "x")
            expectEqual(updater.signatureURL.absoluteString,
                        "https://invoices-retriever.github.io/plugins/index.json.sig")
        }

        await test("A correctly signed index installs the plugin it names") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let catalog = PluginCatalog(installedDirectory: directory)

            let plugin = Data(goodPluginJSON.utf8)
            let digest = DocumentLibrary.sha256(plugin)
            let index = Data("""
            {"revision":1,"generatedAt":"2026-01-01T00:00:00Z","engine":"1.0.0","plugins":[
              {"id":"example-portal","version":"1.0.0","name":"Example Portal",
               "sha256":"\(digest)","path":"plugins/example-portal.json"}]}
            """.utf8)

            let keys = Signing.generateKeyPair()
            let signature = try Signing.sign(index, privateKeyBase64: keys.privateKeyBase64)

            // The fetch closure runs off the main actor, so it records what it
            // was asked for and the assertion happens back here.
            let requested = PathRecorder()
            let update = try await catalog.applyIndex(
                index, signature: signature, publicKeyBase64: keys.publicKeyBase64,
                fetch: { path in
                    await requested.record(path)
                    return plugin
                })

            expectEqual(await requested.paths, ["plugins/example-portal.json"])
            expectEqual(update.installed, ["example-portal"])
            expect(await catalog.manifest(id: "example-portal") != nil, "the plugin was not installed")
            expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("example-portal.json").path),
                "the plugin was not written to disk")
        }

        await test("A plugin whose bytes do not match the index is refused") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let catalog = PluginCatalog(installedDirectory: directory)

            // The signature says the index is ours. It says nothing about the
            // file the index points at, which is why the checksum is checked
            // separately.
            let index = Data("""
            {"revision":1,"generatedAt":"2026-01-01T00:00:00Z","engine":"1.0.0","plugins":[
              {"id":"example-portal","version":"1.0.0","name":"Example Portal",
               "sha256":"0000000000000000000000000000000000000000000000000000000000000000",
               "path":"plugins/example-portal.json"}]}
            """.utf8)
            let keys = Signing.generateKeyPair()
            let signature = try Signing.sign(index, privateKeyBase64: keys.privateKeyBase64)

            let update = try await catalog.applyIndex(
                index, signature: signature, publicKeyBase64: keys.publicKeyBase64,
                fetch: { _ in Data(goodPluginJSON.utf8) })

            expect(update.installed.isEmpty, "a mismatched plugin must not install")
            expectEqual(update.skipped["example-portal"], "checksum mismatch")
            expect(await catalog.manifest(id: "example-portal") == nil)
        }

        await test("An index that goes backwards is refused") {
            // A signature stays valid forever, so a stale-but-genuine index is
            // indistinguishable from a fresh one. Observed for real: a CDN
            // caching per Accept-Encoding pinned one client to an old revision
            // for as long as that variant lived. Anyone able to replay an old
            // index could quietly reinstate a plugin that had been withdrawn.
            let old = Data(#"{"revision":4,"generatedAt":"2026-01-01T00:00:00Z","engine":"1.0.0","plugins":[]}"#.utf8)
            expectEqual(try PluginIndexUpdater.revision(of: old), 4)

            let keys = Signing.generateKeyPair()
            let signature = try Signing.sign(old, privateKeyBase64: keys.privateKeyBase64)
            expect(Signing.verify(old, signature: signature, publicKeyBase64: keys.publicKeyBase64),
                   "the old index is genuinely signed — that is the point")
        }

        await test("A build with no signing key refuses to update at all") {
            let catalog = PluginCatalog(installedDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
            let updater = PluginIndexUpdater(indexURL: base.appendingPathComponent("index.json"),
                                             publicKeyBase64: PluginCatalog.placeholderPublicKey)
            await expectThrows { _ = try await updater.update(catalog) }
        }
    }
}


/// Records what the index asked the downloader to fetch.
actor PathRecorder {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
