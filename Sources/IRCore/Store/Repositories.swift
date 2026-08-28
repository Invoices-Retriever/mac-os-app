import Foundation

/// Row mapping for every table. Kept in one file on purpose: the mapping and
/// the migration that defines the columns should be readable side by side.
public struct Store: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    public static func open(at url: URL) async throws -> Store {
        let database = try Database(url: url)
        try await Migrations.migrate(database)
        return Store(database: database)
    }

    // MARK: - Entities

    public func upsert(_ entity: Entity) async throws {
        try await database.run("""
            INSERT INTO entity (id, name, vat_number, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, vat_number = excluded.vat_number
            """, [SQLValue(entity.id), .text(entity.name), SQLValue(entity.vatNumber), SQLValue(entity.createdAt)])
    }

    public func entities() async throws -> [Entity] {
        try await database.query("SELECT * FROM entity ORDER BY created_at").compactMap(Self.entity)
    }

    /// v1 keeps a single entity; this creates it on first launch so that every
    /// later query has something to hang off.
    public func defaultEntity() async throws -> Entity {
        if let existing = try await entities().first { return existing }
        let entity = Entity(name: Entity.defaultName)
        try await upsert(entity)
        return entity
    }

    private static func entity(_ row: Row) -> Entity? {
        guard let id = row.uuid("id"), let name = row.string("name"),
              let createdAt = row.date("created_at") else { return nil }
        return Entity(id: id, name: name, vatNumber: row.string("vat_number"), createdAt: createdAt)
    }

    // MARK: - Sources

    public func upsert(_ source: Source) async throws {
        try await database.run("""
            INSERT INTO source (id, entity_id, plugin_id, plugin_version, display_name, is_enabled,
                                config_json, options_json, remember_credentials, autofill_enabled,
                                schedule_json, lookback_days, last_run_at, last_success_at,
                                last_run_status, last_error_message, document_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                plugin_version = excluded.plugin_version,
                display_name = excluded.display_name,
                is_enabled = excluded.is_enabled,
                config_json = excluded.config_json,
                options_json = excluded.options_json,
                remember_credentials = excluded.remember_credentials,
                autofill_enabled = excluded.autofill_enabled,
                schedule_json = excluded.schedule_json,
                lookback_days = excluded.lookback_days,
                last_run_at = excluded.last_run_at,
                last_success_at = excluded.last_success_at,
                last_run_status = excluded.last_run_status,
                last_error_message = excluded.last_error_message,
                document_count = excluded.document_count
            """, [
                SQLValue(source.id), SQLValue(source.entityID), .text(source.pluginID),
                .text(source.pluginVersion), .text(source.displayName), SQLValue(source.isEnabled),
                SQLValue(json: source.config), SQLValue(json: source.options),
                SQLValue(source.rememberCredentials), SQLValue(source.autofillEnabled),
                SQLValue(json: source.schedule), .integer(source.lookbackDays),
                SQLValue(source.lastRunAt), SQLValue(source.lastSuccessAt),
                SQLValue(source.lastRunStatus?.rawValue), SQLValue(source.lastErrorMessage),
                .integer(source.documentCount), SQLValue(source.createdAt),
            ])
    }

    public func sources(entityID: UUID? = nil, enabledOnly: Bool = false) async throws -> [Source] {
        var sql = "SELECT * FROM source"
        var conditions: [String] = []
        var bindings: [SQLValue] = []
        if let entityID { conditions.append("entity_id = ?"); bindings.append(SQLValue(entityID)) }
        if enabledOnly { conditions.append("is_enabled = 1") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY display_name COLLATE NOCASE"
        return try await database.query(sql, bindings).compactMap(Self.source)
    }

    public func source(id: UUID) async throws -> Source? {
        try await database.query("SELECT * FROM source WHERE id = ?", [SQLValue(id)]).compactMap(Self.source).first
    }

    public func deleteSource(id: UUID) async throws {
        try await database.run("DELETE FROM source WHERE id = ?", [SQLValue(id)])
    }

    private static func source(_ row: Row) -> Source? {
        guard let id = row.uuid("id"), let entityID = row.uuid("entity_id"),
              let pluginID = row.string("plugin_id"), let name = row.string("display_name"),
              let createdAt = row.date("created_at") else { return nil }

        var source = Source(id: id, entityID: entityID, pluginID: pluginID,
                            pluginVersion: row.string("plugin_version") ?? "0.0.0",
                            displayName: name, createdAt: createdAt)
        source.isEnabled = row.bool("is_enabled")
        source.config = row.json("config_json", as: [String: String].self) ?? [:]
        source.options = row.json("options_json", as: [String: [String]].self) ?? [:]
        source.rememberCredentials = row.bool("remember_credentials")
        source.autofillEnabled = row.bool("autofill_enabled")
        source.schedule = row.json("schedule_json", as: Schedule.self) ?? .manual
        source.lookbackDays = row.int("lookback_days") ?? 90
        source.lastRunAt = row.date("last_run_at")
        source.lastSuccessAt = row.date("last_success_at")
        source.lastRunStatus = row.string("last_run_status").flatMap(RunStatus.init(rawValue:))
        source.lastErrorMessage = row.string("last_error_message")
        source.documentCount = row.int("document_count") ?? 0
        return source
    }

    // MARK: - Runs

    public func upsert(_ run: Run) async throws {
        try await database.run("""
            INSERT INTO run (id, source_id, started_at, finished_at, status, documents_found,
                             documents_new, error_message, screenshot_path, attempt, trigger,
                             outline_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                finished_at = excluded.finished_at,
                status = excluded.status,
                documents_found = excluded.documents_found,
                documents_new = excluded.documents_new,
                error_message = excluded.error_message,
                screenshot_path = excluded.screenshot_path,
                outline_path = excluded.outline_path
            """, [
                SQLValue(run.id), SQLValue(run.sourceID), SQLValue(run.startedAt),
                SQLValue(run.finishedAt), .text(run.status.rawValue),
                .integer(run.documentsFound), .integer(run.documentsNew),
                SQLValue(run.errorMessage), SQLValue(run.screenshotPath),
                .integer(run.attempt), .text(run.trigger.rawValue),
                SQLValue(run.outlinePath),
            ])
    }

    public func runs(sourceID: UUID? = nil, limit: Int = 50) async throws -> [Run] {
        var sql = "SELECT * FROM run"
        var bindings: [SQLValue] = []
        if let sourceID { sql += " WHERE source_id = ?"; bindings.append(SQLValue(sourceID)) }
        sql += " ORDER BY started_at DESC LIMIT ?"
        bindings.append(.integer(limit))
        return try await database.query(sql, bindings).compactMap(Self.run)
    }

    private static func run(_ row: Row) -> Run? {
        guard let id = row.uuid("id"), let sourceID = row.uuid("source_id"),
              let startedAt = row.date("started_at") else { return nil }
        var run = Run(id: id, sourceID: sourceID, startedAt: startedAt,
                      trigger: row.string("trigger").flatMap(RunTrigger.init(rawValue:)) ?? .manual,
                      attempt: row.int("attempt") ?? 1)
        run.finishedAt = row.date("finished_at")
        run.status = row.string("status").flatMap(RunStatus.init(rawValue:)) ?? .failed
        run.documentsFound = row.int("documents_found") ?? 0
        run.documentsNew = row.int("documents_new") ?? 0
        run.errorMessage = row.string("error_message")
        run.screenshotPath = row.string("screenshot_path")
        run.outlinePath = row.string("outline_path")
        return run
    }

    public func appendLog(_ record: RedactingLogger.LogRecord) async throws {
        guard let runID = record.runID else { return }
        // The message has already been through redaction on its way out of the
        // logger; storing the raw text would defeat that.
        try await database.run("""
            INSERT INTO run_log (run_id, timestamp, level, step, message) VALUES (?, ?, ?, ?, ?)
            """, [SQLValue(runID), SQLValue(record.timestamp), .text(record.level.rawValue),
                  SQLValue(record.step), .text(record.message)])
    }

    public func logs(runID: UUID) async throws -> [RedactingLogger.LogRecord] {
        try await database.query(
            "SELECT * FROM run_log WHERE run_id = ? ORDER BY id", [SQLValue(runID)]
        ).compactMap { row in
            guard let timestamp = row.date("timestamp"), let message = row.string("message") else { return nil }
            return RedactingLogger.LogRecord(
                timestamp: timestamp,
                level: row.string("level").flatMap(RedactingLogger.Level.init(rawValue:)) ?? .info,
                message: message, sourceID: nil, runID: runID, step: row.string("step"))
        }
    }

    // MARK: - Documents

    public func upsert(_ document: InvoiceDocument) async throws {
        try await database.run("""
            INSERT INTO document (id, entity_id, source_id, plugin_document_id, sha256, relative_path,
                                  byte_size, issuer, number, issued_on, total_cents, net_cents, vat_cents,
                                  currency, vat_number, kind, origin, confidence_json, verified_by_human,
                                  extracted_text, notes, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                relative_path = excluded.relative_path,
                issuer = excluded.issuer, number = excluded.number, issued_on = excluded.issued_on,
                total_cents = excluded.total_cents, net_cents = excluded.net_cents,
                vat_cents = excluded.vat_cents, currency = excluded.currency,
                vat_number = excluded.vat_number, kind = excluded.kind,
                confidence_json = excluded.confidence_json,
                verified_by_human = excluded.verified_by_human,
                extracted_text = excluded.extracted_text, notes = excluded.notes,
                updated_at = excluded.updated_at
            """, [
                SQLValue(document.id), SQLValue(document.entityID), SQLValue(document.sourceID),
                SQLValue(document.pluginDocumentID), .text(document.sha256), .text(document.relativePath),
                .integer(document.byteSize), SQLValue(document.issuer), SQLValue(document.number),
                SQLValue(document.issuedOn), SQLValue(document.total?.cents), SQLValue(document.net?.cents),
                SQLValue(document.vat?.cents), SQLValue(document.total?.currency ?? document.net?.currency),
                SQLValue(document.vatNumber), .text(document.kind.rawValue), .text(document.origin.rawValue),
                SQLValue(json: document.fieldConfidence), SQLValue(document.verifiedByHuman),
                SQLValue(document.extractedText), SQLValue(document.notes),
                SQLValue(document.createdAt), SQLValue(document.updatedAt),
            ])
    }

    public func document(id: UUID) async throws -> InvoiceDocument? {
        try await database.query("SELECT * FROM document WHERE id = ?", [SQLValue(id)])
            .compactMap(Self.document).first
    }

    public func document(sha256: String) async throws -> InvoiceDocument? {
        try await database.query("SELECT * FROM document WHERE sha256 = ? LIMIT 1", [.text(sha256)])
            .compactMap(Self.document).first
    }

    public func document(sourceID: UUID, pluginDocumentID: String) async throws -> InvoiceDocument? {
        try await database.query(
            "SELECT * FROM document WHERE source_id = ? AND plugin_document_id = ? LIMIT 1",
            [SQLValue(sourceID), .text(pluginDocumentID)]
        ).compactMap(Self.document).first
    }

    public func documents(filter: DocumentFilter = DocumentFilter()) async throws -> [InvoiceDocument] {
        var sql = "SELECT d.* FROM document d"
        var conditions: [String] = []
        var bindings: [SQLValue] = []

        if let text = filter.searchText, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " JOIN document_fts f ON f.document_id = d.id"
            conditions.append("document_fts MATCH ?")
            bindings.append(.text(Self.ftsQuery(text)))
        }
        if let entityID = filter.entityID { conditions.append("d.entity_id = ?"); bindings.append(SQLValue(entityID)) }
        if let sourceID = filter.sourceID { conditions.append("d.source_id = ?"); bindings.append(SQLValue(sourceID)) }
        if let kind = filter.kind { conditions.append("d.kind = ?"); bindings.append(.text(kind.rawValue)) }
        if let origin = filter.origin { conditions.append("d.origin = ?"); bindings.append(.text(origin.rawValue)) }
        if let from = filter.issuedFrom { conditions.append("d.issued_on >= ?"); bindings.append(SQLValue(from)) }
        if let to = filter.issuedTo { conditions.append("d.issued_on <= ?"); bindings.append(SQLValue(to)) }
        if filter.needingReviewOnly { conditions.append("d.verified_by_human = 0") }
        if let exported = filter.exportedTo {
            conditions.append(exported.negated
                ? "NOT EXISTS (SELECT 1 FROM export_record e WHERE e.document_id = d.id AND e.destination_id = ? AND e.succeeded = 1)"
                : "EXISTS (SELECT 1 FROM export_record e WHERE e.document_id = d.id AND e.destination_id = ? AND e.succeeded = 1)")
            bindings.append(.text(exported.destinationID))
        }

        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY COALESCE(d.issued_on, d.created_at) DESC LIMIT ?"
        bindings.append(.integer(filter.limit))

        return try await database.query(sql, bindings).compactMap(Self.document)
    }

    /// FTS5 treats a lot of punctuation as syntax; users type invoice numbers
    /// full of it. Quote each term and append a prefix wildcard to the last one
    /// so that search feels live as they type.
    private static func ftsQuery(_ raw: String) -> String {
        let terms = raw.split(whereSeparator: { $0.isWhitespace }).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\""
        }
        guard let last = terms.last else { return "\"\"" }
        return (terms.dropLast() + [last + "*"]).joined(separator: " ")
    }

    public func deleteDocument(id: UUID) async throws {
        try await database.run("DELETE FROM document WHERE id = ?", [SQLValue(id)])
    }

    public func documentCount(sourceID: UUID) async throws -> Int {
        try await database.query("SELECT COUNT(*) AS n FROM document WHERE source_id = ?", [SQLValue(sourceID)])
            .first?.int("n") ?? 0
    }

    public func allRelativePaths() async throws -> Set<String> {
        Set(try await database.query("SELECT relative_path FROM document").compactMap { $0.string("relative_path") })
    }

    private static func document(_ row: Row) -> InvoiceDocument? {
        guard let id = row.uuid("id"), let entityID = row.uuid("entity_id"),
              let sha = row.string("sha256"), let path = row.string("relative_path"),
              let createdAt = row.date("created_at") else { return nil }

        var document = InvoiceDocument(
            id: id, entityID: entityID, sourceID: row.uuid("source_id"),
            pluginDocumentID: row.string("plugin_document_id"), sha256: sha,
            relativePath: path, byteSize: row.int("byte_size") ?? 0,
            kind: row.string("kind").flatMap(DocumentKind.init(rawValue:)) ?? .invoice,
            origin: row.string("origin").flatMap(DocumentOrigin.init(rawValue:)) ?? .portal,
            createdAt: createdAt)

        let currency = row.string("currency") ?? "EUR"
        document.issuer = row.string("issuer")
        document.number = row.string("number")
        document.issuedOn = row.date("issued_on")
        document.total = row.int("total_cents").map { Money(cents: $0, currency: currency) }
        document.net = row.int("net_cents").map { Money(cents: $0, currency: currency) }
        document.vat = row.int("vat_cents").map { Money(cents: $0, currency: currency) }
        document.vatNumber = row.string("vat_number")
        document.fieldConfidence = row.json("confidence_json", as: [String: Double].self) ?? [:]
        document.verifiedByHuman = row.bool("verified_by_human")
        document.extractedText = row.string("extracted_text")
        document.notes = row.string("notes")
        document.updatedAt = row.date("updated_at") ?? createdAt
        return document
    }

    // MARK: - Exports

    public func record(_ record: ExportRecord) async throws {
        try await database.run("""
            INSERT INTO export_record (id, document_id, destination_id, destination_kind,
                                       exported_at, succeeded, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """, [SQLValue(record.id), SQLValue(record.documentID), .text(record.destinationID),
                  .text(record.destinationKind.rawValue), SQLValue(record.exportedAt),
                  SQLValue(record.succeeded), SQLValue(record.detail)])
    }

    public func hasBeenExported(documentID: UUID, destinationID: String) async throws -> Bool {
        let rows = try await database.query("""
            SELECT 1 AS present FROM export_record
            WHERE document_id = ? AND destination_id = ? AND succeeded = 1 LIMIT 1
            """, [SQLValue(documentID), .text(destinationID)])
        return !rows.isEmpty
    }

    public func exportRecords(documentID: UUID) async throws -> [ExportRecord] {
        try await database.query(
            "SELECT * FROM export_record WHERE document_id = ? ORDER BY exported_at DESC",
            [SQLValue(documentID)]
        ).compactMap { row in
            guard let id = row.uuid("id"), let documentID = row.uuid("document_id"),
                  let destinationID = row.string("destination_id"),
                  let kind = row.string("destination_kind").flatMap(ExportDestinationKind.init(rawValue:)),
                  let exportedAt = row.date("exported_at") else { return nil }
            return ExportRecord(id: id, documentID: documentID, destinationID: destinationID,
                                destinationKind: kind, exportedAt: exportedAt,
                                succeeded: row.bool("succeeded"), detail: row.string("detail"))
        }
    }

    // MARK: - Settings

    public func setting(_ key: String) async throws -> String? {
        try await database.query("SELECT value FROM setting WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String?) async throws {
        if let value {
            try await database.run("""
                INSERT INTO setting (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, [.text(key), .text(value)])
        } else {
            try await database.run("DELETE FROM setting WHERE key = ?", [.text(key)])
        }
    }
}

public struct DocumentFilter: Sendable {
    public var entityID: UUID?
    public var sourceID: UUID?
    public var kind: DocumentKind?
    public var origin: DocumentOrigin?
    public var issuedFrom: Date?
    public var issuedTo: Date?
    public var searchText: String?
    public var needingReviewOnly: Bool
    public var exportedTo: ExportFilter?
    public var limit: Int

    public struct ExportFilter: Sendable {
        public var destinationID: String
        /// true selects documents *not* yet sent there, which is the query an
        /// export actually needs (F8.7).
        public var negated: Bool
        public init(destinationID: String, negated: Bool) {
            self.destinationID = destinationID; self.negated = negated
        }
    }

    public init(entityID: UUID? = nil, sourceID: UUID? = nil, kind: DocumentKind? = nil,
                origin: DocumentOrigin? = nil, issuedFrom: Date? = nil, issuedTo: Date? = nil,
                searchText: String? = nil, needingReviewOnly: Bool = false,
                exportedTo: ExportFilter? = nil, limit: Int = 1000) {
        self.entityID = entityID; self.sourceID = sourceID; self.kind = kind
        self.origin = origin; self.issuedFrom = issuedFrom; self.issuedTo = issuedTo
        self.searchText = searchText; self.needingReviewOnly = needingReviewOnly
        self.exportedTo = exportedTo; self.limit = limit
    }
}
