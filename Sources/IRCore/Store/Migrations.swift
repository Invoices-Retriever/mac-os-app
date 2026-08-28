import Foundation

/// Forward-only, numbered migrations. Each is applied once and recorded, so a
/// database from any earlier build catches up on launch.
public enum Migrations {

    public struct Migration: Sendable {
        public let version: Int
        public let name: String
        public let sql: String
    }

    public static let all: [Migration] = [
        Migration(version: 1, name: "initial schema", sql: """
        CREATE TABLE entity (
            id           TEXT PRIMARY KEY NOT NULL,
            name         TEXT NOT NULL,
            vat_number   TEXT,
            created_at   TEXT NOT NULL
        );

        CREATE TABLE source (
            id                   TEXT PRIMARY KEY NOT NULL,
            entity_id            TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
            plugin_id            TEXT NOT NULL,
            plugin_version       TEXT NOT NULL,
            display_name         TEXT NOT NULL,
            is_enabled           INTEGER NOT NULL DEFAULT 1,
            config_json          TEXT NOT NULL DEFAULT '{}',
            options_json         TEXT NOT NULL DEFAULT '{}',
            remember_credentials INTEGER NOT NULL DEFAULT 1,
            autofill_enabled     INTEGER NOT NULL DEFAULT 1,
            schedule_json        TEXT NOT NULL DEFAULT '{}',
            lookback_days        INTEGER NOT NULL DEFAULT 90,
            last_run_at          TEXT,
            last_success_at      TEXT,
            last_run_status      TEXT,
            last_error_message   TEXT,
            document_count       INTEGER NOT NULL DEFAULT 0,
            created_at           TEXT NOT NULL
        );
        CREATE INDEX idx_source_entity ON source(entity_id);
        CREATE INDEX idx_source_plugin ON source(plugin_id);

        CREATE TABLE run (
            id              TEXT PRIMARY KEY NOT NULL,
            source_id       TEXT NOT NULL REFERENCES source(id) ON DELETE CASCADE,
            started_at      TEXT NOT NULL,
            finished_at     TEXT,
            status          TEXT NOT NULL,
            documents_found INTEGER NOT NULL DEFAULT 0,
            documents_new   INTEGER NOT NULL DEFAULT 0,
            error_message   TEXT,
            screenshot_path TEXT,
            attempt         INTEGER NOT NULL DEFAULT 1,
            trigger         TEXT NOT NULL DEFAULT 'manual'
        );
        CREATE INDEX idx_run_source_started ON run(source_id, started_at DESC);

        CREATE TABLE run_log (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id    TEXT NOT NULL REFERENCES run(id) ON DELETE CASCADE,
            timestamp TEXT NOT NULL,
            level     TEXT NOT NULL,
            step      TEXT,
            message   TEXT NOT NULL
        );
        CREATE INDEX idx_run_log_run ON run_log(run_id, id);

        CREATE TABLE document (
            id                 TEXT PRIMARY KEY NOT NULL,
            entity_id          TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
            source_id          TEXT REFERENCES source(id) ON DELETE SET NULL,
            plugin_document_id TEXT,
            sha256             TEXT NOT NULL,
            relative_path      TEXT NOT NULL,
            byte_size          INTEGER NOT NULL,
            issuer             TEXT,
            number             TEXT,
            issued_on          TEXT,
            total_cents        INTEGER,
            net_cents          INTEGER,
            vat_cents          INTEGER,
            currency           TEXT,
            vat_number         TEXT,
            kind               TEXT NOT NULL DEFAULT 'invoice',
            origin             TEXT NOT NULL DEFAULT 'portal',
            confidence_json    TEXT NOT NULL DEFAULT '{}',
            verified_by_human  INTEGER NOT NULL DEFAULT 0,
            extracted_text     TEXT,
            notes              TEXT,
            created_at         TEXT NOT NULL,
            updated_at         TEXT NOT NULL
        );

        -- The two deduplication keys of F7.3. The first is a hard constraint:
        -- one source cannot produce the same document identifier twice. The
        -- second is an index rather than a constraint, because the same PDF
        -- legitimately arrives from a portal and from a mailbox, and the app
        -- decides what to do about it rather than the database refusing it.
        CREATE UNIQUE INDEX idx_document_source_plugin_id
            ON document(source_id, plugin_document_id)
            WHERE plugin_document_id IS NOT NULL;
        CREATE INDEX idx_document_sha256 ON document(sha256);
        CREATE INDEX idx_document_issued_on ON document(issued_on DESC);
        CREATE INDEX idx_document_entity ON document(entity_id);
        CREATE UNIQUE INDEX idx_document_path ON document(relative_path);

        CREATE TABLE export_record (
            id               TEXT PRIMARY KEY NOT NULL,
            document_id      TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
            destination_id   TEXT NOT NULL,
            destination_kind TEXT NOT NULL,
            exported_at      TEXT NOT NULL,
            succeeded        INTEGER NOT NULL DEFAULT 1,
            detail           TEXT
        );
        CREATE INDEX idx_export_document ON export_record(document_id);
        CREATE UNIQUE INDEX idx_export_idempotence
            ON export_record(document_id, destination_id) WHERE succeeded = 1;

        CREATE TABLE setting (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """),

        Migration(version: 2, name: "full-text search over documents", sql: """
        -- F7.5. Contentless FTS would be lighter, but keeping the text here
        -- means search still works if the PDF has moved and lets us rebuild the
        -- index without re-reading every file.
        CREATE VIRTUAL TABLE document_fts USING fts5(
            document_id UNINDEXED,
            issuer, number, notes, extracted_text,
            tokenize = "unicode61 remove_diacritics 2"
        );

        CREATE TRIGGER document_fts_insert AFTER INSERT ON document BEGIN
            INSERT INTO document_fts(document_id, issuer, number, notes, extracted_text)
            VALUES (new.id, COALESCE(new.issuer,''), COALESCE(new.number,''),
                    COALESCE(new.notes,''), COALESCE(new.extracted_text,''));
        END;

        CREATE TRIGGER document_fts_delete AFTER DELETE ON document BEGIN
            DELETE FROM document_fts WHERE document_id = old.id;
        END;

        CREATE TRIGGER document_fts_update AFTER UPDATE ON document BEGIN
            DELETE FROM document_fts WHERE document_id = old.id;
            INSERT INTO document_fts(document_id, issuer, number, notes, extracted_text)
            VALUES (new.id, COALESCE(new.issuer,''), COALESCE(new.number,''),
                    COALESCE(new.notes,''), COALESCE(new.extracted_text,''));
        END;
        """),
        Migration(version: 3, name: "page outline captured on failure", sql: """
        ALTER TABLE run ADD COLUMN outline_path TEXT;
        """),
        Migration(version: 4, name: "saved export destinations", sql: """
        -- F8.5. A destination configured once and reused, rather than a dialog
        -- re-filled every month. `config` is JSON because what a destination
        -- needs differs by kind — a folder path, a URL, a list of recipients —
        -- and columns for the union of those would be mostly NULL.
        --
        -- Nothing secret is in here: a webhook's Authorization header and a
        -- Paperless token go to the keychain under the destination's id, the
        -- same rule the whole application follows.
        CREATE TABLE export_destination (
            id             TEXT PRIMARY KEY NOT NULL,
            entity_id      TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
            kind           TEXT NOT NULL,
            name           TEXT NOT NULL,
            config         TEXT NOT NULL DEFAULT '{}',
            runs_automatically INTEGER NOT NULL DEFAULT 0,
            created_at     TEXT NOT NULL,
            last_run_at    TEXT,
            last_succeeded INTEGER,
            last_detail    TEXT,
            documents_sent INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_export_destination_entity ON export_destination(entity_id);
        """),
    ]

    public static func migrate(_ database: Database) async throws {
        try await database.execute("""
        CREATE TABLE IF NOT EXISTS schema_migration (
            version    INTEGER PRIMARY KEY NOT NULL,
            name       TEXT NOT NULL,
            applied_at TEXT NOT NULL
        );
        """)

        let applied = try await database.query("SELECT version FROM schema_migration")
        let done = Set(applied.compactMap { $0.int("version") })

        for migration in all.sorted(by: { $0.version < $1.version }) where !done.contains(migration.version) {
            try await database.execute("BEGIN IMMEDIATE")
            do {
                try await database.execute(migration.sql)
                try await database.run(
                    "INSERT INTO schema_migration (version, name, applied_at) VALUES (?, ?, ?)",
                    [.integer(migration.version), .text(migration.name), SQLValue(Date())])
                try await database.execute("COMMIT")
                RedactingLogger.shared.info("Applied migration \(migration.version): \(migration.name)")
            } catch {
                try? await database.execute("ROLLBACK")
                throw error
            }
        }
    }
}
