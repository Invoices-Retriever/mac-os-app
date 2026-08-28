# Architecture

Why this is built the way it is. The specification is in
[CAHIER_DES_CHARGES.md](CAHIER_DES_CHARGES.md); this document records the
decisions taken since, including the one place we knowingly departed from it.

## The decisions that were open, and how they were settled

The specification listed seven blocking questions (§12). Four of them are
answered by this codebase.

### D2 — Licence: AGPL-3.0

The application is AGPL-3.0-or-later. Plugins are MIT and the schema Apache-2.0.

The reasoning is the one the specification gives: the AGPL stops a competitor
turning this into a closed SaaS without contributing back, which is consistent
with a project whose entire pitch is that everything is open. Plugins get a
permissive licence because a plugin is a description of a public portal, and a
copyleft licence there would discourage the contributions the project actually
needs.

This is the decision that is hardest to reverse — changing it later needs every
contributor's agreement — which is why it was taken before the first line of
code rather than after.

### D3 — Browser: WebKit, embedded, not a separate Chromium

The specification recommended Tauri with an embedded Chromium driven over CDP,
downloaded on first launch.

**We build on WebKit instead, through `WKWebView`.** That is a departure and it
is worth being honest about the trade:

*What it costs.* The specification rejected this option because "the future
Windows/Linux port would be a rewrite". That risk is real and it has not gone
away. What has changed is where the risk sits: every plugin semantic lives in
`IRCore`, which does not import WebKit and talks only to a `BrowserSession`
protocol — 14 methods, all of them things any browser automation layer can do.
A port is a new implementation of that protocol plus a new UI, not a rewrite of
the engine, the format, the validator, the vault, the extraction or the exports.
The step executor's tests already run against a scripted fake with no browser at
all, which is the practical proof that the boundary is real.

The second cost is reproducibility. Plugin selectors are matched by whatever
engine renders the page, and WebKit is not Chromium. A plugin that works for one
user works for all of them — everyone has the same WebKit — but a contributor
testing in Chrome may write a selector that behaves differently here. The
mitigation is the developer tooling: `irctl run --step` uses the same engine the
app uses, so a plugin is always tested in the environment it will run in.

*What it buys.* A 4 MB application instead of a 200–400 MB one, with no runtime
to download on first launch. Native Keychain, native Vision OCR, native
notifications, native PDF rendering — all from the SDK, none of them a
dependency. And `WKWebsiteDataStore(forIdentifier:)` gives per-source persistent
profiles as a first-class platform feature rather than as directory management.

The decision that made this defensible is not the choice of WebKit; it is the
`BrowserSession` boundary. Keep it.

### D4 — Plugin format: inspired by Invoice Radar, not compatible with it

The specification flagged that reusing Invoice Radar's format would grant
immediate access to their plugin catalogue, at the cost of depending on a
third-party format with no explicit licence.

This format takes the same shape — declarative JSON, a step vocabulary,
`{{…}}` substitution, `checkAuth` / `startAuth` / `getDocuments` — because that
shape is a good one and arriving at a different one would be perverse. It is not
compatible, and it adds three things the specification asked for:

- `allowedDomains`, **mandatory**. This is the difference that matters. Without
  it, a community plugin can navigate anywhere carrying the user's live session
  cookies.
- `runJs` under a flag: declared in the manifest, cross-checked against the
  actual steps, badged in the catalogue, and unmergeable by CI alone.
- `country` and `tags`, so the catalogue is navigable by market — which is the
  project's editorial bet.

### D6 — Extraction: included, layered, and the model is off

Four layers, in decreasing order of trust, each recording its confidence on the
field it filled:

| Layer | Confidence | Where |
| --- | --- | --- |
| Declared by the plugin | 0.95 | `StepExecutor.emit` |
| Regular expressions over the PDF's text | 0.75 | `MetadataExtractor` + `InvoicePatterns` |
| On-device OCR (Vision) for scans | 0.55 | `MetadataExtractor.ocrText` |
| A language model | 0.7 | protocol only, **no implementation ships enabled** |

Arithmetic beats pattern matching: when two of {total, net, VAT} are known, the
third is computed rather than guessed, and when all three are present and
inconsistent, every one of them is marked as doubtful instead of one being
picked as the winner.

The language-model layer is a protocol with no default implementation. That is
the point. A default-on cloud call would break the promise the product is built
on, and the setting that enables it names the provider and says out loud that
the user becomes responsible for the transfer.

## The three things worth understanding before changing anything

### The domain sandbox is enforced three times, on purpose

1. **`WKContentRuleList`** — compiled from `allowedDomains` as "block
   everything, then un-block these hosts". This is the one that matters: it
   covers subresources, so a `fetch()` to an attacker's server is stopped, not
   just a navigation. Compilation failing is fatal to session creation, because
   failing open would silently remove the control.
2. **`WKNavigationDelegate`** — cancels out-of-policy top-level navigations, so
   the failure has a name (`domainNotAllowed`) instead of being a blank page.
3. **`StepExecutor.check(_:)`** — before `navigate` and `downloadPdf`, so a URL
   built at run time from a template is caught with a message naming the host.

The third one is not redundant with the first two. `allowedDomains` can be
checked statically for literal URLs — the validator and the CI both do — but
`{{item.link}}` cannot be, and that is exactly the shape a malicious plugin
would use.

### Redaction happens once, on the way out

`RedactingLogger` is the only place a secret is masked, and `CredentialVault`
registers every value with it at the moment it is read, before anything can use
it. There is deliberately no window in which a secret exists but redaction does
not know about it.

The alternative — masking at each call site — fails the first time someone adds
a log line and forgets. This one cannot be forgotten, only removed, and removing
it is visible.

Values shorter than four characters are not registered: redacting every
occurrence of a two-character password would destroy the log and tell an
attacker where it appeared.

### The folder is the truth; SQLite is an index

Documents live in a folder the user chose, in `year/month` directories, with
filenames they configured. Anyone can open it in Finder and understand it. The
SQLite database holds metadata and pointers, and `DocumentLibrary.rescan`
rebuilds it from the folder alone.

This constrains what may be stored: nothing goes in the database that exists
nowhere else. It is also why deletion asks whether to move the file to the Trash
separately from forgetting the row — the two are genuinely different operations.

## Deduplication

Two keys, because they catch different mistakes:

- **`(source_id, plugin_document_id)`**, a unique index. Catches a portal
  re-rendering the same invoice into byte-different PDF. This one is a hard
  constraint: one source cannot report the same identifier twice.
- **`sha256`**, an index rather than a constraint. Catches the same document
  arriving from a portal and from a mailbox. Not a constraint because the
  application should decide what to do about that, not the database.

A plugin whose `document.id` is unstable — a row index, a timestamp — defeats
the first key and users collect duplicates every month. It is the single most
common way a plugin is subtly wrong, which is why `CONTRIBUTING` in the plugins
repository says to run every plugin twice.

## Concurrency

`IRCore` is Swift 6 strict-concurrency clean with no `@preconcurrency` escapes.
`Store` and `PluginCatalog` are actors; `CollectionService` is an actor holding
the in-flight task table; `RedactingLogger` is a lock-protected class because it
is called from everywhere including synchronous WebKit delegate callbacks.
`WebKitBrowserSession` is `@MainActor`, which is where WebKit has to live.

Bounded parallelism during a batch is two sources by default. More is not
faster: each source is a browser, and portals notice bursts.

## What is not built yet

Honestly, so nobody rediscovers it:

- E-mail collection (IMAP, Gmail OAuth, Microsoft Graph) — specified, absent.
- Paperless-ngx and e-mail exports — the `Exporter` protocol is ready for both.
- The language-model extractor — protocol only.
- Signing, notarisation and an update channel.
- Multi-entity separation. The data model carries `entity_id` everywhere and the
  store is written for it; the UI keeps exactly one and shows no picker.
