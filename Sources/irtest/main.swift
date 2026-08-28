import Foundation
import IRCore

// The suites are ordered from "cannot possibly be wrong" upwards: value
// parsing, then the security controls, then the engine, then storage. When
// something breaks, the first failure in this list is usually the cause of the
// rest.

// Pin the interface language, so that a contributor on a French Mac and CI on
// an English one see the same assertions pass or fail. The localization suite
// changes it deliberately and puts it back.
Localization.setLanguage(.english)

await suite("Amounts") {
    await test("French format, non-breaking space and comma decimal") {
        expectEqual(MoneyParser.parse("1 234,56 €")?.cents, 123456)
        expectEqual(MoneyParser.parse("1 234,56 €")?.currency, "EUR")
        expectEqual(MoneyParser.parse("1\u{00A0}234,56 €")?.cents, 123456)
    }
    await test("Anglo format, comma thousands and dot decimal") {
        expectEqual(MoneyParser.parse("$1,234.56")?.cents, 123456)
        expectEqual(MoneyParser.parse("$1,234.56")?.currency, "USD")
    }
    await test("German format") {
        expectEqual(MoneyParser.parse("1.234,56 EUR")?.cents, 123456)
    }
    await test("A separator with three digits after it is not a decimal mark") {
        expectEqual(MoneyParser.parse("1,234")?.cents, 123400)
        expectEqual(MoneyParser.parse("12.345")?.cents, 1234500)
    }
    await test("Negative amounts, as on a credit note") {
        expectEqual(MoneyParser.parse("-45,00 €")?.cents, -4500)
        expectEqual(MoneyParser.parse("−45,00 €")?.cents, -4500)   // U+2212 minus
    }
    await test("A string with no digits is not an amount") {
        expect(MoneyParser.parse("Total :") == nil)
        expect(MoneyParser.parse("") == nil)
    }
    await test("Rounding is to the nearest cent") {
        expectEqual(MoneyParser.parse("19.99")?.cents, 1999)
        expectEqual(MoneyParser.parse("0.005")?.cents, 1)
        expectEqual(MoneyParser.parse("0,004 €")?.cents, 0)
    }
    await test("Three digits after the separator: the group in front decides") {
        // German thousands, and a sub-cent unit price. Both shapes occur.
        expectEqual(MoneyParser.parse("1.005")?.cents, 100500)
        expectEqual(MoneyParser.parse("0.005")?.cents, 1)
    }
}

await suite("Dates") {
    func iso(_ raw: String) -> String? { InvoiceDateParser.parse(raw).map(InvoiceDateParser.isoString) }

    await test("The formats portals actually use") {
        expectEqual(iso("2026-03-31"), "2026-03-31")
        expectEqual(iso("31/03/2026"), "2026-03-31")
        expectEqual(iso("31.03.2026"), "2026-03-31")
        expectEqual(iso("2026-03-31T14:22:01Z"), "2026-03-31")
        expectEqual(iso("31 mars 2026"), "2026-03-31")
        expectEqual(iso("March 31, 2026"), "2026-03-31")
    }
    await test("Nonsense is refused rather than guessed at") {
        expect(InvoiceDateParser.parse("last Tuesday") == nil)
        expect(InvoiceDateParser.parse("") == nil)
    }
    await test("Everything normalises to UTC midnight, so two portals agree") {
        let a = InvoiceDateParser.parse("2026-03-31T23:59:00Z")
        let b = InvoiceDateParser.parse("2026-03-31")
        expectEqual(a, b)
    }
}

await suite("Semantic versions") {
    await test("Ordering, including prereleases") {
        expect(SemVer("1.2.3")! < SemVer("1.10.0")!)
        expect(SemVer("1.0.0-beta")! < SemVer("1.0.0")!)
        expect(SemVer("2.0.0")! > SemVer("1.99.99")!)
    }
    await test("Requirement ranges") {
        expect(VersionRequirement(">=1.0.0")!.isSatisfied(by: SemVer(1, 5, 0)))
        expect(!VersionRequirement(">=2.0.0")!.isSatisfied(by: SemVer(1, 5, 0)))
        expect(VersionRequirement("^1.0.0")!.isSatisfied(by: SemVer(1, 9, 0)))
        expect(!VersionRequirement("^1.0.0")!.isSatisfied(by: SemVer(2, 0, 0)))
        expect(!VersionRequirement("~1.2.0")!.isSatisfied(by: SemVer(1, 3, 0)))
    }
}

await suite("TOTP") {
    // RFC 6238 appendix B, secret "12345678901234567890" in base32.
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    await test("Matches the RFC 6238 test vectors") {
        expectEqual(try TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 8), "94287082")
        expectEqual(try TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 1111111109), digits: 8), "07081804")
        expectEqual(try TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 1234567890), digits: 8), "89005924")
    }
    await test("An otpauth:// URI is accepted whole") {
        let parsed = TOTP.normaliseSecret(
            "otpauth://totp/OVH:me?secret=\(secret)&digits=8&period=60&algorithm=SHA256")
        expectEqual(parsed?.secret, secret)
        expectEqual(parsed?.digits, 8)
        expectEqual(parsed?.period, 60)
        expect(parsed?.algorithm == .sha256)
    }
    await test("Spaces in a pasted secret are tolerated") {
        expectEqual(TOTP.normaliseSecret("gezd gnbv gy3t qojq")?.secret, "GEZDGNBVGY3TQOJQ")
    }
    await test("Codes are derived from seeds already in hand, not fetched again") {
        // Reading the seed a second time to generate a code cost a second
        // keychain prompt for a value the caller already had.
        var manifest = try decodeGoodPlugin()
        manifest.configSchema = ["mfa": ConfigField(type: .totp, label: "Two-factor")]

        let codes = try CredentialVault().totpCodes(
            from: ["mfa": "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"], manifest: manifest)
        expectEqual(codes["mfa"]?.count, 6)
        expect(codes["mfa"]?.allSatisfy(\.isNumber) == true)
    }

    await test("A field with no stored seed produces no code, rather than failing") {
        var manifest = try decodeGoodPlugin()
        manifest.configSchema = ["mfa": ConfigField(type: .totp, label: "Two-factor")]
        expect(try CredentialVault().totpCodes(from: [:], manifest: manifest).isEmpty)
    }

    await test("A secret that is not base32 is refused, not mangled") {
        expect(TOTP.normaliseSecret("not-base32-!!!") == nil)
    }
}

await suite("Domain sandbox") {
    let policy = DomainPolicy(allowedDomains: ["ovh.com", "*.ovh.com", "ovhcloud.com"])

    await test("Exact and wildcard hosts are allowed") {
        expect(policy.allows(url: URL(string: "https://ovh.com/billing")!))
        expect(policy.allows(url: URL(string: "https://www.ovh.com/manager")!))
        expect(policy.allows(url: URL(string: "https://api.eu.ovh.com/v1")!))
        expect(policy.allows(url: URL(string: "https://ovhcloud.com")!))
    }
    await test("Look-alike hosts are refused") {
        expect(!policy.allows(url: URL(string: "https://evil.example.com/collect")!))
        expect(!policy.allows(url: URL(string: "https://ovh.com.evil.example.com/")!))
        expect(!policy.allows(url: URL(string: "https://notovh.com/")!))
        expect(!policy.allows(url: URL(string: "https://ovhcloud.com.attacker.net/")!))
    }
    await test("A wildcard does not cover the apex; both must be declared") {
        let narrow = DomainPolicy(allowedDomains: ["*.example.com"])
        expect(narrow.allows(host: "www.example.com"))
        expect(!narrow.allows(host: "example.com"))
    }
    await test("The default policy denies everything — it fails closed") {
        expect(!DomainPolicy.denyAll.allows(url: URL(string: "https://ovh.com")!))
    }
    await test("Local schemes pass; file and ftp do not") {
        expect(policy.allows(url: URL(string: "about:blank")!))
        expect(policy.allows(url: URL(string: "data:text/html,hello")!))
        expect(!policy.allows(url: URL(string: "file:///etc/passwd")!))
        expect(!policy.allows(url: URL(string: "ftp://ovh.com/x")!))
    }
    await test("The content rule list blocks by default, then un-blocks") {
        let json = policy.contentRuleListJSON()
        let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        // Two filters per pattern: one for a port or path, one for a bare origin.
        expectEqual(rules.count, policy.patterns.count * 2 + 1)
        expectEqual((rules[0]["action"] as! [String: Any])["type"] as? String, "block")
        for rule in rules.dropFirst() {
            expectEqual((rule["action"] as! [String: Any])["type"] as? String, "ignore-previous-rules")
        }
    }
    await test("No filter uses alternation, which WebKit cannot compile") {
        // "Disjunctions are not supported yet" fails the whole list, and a
        // policy that will not compile means no session can start at all.
        // Caught in production, not in review.
        let json = policy.contentRuleListJSON()
        let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        for rule in rules {
            let filter = (rule["trigger"] as! [String: Any])["url-filter"] as! String
            expect(!filter.contains("|"), "alternation in '\(filter)'")
        }
    }
    await test("The host anchor still refuses a look-alike") {
        // What the anchor is for. A filter matching these would let a plugin
        // carry the user's session to an attacker's host.
        for filter in DomainPolicy.urlFilters(for: "ovh.com") {
            let regex = try NSRegularExpression(pattern: filter)
            func matches(_ url: String) -> Bool {
                regex.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil
            }
            expect(!matches("https://ovh.com.evil.example.com/"), "\(filter) matched a suffix host")
            expect(!matches("https://ovh.com@evil.example.com/"), "\(filter) matched userinfo")
            expect(!matches("https://evil.example.com/?x=https://ovh.com/"), "\(filter) matched a query")
        }
        let withPath = try NSRegularExpression(pattern: DomainPolicy.urlFilters(for: "ovh.com")[0])
        let url = "https://ovh.com/manager"
        expect(withPath.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil,
               "the real host stopped matching")
    }
}

await suite("Secret redaction") {
    let logger = RedactingLogger.shared

    await test("A registered secret never survives a log line") {
        logger.forgetSecrets()
        logger.registerSecret("hunter2-very-secret")
        let output = logger.redact("POST /login password=hunter2-very-secret&next=/")
        expect(!output.contains("hunter2-very-secret"))
        expect(output.contains("«redacted»"))
        logger.forgetSecrets()
    }
    await test("A percent-encoded secret is redacted too") {
        logger.forgetSecrets()
        logger.registerSecret("p@ssw0rd!value")
        let encoded = "p@ssw0rd!value".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        expect(!logger.redact("body=\(encoded)").contains(encoded))
        logger.forgetSecrets()
    }
    await test("Very short values are not registered, to keep logs readable") {
        logger.forgetSecrets()
        logger.registerSecret("ab")
        expectEqual(logger.redact("a table of abbreviations"), "a table of abbreviations")
        logger.forgetSecrets()
    }
    await test("Overlapping secrets are both masked") {
        logger.forgetSecrets()
        logger.registerSecret("secretvalue")
        logger.registerSecret("secretvalue-extended")
        expect(!logger.redact("token=secretvalue-extended").contains("secretvalue"))
        logger.forgetSecrets()
    }
}

await suite("Index signing") {
    await test("A signature verifies; a tampered index does not") {
        let pair = Signing.generateKeyPair()
        let payload = Data(#"{"revision":7,"plugins":[]}"#.utf8)
        let signature = try Signing.sign(payload, privateKeyBase64: pair.privateKeyBase64)

        expect(Signing.verify(payload, signature: signature, publicKeyBase64: pair.publicKeyBase64))
        expect(!Signing.verify(Data(#"{"revision":8,"plugins":[]}"#.utf8),
                               signature: signature, publicKeyBase64: pair.publicKeyBase64))
        expect(!Signing.verify(payload, signature: signature,
                               publicKeyBase64: Signing.generateKeyPair().publicKeyBase64))
    }
}

await runLocalizationSuites()
await runInterfaceCatalogueSuites()
await runPluginSuites()
await runIndexUpdaterSuites()
await runEngineSuites()
await runAPISuites()
await runAPITransportSuites()
await runVaultRecoverySuites()
await runEarliestDateSuites()
await runExportDestinationSuites()
await runSavedDestinationSuites()
await runSMTPSuites()
await runExportFailureSuites()
await runPerInvoiceMailSuites()
await runIncrementalSuites()
await runOutcomeSuites()
await runFrameSuites()
await runSignInSuites()
await runRecorderSuites()
await runStorageSuites()

report()
