# Changelog

Notable changes to Invoices Retriever. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
semantic versioning.

## [Unreleased]

### Added

- **Plugin engine.** A declarative JSON format (schema v1) with a 21-action step
  vocabulary, `{{…}}` template resolution, `forEach` iteration over listing
  rows, conditional branches, and network-response extraction.
- **Domain sandbox.** `allowedDomains` is mandatory and enforced by WebKit's
  content blocker across navigations and subresources, with a second check in
  the navigation delegate and a third in the step executor.
- **Browser driver.** WebKit, one persistent `WKWebsiteDataStore` per source, so
  two accounts with the same supplier never share a session and two-factor
  authentication is not replayed every month.
- **Credential vault.** macOS Keychain, one item per source per field,
  `ThisDeviceOnly`, with optional per-source Touch ID and RFC 6238 TOTP
  generation.
- **Redacting logger.** Central, tested redaction of every vault value on the
  way out, covering percent-encoded forms.
- **Library.** SQLite index over a folder that stays readable without the app,
  deduplication by SHA-256 and by (source, plugin document id), a configurable
  naming template, full-text search, and a rescan that rebuilds the index from
  the folder alone.
- **Metadata extraction.** Plugin-declared values first, then multilingual
  (FR/EN/DE) regular expressions over the PDF text, then on-device OCR via
  Vision. Amounts are reconciled arithmetically and each field carries a
  confidence score. The language-model fallback is defined but off.
- **Exports.** Folder, CSV and JSON registers, and webhook — all idempotent by
  default.
- **Scheduling and notifications**, off until explicitly enabled, with no
  background daemon.
- **`irctl`.** Validate, lint, step-debug, extract, and build and sign a plugin
  index.
- **French and English interface.** Both catalogues are complete, with plural
  rules per language — French treats zero as singular, English does not — and a
  picker in Settings that overrides the system language. Dates and amounts
  follow the user's regional settings independently of the interface language.
- **`irtest`.** A dependency-free test suite that runs without Xcode, including
  checks that the two catalogues cover exactly the strings the code asks for and
  that no placeholder is lost in translation.

### Known gaps

- The plugin catalogue is drafts only; nothing has been verified against a live
  supplier account yet.
- E-mail collection (IMAP, Gmail, Microsoft Graph) is specified but not built.
- Paperless-ngx and e-mail exports are not built.
- The application is not yet signed or notarised, and there is no update
  channel.
