# Contributing to the application

Most people who want to help this project should be writing **plugins**, not
Swift. Plugins live in
[Invoices-Retriever/plugins](https://github.com/Invoices-Retriever/plugins) and
each is a single JSON file; that repository's `CONTRIBUTING.md` is the one you
want. This document is about the application itself.

## The three rules

These constrain what the application is allowed to do, and they come before any
feature.

1. **Never circumvent a technical protection measure.** No captcha solving, no
   spoofed browser fingerprints, no code whose purpose is to look less like
   automation. When a portal blocks us, the correct behaviour is to fail with a
   clear message telling the user to fetch that one by hand. Automating the
   retrieval of your own invoices is legitimate; defeating a supplier's
   defences is not, and it would put every user of this software in a worse
   position than they are now.
2. **Keep to a human request rate.** `RateLimiter` exists for this. Do not add a
   path around it.
3. **Collect nothing beyond the user's own documents.**

These deliberately limit coverage. A pull request that trades one of them for a
working plugin is declined.

## Building

```bash
swift build              # everything
swift run irtest         # the test suite — must be green before you push
swift run irctl help
./Scripts/build-app.sh   # build/Invoices Retriever.app
```

Xcode is not required, and the project is arranged to keep it that way: there is
no `.xcodeproj` to fall out of sync, and the test suite is a plain executable
because Apple's Command Line Tools ship neither XCTest nor swift-testing. If you
use Xcode, open `Package.swift` directly.

## The shape of the code

| Target | What lives there |
| --- | --- |
| `IRCore` | Everything headless: models, the plugin format and validator, the step executor, the vault, the store, extraction, the library, exporters. No WebKit, no AppKit. |
| `IRBrowser` | The WebKit driver. The only place that knows about `WKWebView`. |
| `InvoicesRetriever` | SwiftUI. Talks to the core only through `AppModel`. |
| `irctl` | The command-line tool, for plugin authors and CI. |
| `irtest` | The test suite. |

Two boundaries matter and are worth defending in review:

- **`IRCore` does not import WebKit.** The step executor talks to a
  `BrowserSession` protocol, which is why it can be tested against a scripted
  fake with no network and no browser — and why a future Windows or Linux port
  is a new driver rather than a rewrite.
- **`Views/` cannot reach a secret.** No view owns a `CredentialVault`.
  Everything security-relevant goes through `AppModel`, which is small enough to
  read in one sitting.

## Where the rules about security live

If you are changing any of these, say so explicitly in the pull request
description, because they carry the guarantees in [SECURITY.md](SECURITY.md):

- `Security/DomainPolicy.swift` — the sandbox. It fails closed; keep it that
  way.
- `Logging/RedactingLogger.swift` — the only place redaction happens.
- `Vault/` — the only door in and out of the Keychain.
- `IRBrowser/WebKitBrowserSession.swift` — content rules, navigation policy,
  per-source data stores.

Changes to any of them need a test that would fail without the change.

## Adding a step to the plugin vocabulary

Adding a capability to the format is deliberately more work than adding a helper
function, because every action is permanently part of what a community plugin
can do. In order:

1. Add the branch to `schema/plugin-v1.schema.json`, with a `description`
   written for a contributor rather than for a compiler.
2. Add the field to `PluginStep` and the case to `StepAction`.
3. Implement it in `StepExecutor.execute`.
4. Add the per-action requirements to `PluginValidator`.
5. Mirror the cheap checks in the plugins repository's `scripts/validate.mjs`.
6. Test it against `FakeBrowserSession`.
7. Document it in the plugins repository's `CONTRIBUTING.md`.
8. Copy the schema to `Sources/IRCore/Resources/` and to the plugins repository
   — CI diffs all three copies.

If the answer to "why can't this be an `extract` with a regex?" is not obvious,
it probably can be.

## Tests

`swift run irtest`. The suite is ordered from values upwards — amounts, dates,
the security controls, the engine, storage — so the first failure is usually the
cause of the rest.

Write a test when you fix a bug: the shape of the bug is the interesting part,
not the fix. Tests that pin down security behaviour should read as statements
about the guarantee ("the engine refuses a navigation outside the sandbox even
if the URL is built at run time") rather than about the implementation.

## Adding or changing a user-facing string

Every string goes through `t("…")`, `tn("…", count)` for counted ones, or
`core("…")` in `IRCore`. The key is the English text, so an unbundled build
reads correctly with no catalogue loaded.

After changing one, add it to both `en.lproj/Localizable.strings` and
`fr.lproj/Localizable.strings` (and the `.stringsdict` if it is counted). The
test suite compares the catalogues against the strings the code actually asks
for and fails on a key that is missing, orphaned, untranslated, or that lost a
`%@` on the way into French — so `swift run irtest` will tell you what you
forgot.

Do not reach for `Text("…")` with a literal: SwiftUI would resolve it against
`Bundle.main`, which is not where the catalogues live, and it would silently
work in English only.

## Style

Match the surrounding code. A few things that are not obvious from reading it:

- Comments explain **why**, and are worth writing where a reader would otherwise
  wonder whether something was an accident. Comments that restate the code are
  removed in review.
- Errors are `IRError`, and the case you choose decides whether the engine
  retries. Getting `authenticationFailed` wrong means retrying a bad password
  until an account locks.
- User-facing strings are written for someone who is not a developer and who is
  slightly annoyed. "Sign-in needed" beats "AUTH_EXPIRED".
- Money is `Money`, in integer minor units. Never a `Double`.

## Pull requests

One change per pull request. Say what it does and why; if it touches anything in
the security list above, say that too. Green tests are the baseline, not the
goal.
