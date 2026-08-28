# Invoices Retriever

**An open-source, local-first invoice collector for macOS.**

A growing share of supplier invoices never arrives by e-mail. It sits behind a
login on a portal — AWS, Google Ads, Meta, OVH, Free Pro, URSSAF, Amazon
Business — and every month you repeat the same journey by hand: sign in, get
through two-factor, find the billing history, download, rename, file, forward.
The time it costs grows linearly with the number of suppliers.

Invoices Retriever does that journey for you, on your own Mac. It signs in to
your accounts, downloads what is new since last time, reads the date, number and
amount off each document, names it the way you asked, and puts it where you
expect it.

Nothing leaves your machine except requests to your suppliers' own websites.
There is no account, no server of ours, and no telemetry.

> **Status: early.** The engine, the plugin format, the library and the exports
> are built and tested. The plugin catalogue is not: see
> [Coverage](#coverage) before expecting it to collect your invoices today.

---

## How it works

```
┌──────────────────────────────────────────────────────┐
│  SwiftUI                                             │
│  Sources · Library · Catalogue · Runs · Developer    │
└───────────────────────┬──────────────────────────────┘
┌───────────────────────▼──────────────────────────────┐
│  IRCore                                              │
│  ┌───────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │ Scheduler │ │ Step executor│ │ Credential      │  │
│  │           │ │ (the DSL)    │ │ vault (Keychain)│  │
│  └───────────┘ └──────┬───────┘ └─────────────────┘  │
│  ┌───────────┐ ┌──────▼───────┐ ┌─────────────────┐  │
│  │ Extractor │ │ BrowserSession│ │ Exporters      │  │
│  │ regex/OCR │ │  + domain     │ │ folder·CSV·    │  │
│  │           │ │    sandbox    │ │ JSON·webhook   │  │
│  └───────────┘ └──────┬───────┘ └─────────────────┘  │
└───────────────────────┼──────────────────────────────┘
              ┌─────────▼──────────┐
              │ IRBrowser (WebKit) │  one profile per source
              └────────────────────┘

   SQLite (index) · your document folder · Keychain (secrets)
```

**A plugin is a JSON file, not code.** It describes how to tell whether you are
signed in, how to sign in, and where the invoices are. The application
interprets a fixed vocabulary of steps. That is what makes a contribution
reviewable by a maintainer who is not a Swift developer, and what keeps the
attack surface of community content small.

**Every plugin runs inside a domain sandbox.** `allowedDomains` is mandatory,
and it is enforced by WebKit's content blocker — navigations *and* subresources
— not by the plugin. A plugin cannot reach a host it did not declare, so it
cannot carry your session cookies anywhere else. This is the single most
important control in the project.

**Secrets live in the Keychain and nowhere else.** Not in the database, not in a
preferences file, not in a log. Every value the vault hands out is registered
with a redacting logger first, so it cannot appear in a run log, a failure
screenshot or an anomaly report.

## Building

Requires macOS 14 and a Swift 6 toolchain. Xcode is not needed.

```bash
git clone https://github.com/Invoices-Retriever/mac-os-app
cd mac-os-app

swift run irtest            # the test suite
./Scripts/build-app.sh      # produces build/Invoices Retriever.app
```

For a signed, distributable build set `IR_SIGNING_IDENTITY` to a Developer ID
Application certificate before running the script; it prints the notarisation
commands afterwards. Distribution is outside the Mac App Store on purpose — the
App Store sandbox cannot host a driven browser with per-source persistent
profiles.

## `irctl`

The command-line half, shipped inside the app bundle. It is what plugin authors
and CI both use, and it runs the same validator and the same engine as the app.

```bash
export PATH="/Applications/Invoices Retriever.app/Contents/MacOS:$PATH"

irctl validate plugins/            # every rule CI applies
irctl run plugins/ovh.json --step  # walk a plugin against the real portal
irctl extract invoice.pdf          # show what the metadata extractor reads
irctl catalog                      # fetch and verify the published plugin index
irctl keygen                       # a signing key pair for a plugin index
```

## Coverage

Plugins live in a separate repository:
**[Invoices-Retriever/plugins](https://github.com/Invoices-Retriever/plugins)**.
The rhythm of contribution there is an order of magnitude higher than here, and
the barrier to entry should be one JSON file with no compiler.

The bet this project is making is editorial rather than technical: French and
European supplier coverage is poor in the German-speaking commercial
alternatives, and that is where a community can create value quickly. If your
supplier is missing, you are the person best placed to add it — you have the
account.

## What this is not

- **Not an accounting package, and not a document management system.** It
  exports to the tools you already use rather than replacing them.
- **Not for issuing invoices.** That is a different product and well served.
- **Not a legally probative archive.** Retention with evidential value remains
  your responsibility or your DMS's.
- **Not a way around a portal's protections.** If a supplier blocks automated
  access, the plugin fails and asks you to fetch that one by hand. See
  [CONTRIBUTING](CONTRIBUTING.md#the-three-rules).

## Licence

The application is [AGPL-3.0-or-later](LICENSE). Plugins are MIT and the plugin
schema is Apache-2.0, both in the plugins repository — a plugin is a description
of a public portal, and a copyleft licence there would discourage exactly the
contributions this project needs.

## Documents

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on the app, and the rules
- [SECURITY.md](SECURITY.md) — reporting a vulnerability
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — why it is built this way
- [docs/CAHIER_DES_CHARGES.md](docs/CAHIER_DES_CHARGES.md) — the original
  specification, in French
- [CHANGELOG.md](CHANGELOG.md)
