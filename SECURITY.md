# Security

This application holds the credentials to every supplier account a user owns and
executes content written by the community. That combination is why the threat
model is written down rather than assumed.

## Reporting a vulnerability

**Do not open a public issue.**

Use GitHub's private vulnerability reporting on this repository
(Security → Report a vulnerability), or e-mail the address in
[MAINTAINERS.md](MAINTAINERS.md) with `SECURITY` in the subject.

What to expect:

| | |
| --- | --- |
| Acknowledgement | within 3 working days |
| First assessment | within 10 working days |
| Fix or mitigation for a critical issue | within 30 days, or a public advisory explaining why not |

Please include what you did, what happened, and what you expected. A proof of
concept helps; a working exploit against someone else's account does not, and is
not something we want.

We do not run a bounty programme. We will credit you in the advisory and the
changelog unless you would rather we did not.

## What counts

In scope, and taken seriously:

- Anything that lets a plugin reach a domain outside its `allowedDomains`.
- Anything that gets a secret into a log, a screenshot, an anomaly report or the
  SQLite index.
- Anything that lets one source read another source's cookies or session.
- Anything that installs or runs a plugin without the signature check on the
  index passing.
- Anything that makes the application write outside the folders the user chose.
- Escalation from a malicious plugin to code execution outside the browser.

Out of scope:

- A plugin scraping data the signed-in user can already see. That is what
  plugins do.
- Denial of service against a supplier's portal, which our rate limiting exists
  to prevent, not to enable.
- Anything requiring an attacker to already have the user's unlocked Mac.
- Reports from automated scanners with no demonstrated impact.

## The controls, so you know what to test

| Threat | Control |
| --- | --- |
| A malicious plugin exfiltrating cookies or credentials | `allowedDomains` compiled into a `WKContentRuleList` that blocks everything and un-blocks the declared hosts; the navigation delegate refuses out-of-policy navigations a second time; the step executor checks a third time so the error names the host |
| A legitimate plugin compromised by a later contributor | Every pull request touching a plugin is reviewed by a human; `runJs` cannot be merged by CI at all; the index is signed with a key held outside the repository |
| Secrets leaking into logs or reports | Redaction happens once, centrally, on the way out of the logger; every vault read registers the value before it is used; screenshots are never transmitted |
| Exfiltration through the language-model fallback | Off by default; the provider is the user's own choice; the user is shown what would be sent |
| A stolen machine | Secrets are in the Keychain with `ThisDeviceOnly`, never in SQLite or a configuration file; per-source Touch ID is available |
| Supply chain | The application has no third-party dependencies. Everything comes from the macOS SDK |

## Revoking a plugin

If a malicious or compromised plugin is ever published: it is removed from the
repository, a new index is published without it, and installed copies delete it
on their next index refresh — a plugin that disappears from the index is
uninstalled rather than left in place. An advisory goes out on this repository
the same day.

## Verifying a release

Releases are signed and notarised, and ship with an SBOM. To check a download:

```bash
codesign --verify --deep --strict --verbose=2 "/Applications/Invoices Retriever.app"
spctl --assess --type execute --verbose "/Applications/Invoices Retriever.app"
```
