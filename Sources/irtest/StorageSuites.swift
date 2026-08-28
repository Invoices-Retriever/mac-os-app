import Foundation
import IRCore

private func makeTemporaryStore() async throws -> (Store, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("irtest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try await Store.open(at: directory.appendingPathComponent("index.sqlite"))
    return (store, directory)
}

@MainActor
func runStorageSuites() async {

    await suite("Storage") {
        await test("Migrations apply, and applying them twice is harmless") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await Migrations.migrate(store.database)
            let rows = try await store.database.query("SELECT COUNT(*) AS n FROM schema_migration")
            expectEqual(rows.first?.int("n"), Migrations.all.count)
        }

        await test("A source round-trips, including its schedule and config") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            var source = Source(entityID: entity.id, pluginID: "ovh", pluginVersion: "1.0.0",
                                displayName: "OVH — main account")
            source.config = ["customerID": "ab12345-ovh"]
            source.schedule = .monthly(day: 5, hour: 9)
            source.lookbackDays = 45
            try await store.upsert(source)

            let loaded = try await store.source(id: source.id)
            expectEqual(loaded?.displayName, "OVH — main account")
            expectEqual(loaded?.config["customerID"], "ab12345-ovh")
            expectEqual(loaded?.lookbackDays, 45)
            expect(loaded?.schedule == .monthly(day: 5, hour: 9))
        }

        await test("A document round-trips with its amounts intact") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            var document = InvoiceDocument(entityID: entity.id, sha256: "abc123",
                                           relativePath: "2026/03/x.pdf", byteSize: 2048)
            document.total = Money(cents: 123456, currency: "EUR")
            document.vat = Money(cents: 20576, currency: "EUR")
            document.issuedOn = InvoiceDateParser.parse("2026-03-31")
            document.number = "FR-42"
            document.issuer = "OVHcloud"
            try await store.upsert(document)

            let loaded = try await store.document(id: document.id)
            expectEqual(loaded?.total?.cents, 123456)
            expectEqual(loaded?.total?.currency, "EUR")
            expectEqual(loaded?.vat?.cents, 20576)
            expectEqual(loaded?.number, "FR-42")
            expectEqual(loaded?.issuedOn.map(InvoiceDateParser.isoString), "2026-03-31")
        }

        await test("The same plugin document id cannot be stored twice for one source") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let source = Source(entityID: entity.id, pluginID: "ovh",
                                pluginVersion: "1.0.0", displayName: "OVH")
            try await store.upsert(source)

            let first = InvoiceDocument(entityID: entity.id, sourceID: source.id,
                                        pluginDocumentID: "F-1", sha256: "aaa",
                                        relativePath: "a.pdf", byteSize: 1)
            try await store.upsert(first)

            let second = InvoiceDocument(entityID: entity.id, sourceID: source.id,
                                         pluginDocumentID: "F-1", sha256: "bbb",
                                         relativePath: "b.pdf", byteSize: 1)
            await expectThrows { try await store.upsert(second) }
        }

        await test("Full-text search finds a document by issuer and by number") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            var document = InvoiceDocument(entityID: entity.id, sha256: "abc",
                                           relativePath: "x.pdf", byteSize: 1)
            document.issuer = "Scaleway"
            document.number = "SCW-2026-0099"
            document.extractedText = "Facture Scaleway Elements hébergement"
            try await store.upsert(document)

            var filter = DocumentFilter(entityID: entity.id)
            filter.searchText = "Scaleway"
            expectEqual(try await store.documents(filter: filter).count, 1)

            filter.searchText = "SCW-2026"
            expectEqual(try await store.documents(filter: filter).count, 1)

            filter.searchText = "hébergement"
            expectEqual(try await store.documents(filter: filter).count, 1)

            filter.searchText = "Hetzner"
            expectEqual(try await store.documents(filter: filter).count, 0)
        }

        await test("Filtering by period works on the issue date") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let entity = try await store.defaultEntity()

            for (index, day) in ["2026-01-15", "2026-02-15", "2026-03-15"].enumerated() {
                var document = InvoiceDocument(entityID: entity.id, sha256: "sha\(index)",
                                               relativePath: "\(index).pdf", byteSize: 1)
                document.issuedOn = InvoiceDateParser.parse(day)
                try await store.upsert(document)
            }

            let filter = DocumentFilter(entityID: entity.id,
                                        issuedFrom: InvoiceDateParser.parse("2026-02-01"),
                                        issuedTo: InvoiceDateParser.parse("2026-02-28"))
            expectEqual(try await store.documents(filter: filter).count, 1)
        }

        await test("Export idempotence: a recorded export is not offered again") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let document = InvoiceDocument(entityID: entity.id, sha256: "abc",
                                           relativePath: "x.pdf", byteSize: 1)
            try await store.upsert(document)

            expect(!(try await store.hasBeenExported(documentID: document.id, destinationID: "folder:/tmp/out")))
            try await store.record(ExportRecord(documentID: document.id,
                                                destinationID: "folder:/tmp/out",
                                                destinationKind: .folder))
            expect(try await store.hasBeenExported(documentID: document.id, destinationID: "folder:/tmp/out"))
            // A different destination is a different question.
            expect(!(try await store.hasBeenExported(documentID: document.id, destinationID: "folder:/tmp/other")))

            var filter = DocumentFilter(entityID: entity.id)
            filter.exportedTo = DocumentFilter.ExportFilter(destinationID: "folder:/tmp/out", negated: true)
            expectEqual(try await store.documents(filter: filter).count, 0)
        }

        await test("Preferences round-trip through the settings table") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            var preferences = Preferences.default
            preferences.maximumConcurrency = 4
            preferences.enableLLMFallback = true
            try await preferences.save(to: store)

            let loaded = await Preferences.load(from: store)
            expectEqual(loaded.maximumConcurrency, 4)
            expect(loaded.enableLLMFallback)
        }

        await test("A record missing keys keeps its known settings") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            // What a record written by an older version looks like: it knows
            // nothing of the settings added since. Losing the two it does carry
            // would be the user losing their configuration on upgrade.
            try await store.setSetting(Preferences.settingKey,
                #"{"maximumConcurrency":5,"interfaceLanguage":"fr"}"#)

            let loaded = await Preferences.load(from: store)
            expectEqual(loaded.maximumConcurrency, 5)
            expectEqual(loaded.interfaceLanguage, "fr")
            expectEqual(loaded.fileNamePattern, Preferences.default.fileNamePattern)
            expect(!loaded.enableLLMFallback, "an absent key must never turn the model on")
        }

        await test("An unreadable record falls back rather than crashing") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await store.setSetting(Preferences.settingKey, "this is not JSON")
            let loaded = await Preferences.load(from: store)
            expectEqual(loaded.maximumConcurrency, Preferences.default.maximumConcurrency)
        }

        await test("The LLM fallback is off in the shipped defaults") {
            expect(!Preferences.default.enableLLMFallback)
            expect(!Preferences.default.schedulerEnabled)
        }
    }

    await suite("Document library") {
        await test("A collected document is written and indexed") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let source = Source(entityID: entity.id, pluginID: "ovh",
                                pluginVersion: "1.0.0", displayName: "OVH")
            try await store.upsert(source)

            let root = directory.appendingPathComponent("library")
            let library = DocumentLibrary(root: root, store: store)

            var collected = CollectedDocument(pluginDocumentID: "F-1", data: Data("%PDF-1.4 one".utf8))
            collected.issuedOn = InvoiceDateParser.parse("2026-03-31")
            collected.total = Money(cents: 12000, currency: "EUR")
            collected.number = "FR-1"
            collected.issuer = "OVHcloud"

            guard case .stored(let document) = try await library.ingest(
                collected, source: source, entityID: entity.id) else {
                expect(false, "the first ingestion should store the document")
                return
            }
            expectEqual(document.relativePath, "2026/03/2026-03-31_OVHcloud_FR-1_120.00.pdf")
            expect(library.fileExists(for: document))
            expectEqual(try await store.document(id: document.id)?.number, "FR-1")
        }

        await test("The same plugin document id is refused a second time") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let source = Source(entityID: entity.id, pluginID: "ovh",
                                pluginVersion: "1.0.0", displayName: "OVH")
            try await store.upsert(source)
            let library = DocumentLibrary(root: directory.appendingPathComponent("library"), store: store)

            var collected = CollectedDocument(pluginDocumentID: "F-1", data: Data("%PDF one".utf8))
            collected.issuedOn = InvoiceDateParser.parse("2026-03-31")
            _ = try await library.ingest(collected, source: source, entityID: entity.id)

            // Same identifier, different bytes: the portal re-rendered it.
            var again = CollectedDocument(pluginDocumentID: "F-1", data: Data("%PDF one, regenerated".utf8))
            again.issuedOn = InvoiceDateParser.parse("2026-03-31")
            guard case .duplicate(_, let reason) = try await library.ingest(
                again, source: source, entityID: entity.id) else {
                expect(false, "the second ingestion should be a duplicate")
                return
            }
            expect(reason == .samePluginDocumentID)
        }

        await test("Identical bytes from a different source are caught by the hash") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let first = Source(entityID: entity.id, pluginID: "a", pluginVersion: "1.0.0", displayName: "A")
            let second = Source(entityID: entity.id, pluginID: "b", pluginVersion: "1.0.0", displayName: "B")
            try await store.upsert(first)
            try await store.upsert(second)
            let library = DocumentLibrary(root: directory.appendingPathComponent("library"), store: store)

            let bytes = Data("%PDF the very same invoice".utf8)
            var one = CollectedDocument(pluginDocumentID: "X-1", data: bytes)
            one.issuedOn = InvoiceDateParser.parse("2026-03-31")
            _ = try await library.ingest(one, source: first, entityID: entity.id)

            var two = CollectedDocument(pluginDocumentID: "Y-9", data: bytes)
            two.issuedOn = InvoiceDateParser.parse("2026-03-31")
            guard case .duplicate(_, let reason) = try await library.ingest(
                two, source: second, entityID: entity.id) else {
                expect(false, "identical bytes should be a duplicate")
                return
            }
            expect(reason == .sameContent)
        }

        await test("Two invoices that would share a name get distinct files") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let source = Source(entityID: entity.id, pluginID: "a", pluginVersion: "1.0.0", displayName: "A")
            try await store.upsert(source)
            let library = DocumentLibrary(root: directory.appendingPathComponent("library"), store: store)

            var paths: [String] = []
            for (index, bytes) in ["%PDF a", "%PDF b"].enumerated() {
                var collected = CollectedDocument(pluginDocumentID: "id-\(index)", data: Data(bytes.utf8))
                collected.issuedOn = InvoiceDateParser.parse("2026-03-31")
                collected.issuer = "Same Supplier"
                if case .stored(let document) = try await library.ingest(
                    collected, source: source, entityID: entity.id) {
                    paths.append(document.relativePath)
                }
            }
            expectEqual(paths.count, 2)
            expect(paths[0] != paths[1], "the second file must not overwrite the first")
        }

        await test("Rescanning a folder rebuilds the index") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }

            let entity = try await store.defaultEntity()
            let root = directory.appendingPathComponent("library")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("2026/03"), withIntermediateDirectories: true)
            try Data("%PDF found on disk".utf8).write(
                to: root.appendingPathComponent("2026/03/2026-03-31_Somebody.pdf"))

            let library = DocumentLibrary(root: root, store: store)
            let result = try await library.rescan(entityID: entity.id)
            expectEqual(result.added, 1)

            let documents = try await store.documents(filter: DocumentFilter(entityID: entity.id))
            expectEqual(documents.count, 1)
            expect(documents.first?.origin == .folderScan)
            expectEqual(documents.first?.issuedOn.map(InvoiceDateParser.isoString), "2026-03-31")

            // A second scan must not duplicate anything.
            expectEqual(try await library.rescan(entityID: entity.id).added, 0)
        }
    }

    await suite("Registers") {
        await test("CSV escapes commas and quotes, and uses a dot decimal") {
            let (store, directory) = try await makeTemporaryStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = store

            let output = directory.appendingPathComponent("register.csv")
            var document = InvoiceDocument(entityID: UUID(), sha256: "abc",
                                           relativePath: "2026/03/x.pdf", byteSize: 1)
            document.issuer = "Dupont, Martin & Cie \"Pro\""
            document.number = "FR-1"
            document.total = Money(cents: 123456, currency: "EUR")
            document.issuedOn = InvoiceDateParser.parse("2026-03-31")

            let exporter = RegisterExporter(format: .csv, outputURL: output)
            _ = try await exporter.finish([document])

            // Read as bytes: String(contentsOf:encoding:) consumes the BOM, so
            // checking for it on the decoded string would always fail.
            let raw = try Data(contentsOf: output)
            expect(raw.starts(with: [0xEF, 0xBB, 0xBF]), "a BOM keeps Excel from mangling accents")

            let csv = String(decoding: raw, as: UTF8.self)
            expect(csv.contains("\"Dupont, Martin & Cie \"\"Pro\"\"\""))
            expect(csv.contains("1234.56"))
            expect(csv.contains("2026-03-31"))
        }

        await test("A credit note keeps its negative sign through the register") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let output = directory.appendingPathComponent("register.csv")
            var document = InvoiceDocument(entityID: UUID(), sha256: "abc",
                                           relativePath: "x.pdf", byteSize: 1, kind: .creditNote)
            document.total = Money(cents: -4500, currency: "EUR")

            _ = try await RegisterExporter(format: .csv, outputURL: output).finish([document])
            expect(try String(contentsOf: output, encoding: .utf8).contains("-45.00"))
        }
    }
}
