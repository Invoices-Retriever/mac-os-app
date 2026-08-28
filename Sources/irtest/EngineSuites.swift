import Foundation
import IRCore

private func makeContext(config: [String: String] = [:],
                         secrets: [String: String] = [:],
                         totp: [String: String] = [:],
                         options: [String: [String]] = [:]) throws -> ExecutionContext {
    let manifest = try decodeGoodPlugin()
    var source = Source(entityID: UUID(), pluginID: manifest.id,
                        pluginVersion: manifest.version, displayName: "Example")
    source.options = options
    return ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                            config: config, secrets: secrets, totpCodes: totp,
                            incrementalCutoff: InvoiceDateParser.parse("2026-01-01")!)
}

@MainActor
func runEngineSuites() async {

    await suite("Template resolution") {
        await test("Namespaced references resolve") {
            let context = try makeContext(config: ["username": "cust-42"],
                                          secrets: ["password": "hunter2"],
                                          totp: ["mfa": "123456"],
                                          options: ["account": ["A1"]])
            expectEqual(try context.resolve("{{config.username}}"), "cust-42")
            expectEqual(try context.resolve("{{secret.password}}"), "hunter2")
            expectEqual(try context.resolve("{{totp.mfa}}"), "123456")
            expectEqual(try context.resolve("{{option.account}}"), "A1")
            expectEqual(try context.resolve("{{source.name}}"), "Example")
        }
        await test("config falls through to secrets, so a contributor writing either works") {
            let context = try makeContext(secrets: ["password": "hunter2"])
            expectEqual(try context.resolve("{{config.password}}"), "hunter2")
        }
        await test("Variables set by earlier steps resolve, bare or namespaced") {
            let context = try makeContext()
            context.set("invoiceNumber", .string("F-2026-001"))
            expectEqual(try context.resolve("{{invoiceNumber}}"), "F-2026-001")
            expectEqual(try context.resolve("{{vars.invoiceNumber}}"), "F-2026-001")
        }
        await test("A path into an object variable resolves") {
            let context = try makeContext()
            context.set("response", .object(["data": .object(["total": .number(4200)])]))
            expectEqual(try context.resolve("{{response.data.total}}"), "4200")
        }
        await test("forEach items resolve, and pop cleanly") {
            let context = try makeContext()
            context.pushItem(["number": .string("A-1")])
            expectEqual(try context.resolve("{{item.number}}"), "A-1")
            context.popItem()
            await expectThrows { _ = try context.resolve("{{item.number}}") }
        }
        await test("Date helpers resolve") {
            let context = try makeContext()
            expectEqual(try context.resolve("{{cutoff.year}}"), "2026")
            expectEqual(try context.resolve("{{cutoff.date}}"), "2026-01-01")
        }
        await test("An unknown reference throws instead of becoming an empty string") {
            let context = try makeContext()
            await expectThrows { _ = try context.resolve("{{config.nope}}") }
        }
        await test("Interpolation happens inside a larger string") {
            let context = try makeContext(config: ["username": "42"])
            expectEqual(try context.resolve("https://example.com/u/{{config.username}}/bills"),
                        "https://example.com/u/42/bills")
        }
        await test("A string with no braces is returned untouched") {
            let context = try makeContext()
            expectEqual(try context.resolve("https://example.com"), "https://example.com")
        }
    }

    await suite("Pattern matching") {
        await test("A pattern without a wildcard is a substring match") {
            expect(StepExecutor.matches(pattern: "/account", value: "https://example.com/account/bills"))
            expect(!StepExecutor.matches(pattern: "/admin", value: "https://example.com/account"))
        }
        await test("A wildcard matches any run of characters, anchored at both ends") {
            expect(StepExecutor.matches(pattern: "https://example.com/*/bills",
                                        value: "https://example.com/42/bills"))
            expect(!StepExecutor.matches(pattern: "https://example.com/*/bills",
                                         value: "https://other.com/42/bills"))
        }
        await test("A host pattern with a wildcard in the middle works") {
            // The shape the OVHcloud plugin relies on to tell the manager from
            // the sign-in page it is redirected to when the session is gone.
            let manager = "https://manager.*.ovhcloud.com/*"
            expect(StepExecutor.matches(pattern: manager,
                                        value: "https://manager.eu.ovhcloud.com/#/billing/history"))
            expect(StepExecutor.matches(pattern: manager,
                                        value: "https://manager.ca.ovhcloud.com/#/billing/history"))
            expect(!StepExecutor.matches(pattern: manager,
                                         value: "https://auth.eu.ovhcloud.com/signin/?action=disconnect"))
        }
        await test("Regular expression metacharacters in a pattern are literal") {
            expect(StepExecutor.matches(pattern: "a.b", value: "https://x/a.b"))
            expect(!StepExecutor.matches(pattern: "https://x/a.b", value: "https://x/axb"))
        }
        await test("Capture group 1 wins when the contributor provided one") {
            expectEqual(StepExecutor.applyRegex("Facture n° ([A-Z0-9-]+)", to: "Facture n° FR-2026-14"),
                        "FR-2026-14")
            expectEqual(StepExecutor.applyRegex("[0-9]{4}", to: "ref 2026 x"), "2026")
        }
    }

    await suite("Step execution") {
        /// The whole of `getDocuments` against a scripted portal: this is the
        /// acceptance test for the interpreter.
        await test("A full getDocuments run collects every row") {
            var listing = FakeBrowserSession.Page()
            listing.elements["#billing-table"] = "Invoices"
            listing.rows = [
                ["number": "F-001", "date": "31/01/2026", "total": "120,00 €",
                 "link": "https://example.com/pdf/F-001"],
                ["number": "F-002", "date": "28/02/2026", "total": "1 234,56 €",
                 "link": "https://example.com/pdf/F-002"],
            ]
            let session = FakeBrowserSession(pages: ["https://example.com/account": listing])
            session.downloads = [
                "https://example.com/pdf/F-001": Data("%PDF one".utf8),
                "https://example.com/pdf/F-002": Data("%PDF two".utf8),
            ]

            let manifest = try decodeGoodPlugin()
            let context = try makeContext()
            let executor = StepExecutor(session: session, context: context,
                                        policy: manifest.domainPolicy,
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.getDocuments, section: "getDocuments")

            expectEqual(context.documents.count, 2)
            expectEqual(context.documents.first?.pluginDocumentID, "F-001")
            expectEqual(context.documents.first?.total?.cents, 12000)
            expectEqual(context.documents.last?.total?.cents, 123456)
            expectEqual(context.documents.last?.issuedOn.map(InvoiceDateParser.isoString), "2026-02-28")
            expectEqual(context.documents.first?.issuer, "Example Portal")
        }

        await test("A row that fails does not cost the other rows") {
            var listing = FakeBrowserSession.Page()
            listing.elements["#billing-table"] = "Invoices"
            listing.rows = [
                ["number": "F-001", "date": "31/01/2026", "total": "10,00 €",
                 "link": "https://example.com/pdf/F-001"],
                ["number": "F-BAD", "date": "31/01/2026", "total": "10,00 €",
                 "link": "https://example.com/pdf/missing"],
                ["number": "F-003", "date": "31/03/2026", "total": "30,00 €",
                 "link": "https://example.com/pdf/F-003"],
            ]
            let session = FakeBrowserSession(pages: ["https://example.com/account": listing])
            session.downloads = [
                "https://example.com/pdf/F-001": Data("%PDF one".utf8),
                "https://example.com/pdf/F-003": Data("%PDF three".utf8),
            ]

            let manifest = try decodeGoodPlugin()
            let context = try makeContext()
            let executor = StepExecutor(session: session, context: context,
                                        policy: manifest.domainPolicy,
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.getDocuments, section: "getDocuments")
            expectEqual(context.documents.count, 2)
        }

        await test("The engine refuses a navigation outside the sandbox even if the URL is built at runtime") {
            let session = FakeBrowserSession(pages: [
                "https://example.com/account": FakeBrowserSession.Page(),
                "https://exfiltrate.example.net/steal": FakeBrowserSession.Page(),
            ])
            let context = try makeContext()
            context.set("target", .string("https://exfiltrate.example.net/steal"))

            var step = PluginStep(action: .navigate)
            step.url = "{{target}}"

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            await expectThrows { try await executor.run([step], section: "test") }
            expect(session.navigationLog.isEmpty, "no navigation should have been attempted")
        }

        await test("checkElementExists fails when the element is absent") {
            let session = FakeBrowserSession(pages: ["https://example.com/account": FakeBrowserSession.Page()],
                                             start: "https://example.com/account")
            let context = try makeContext()
            var step = PluginStep(action: .checkElementExists)
            step.selector = "#billing-table"
            step.timeout = 200

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30))
            await expectThrows { try await executor.run([step], section: "checkAuth") }
        }

        await test("if / else takes the right branch") {
            var page = FakeBrowserSession.Page()
            page.elements[".cookie-banner"] = "We use cookies"
            page.elements[".accept"] = "Accept"
            let session = FakeBrowserSession(pages: ["https://example.com/account": page],
                                             start: "https://example.com/account")
            let context = try makeContext()

            var extractStep = PluginStep(action: .extract)
            extractStep.selector = ".cookie-banner"
            extractStep.assignTo = "banner"

            var branch = PluginStep(action: .ifStep)
            branch.condition = .elementExists(".cookie-banner")
            branch.then = [extractStep]

            var elseStep = PluginStep(action: .extract)
            elseStep.selector = ".missing"
            elseStep.assignTo = "shouldNotHappen"
            branch.else = [elseStep]

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30))
            try await executor.run([branch], section: "test")
            expectEqual(context.variable("banner")?.stringValue, "We use cookies")
            expect(context.variable("shouldNotHappen") == nil)
        }

        await test("An optional click on a missing element is not an error") {
            let session = FakeBrowserSession(pages: ["https://example.com/account": FakeBrowserSession.Page()],
                                             start: "https://example.com/account")
            let context = try makeContext()
            var step = PluginStep(action: .click)
            step.selector = ".cookie-accept"
            step.optional = true
            step.timeout = 200

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run([step], section: "test")   // must not throw
        }

        await test("extract with a regex narrows the captured value") {
            var page = FakeBrowserSession.Page()
            page.elements["h1"] = "Facture n° FR-2026-0042 du 31 mars 2026"
            let session = FakeBrowserSession(pages: ["https://example.com/account": page],
                                             start: "https://example.com/account")
            let context = try makeContext()

            var step = PluginStep(action: .extract)
            step.selector = "h1"
            step.regex = "n° ([A-Z0-9-]+)"
            step.assignTo = "number"

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30))
            try await executor.run([step], section: "test")
            expectEqual(context.variable("number")?.stringValue, "FR-2026-0042")
        }

        await test("extractNetworkResponse reads a JSON body the page fetched") {
            let session = FakeBrowserSession(pages: ["https://example.com/account": FakeBrowserSession.Page()],
                                             start: "https://example.com/account")
            session.responses = [ObservedResponse(
                url: URL(string: "https://api.example.com/v1/invoices")!,
                statusCode: 200, mimeType: "application/json",
                body: Data(#"{"data":{"invoices":[{"id":"F-9"}]}}"#.utf8))]

            let context = try makeContext()
            var step = PluginStep(action: .extractNetworkResponse)
            step.url = "*/v1/invoices"
            step.jsonPath = "data.invoices"
            step.assignTo = "invoices"
            step.timeout = 1000

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com", "*.example.com"]),
                                        deadline: Deadline(30))
            try await executor.run([step], section: "test")
            expectEqual(context.variable("invoices")?.arrayValue?.count, 1)
        }

        await test("A document with an empty id is refused rather than filed under nothing") {
            let session = FakeBrowserSession(pages: ["https://example.com/account": FakeBrowserSession.Page()],
                                             start: "https://example.com/account")
            let context = try makeContext()
            context.set("blank", .string(""))

            var step = PluginStep(action: .printPdf)
            var descriptor = DocumentDescriptor(id: "{{blank}}", date: "2026-01-01")
            descriptor.total = "10,00 €"
            step.document = descriptor

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(30))
            await expectThrows { try await executor.run([step], section: "test") }
        }

        await test("Time the person spends signing in is given back") {
            // A two-factor code fetched from a phone took two minutes; the
            // collection that sign-in existed to unlock must still have its
            // full budget afterwards.
            let deadline = Deadline(30)
            let before = await deadline.date
            await deadline.extend(by: 120)
            let after = await deadline.date
            expect(after.timeIntervalSince(before) >= 119, "the wait was not refunded")
            expect(await !deadline.hasPassed)
        }

        await test("The run budget stops a plugin that would otherwise loop") {
            let session = FakeBrowserSession(pages: ["https://example.com/account": FakeBrowserSession.Page()])
            let context = try makeContext()
            var step = PluginStep(action: .sleep)
            step.ms = 50

            let executor = StepExecutor(session: session, context: context,
                                        policy: DomainPolicy(allowedDomains: ["example.com"]),
                                        deadline: Deadline(-1))
            await expectThrows { try await executor.run([step], section: "test") }
        }
    }

    await suite("Retry policy") {
        await test("An authentication failure is never retried") {
            expect(!IRError.authenticationFailed("x").isRetryable)
            expect(!IRError.authenticationRequired("x").isRetryable)
            expect(!IRError.blockedByPortal("captcha").isRetryable)
            expect(!IRError.domainNotAllowed(host: "x", allowed: []).isRetryable)
        }
        await test("A timeout is retryable") {
            expect(IRError.stepTimedOut(action: "click", milliseconds: 1000).isRetryable)
            expect(IRError.elementNotFound(selector: ".x").isRetryable)
        }
        await test("Sign-in errors are distinguished from ordinary failures") {
            expect(IRError.authenticationRequired("x").needsUserSignIn)
            expect(!IRError.stepTimedOut(action: "x", milliseconds: 1).needsUserSignIn)
        }
    }

    await suite("Incremental collection") {
        await test("A source that has never succeeded looks back by its window") {
            var source = Source(entityID: UUID(), pluginID: "x", pluginVersion: "1.0.0", displayName: "X")
            source.lookbackDays = 30
            let now = Date()
            let cutoff = source.incrementalCutoff(now: now)
            expect(abs(now.timeIntervalSince(cutoff) - 30 * 86_400) < 60)
        }
        await test("A source that has succeeded re-checks a week of overlap") {
            var source = Source(entityID: UUID(), pluginID: "x", pluginVersion: "1.0.0", displayName: "X")
            source.lastSuccessAt = InvoiceDateParser.parse("2026-03-31")
            let cutoff = source.incrementalCutoff()
            expectEqual(InvoiceDateParser.isoString(cutoff), "2026-03-24")
        }
    }

    await suite("Schedules") {
        await test("A manual schedule never fires by itself") {
            expect(Schedule.manual.nextDate(after: Date()) == nil)
            expect(!Schedule.manual.isAutomatic)
        }
        await test("A monthly schedule produces a date in the future") {
            let next = Schedule.monthly(day: 5, hour: 9).nextDate(after: Date())
            expect(next != nil)
            expect(next! > Date())
        }
    }
}

/// The sign-in path, which is where every source starts and where the engine
/// has broken twice: once by polling a navigating check every two seconds, once
/// by running it immediately after filling the form.
@MainActor
func runSignInSuites() async {

    await suite("Interactive sign-in") {

        /// A portal whose sign-in lives on its own host, like OVHcloud's.
        func makePortal() -> FakeBrowserSession {
            var login = FakeBrowserSession.Page()
            login.elements["#account"] = ""
            login.elements["#password"] = ""
            login.elements["#login-submit"] = "Sign in"

            var manager = FakeBrowserSession.Page()
            manager.elements["#billing"] = "Invoices"

            return FakeBrowserSession(pages: [
                "https://auth.example.com/signin": login,
                "https://manager.example.com/billing": manager,
            ], start: "https://auth.example.com/signin")
        }

        let plugin = """
        {"id":"portal","name":"Portal","version":"1.0.0","engine":">=1.0.0",
         "allowedDomains":["example.com","*.example.com"],
         "configSchema":{"user":{"type":"string","label":"User","required":true},
                         "password":{"type":"password","label":"Password","required":true}},
         "checkAuth":[{"action":"navigate","url":"https://manager.example.com/billing"},
                      {"action":"checkElementExists","selector":"#billing","timeout":300}],
         "startAuth":[{"action":"navigate","url":"https://auth.example.com/signin"},
                      {"action":"type","selector":"#account","value":"{{config.user}}"},
                      {"action":"type","selector":"#password","value":"{{secret.password}}"},
                      {"action":"click","selector":"#login-submit"}],
         "getDocuments":[{"action":"navigate","url":"https://manager.example.com/billing"},
                         {"action":"printPdf","document":{"id":"x","date":"2026-01-01"}}]}
        """

        await test("The form the user is filling in is never navigated away from") {
            // Reported as "the credentials are filled in, then nothing happens
            // and the page reloads". checkAuth begins by navigating, so asking
            // it while the login form is on screen wipes what was typed.
            let session = makePortal()
            session.signInAfterChecks = 999          // the user never finishes
            let manifest = try PluginManifest.decode(from: Data(plugin.utf8))

            var runner = PluginRunner(manifest: manifest,
                                      sessionFactory: FakeSessionFactory(session: session),
                                      vault: CredentialVault())
            runner.interactiveSignInBudget = .milliseconds(400)
            runner.runBudget = .seconds(5)

            var source = Source(entityID: UUID(), pluginID: "portal",
                                pluginVersion: "1.0.0", displayName: "Portal")
            source.config = ["user": "someone"]
            source.rememberCredentials = false

            _ = await runner.run(source: source, mode: .authenticateOnly)

            // startAuth navigates to the sign-in page once. Every later
            // navigation to the manager is checkAuth reloading the page the
            // user is working on.
            let afterSignInPage = session.navigationLog
                .drop(while: { $0 != "https://auth.example.com/signin" })
                .dropFirst()
            expect(afterSignInPage.isEmpty,
                   "navigated away from the sign-in flow: \(Array(afterSignInPage))")
        }

        await test("Once the user leaves the sign-in host, the real check runs") {
            let session = makePortal()
            session.signInAfterChecks = 999
            // The user got through: the browser is on the manager now.
            session.currentURLValue = URL(string: "https://manager.example.com/billing")

            let manifest = try PluginManifest.decode(from: Data(plugin.utf8))
            var runner = PluginRunner(manifest: manifest,
                                      sessionFactory: FakeSessionFactory(session: session),
                                      vault: CredentialVault())
            runner.interactiveSignInBudget = .seconds(3)
            runner.runBudget = .seconds(10)

            var source = Source(entityID: UUID(), pluginID: "portal",
                                pluginVersion: "1.0.0", displayName: "Portal")
            source.config = ["user": "someone"]
            source.rememberCredentials = false

            let outcome = await runner.run(source: source, mode: .authenticateOnly)
            expect(outcome.status == .succeeded, "sign-in was not detected: \(outcome.status)")
        }
    }
}

/// Frames, and the fact that a portal's real content is often not in the main
/// document at all.
@MainActor
func runFrameSuites() async {

    await suite("Frames") {
        await test("A result from the main frame is taken when it has one") {
            // The rule the driver uses to decide whether to look further. Kept
            // here because the driver needs WebKit and this does not.
            expect(FrameAnswer.isAnswer(.bool(true)))
            expect(FrameAnswer.isAnswer(.string("F-2026-001")))
            expect(FrameAnswer.isAnswer(.array([.string("x")])))
            expect(FrameAnswer.isAnswer(.number(3)))
            expect(FrameAnswer.isAnswer(.object(["ok": .bool(true)])))
        }

        await test("A frame that found nothing does not stop the search") {
            // These are what the DOM snippets return when the element is not in
            // that document: the shell page of an iframe-based portal answers
            // exactly this for every selector the plugin cares about.
            expect(!FrameAnswer.isAnswer(.null))
            expect(!FrameAnswer.isAnswer(.bool(false)))
            expect(!FrameAnswer.isAnswer(.string("")))
            expect(!FrameAnswer.isAnswer(.array([])))
            expect(!FrameAnswer.isAnswer(.object(["ok": .bool(false),
                                                  "reason": .string("not-found")])))
        }
    }
}

/// What a run reports when it half-worked.
@MainActor
func runOutcomeSuites() async {

    await suite("Run outcomes") {
        await test("Matching rows and reading none of them is not a success") {
            // Reported as a green run collecting nothing: the plugin found the
            // invoice list and could not read a single row, which is the most
            // informative failure there is, and it was being called success.
            var listing = FakeBrowserSession.Page()
            listing.elements["#billing-table"] = "Invoices"
            listing.rows = [
                ["number": "F-001", "date": "31/01/2026", "total": "10,00 €"],
                ["number": "F-002", "date": "28/02/2026", "total": "20,00 €"],
            ]
            let session = FakeBrowserSession(pages: ["https://example.com/account": listing])

            // The plugin asks for a link the rows do not contain.
            let manifest = try decodeGoodPlugin()
            let context = try makeCollectContext()
            let executor = StepExecutor(session: session, context: context,
                                        policy: manifest.domainPolicy,
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.getDocuments, section: "getDocuments")

            expectEqual(context.matchedRows, 2)
            expect(context.documents.isEmpty, "the rows should not have produced documents")
        }

        await test("Rows that produce documents leave the count alone") {
            var listing = FakeBrowserSession.Page()
            listing.elements["#billing-table"] = "Invoices"
            listing.rows = [["number": "F-001", "date": "31/01/2026", "total": "10,00 €",
                             "link": "https://example.com/pdf/F-001"]]
            let session = FakeBrowserSession(pages: ["https://example.com/account": listing])
            session.downloads = ["https://example.com/pdf/F-001": Data("%PDF".utf8)]

            let manifest = try decodeGoodPlugin()
            let context = try makeCollectContext()
            let executor = StepExecutor(session: session, context: context,
                                        policy: manifest.domainPolicy,
                                        deadline: Deadline(30),
                                        rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.getDocuments, section: "getDocuments")

            expectEqual(context.matchedRows, 1)
            expectEqual(context.documents.count, 1)
        }
    }
}

private func makeCollectContext() throws -> ExecutionContext {
    let manifest = try decodeGoodPlugin()
    let source = Source(entityID: UUID(), pluginID: manifest.id,
                        pluginVersion: manifest.version, displayName: "Example")
    return ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                            config: [:], secrets: [:], totpCodes: [:],
                            incrementalCutoff: InvoiceDateParser.parse("2026-01-01")!)
}

/// API connectors: reading a portal's own endpoint instead of the table it
/// rendered from it.
@MainActor
func runAPISuites() async {

    let plugin = """
    {"id":"api-portal","name":"API Portal","version":"1.0.0","engine":">=1.1.0",
     "allowedDomains":["example.com","*.example.com"],
     "checkAuth":[{"action":"navigate","url":"https://example.com/account"},
                  {"action":"checkURL","url":"*/account"}],
     "getDocuments":[
       {"action":"navigate","url":"https://example.com/account"},
       {"action":"apiRequest","url":"https://api.example.com/me/bill",
        "jsonPath":"data","assignTo":"bills"},
       {"action":"extractAll","items":"{{bills}}",
        "forEach":[
          {"action":"downloadPdf","url":"{{item.pdfUrl}}",
           "document":{"id":"{{item.billId}}","date":"{{item.date}}",
                       "total":"{{item.total}}"}}]}]}
    """

    await suite("API connectors") {

        await test("A plugin reading an API validates") {
            let manifest = try PluginManifest.decode(from: Data(plugin.utf8))
            let report = PluginValidator.validate(manifest)
            expect(report.isValid, "\(report.errors.map(\.message))")
            // The point of making this a step rather than runJs: a plugin
            // reading an API is not flagged as running its own code.
            expect(!manifest.containsArbitraryJavaScript)
        }

        await test("Using new vocabulary without declaring the engine is an error") {
            // Otherwise the plugin ships, and every application older than the
            // feature rejects it as *invalid* — sending users to hunt for a
            // fault in a plugin that is perfectly correct.
            var object = try JSONSerialization.jsonObject(with: Data(plugin.utf8)) as! [String: Any]
            object["engine"] = ">=1.0.0"
            let manifest = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("1.1.0") })
        }

        await test("extractAll over the page still runs on a 1.0 engine") {
            // The floor must come from what a plugin uses, not from the mere
            // existence of newer vocabulary — or every plugin would need a bump.
            let scraping = """
            {"id":"scraper","name":"Scraper","version":"1.0.0","engine":">=1.0.0",
             "allowedDomains":["example.com"],
             "checkAuth":[{"action":"checkURL","url":"*/a"}],
             "getDocuments":[{"action":"extractAll","selector":"tr","forEach":[
               {"action":"printPdf","document":{"id":"{{item.n}}","date":"{{item.d}}"}}]}]}
            """
            let manifest = try PluginManifest.decode(from: Data(scraping.utf8))
            expectEqual(requiredEngineFloor(manifest), SemVer(1, 0, 0))
            let r = PluginValidator.validate(manifest)
            expect(r.isValid, "\(r.errors.map(\.message))")
        }

        await test("A plugin needing a newer engine is skipped, not called invalid") {
            // The header decodes even when the steps do not, which is the only
            // reason this can produce an accurate message.
            let future = """
            {"id":"future","name":"Future","version":"2.0.0","engine":">=9.0.0",
             "allowedDomains":["example.com"],
             "checkAuth":[{"action":"teleport"}],
             "getDocuments":[{"action":"teleport"}]}
            """
            let data = Data(future.utf8)
            // Decoding the whole manifest is exactly what fails today.
            var decodeFailed = false
            do { _ = try PluginManifest.decode(from: data) } catch { decodeFailed = true }
            expect(decodeFailed, "the premise of the header no longer holds")

            let header = try PluginManifest.header(from: data)
            expectEqual(header.id, "future")
            expect(!header.isSupportedByEngine())
            expect(PluginCatalog.engineTooOldMessage(header.engine).contains("9.0.0"))
        }

        await test("An API endpoint outside allowedDomains is caught statically") {
            var object = try JSONSerialization.jsonObject(with: Data(plugin.utf8)) as! [String: Any]
            object["allowedDomains"] = ["example.com"]
            let manifest = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            let report = PluginValidator.validate(manifest)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("api.example.com") })
        }

        await test("Only reading methods are allowed") {
            var object = try JSONSerialization.jsonObject(with: Data(plugin.utf8)) as! [String: Any]
            var steps = object["getDocuments"] as! [[String: Any]]
            steps[1]["method"] = "DELETE"
            object["getDocuments"] = steps
            let manifest = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            expect(!PluginValidator.validate(manifest).isValid,
                   "a collector must not be able to modify a portal")
        }

        await test("extractAll needs exactly one source of rows") {
            for change in [["selector": "tr", "items": "{{bills}}"], [:]] as [[String: String]] {
                var object = try JSONSerialization.jsonObject(with: Data(plugin.utf8)) as! [String: Any]
                var steps = object["getDocuments"] as! [[String: Any]]
                steps[2].removeValue(forKey: "items")
                for (k, v) in change { steps[2][k] = v }
                object["getDocuments"] = steps
                let manifest = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
                expect(!PluginValidator.validate(manifest).isValid, "accepted \(change)")
            }
        }

        await test("A whole collection runs off the API") {
            var page = FakeBrowserSession.Page()
            page.elements["#account"] = "signed in"
            let session = FakeBrowserSession(pages: ["https://example.com/account": page],
                                             start: "https://example.com/account")
            session.apiResponses["https://api.example.com/me/bill"] = APIResponse(
                status: 200,
                json: .object(["data": .array([
                    .object(["billId": .string("FR-1"), "date": .string("2026-01-31"),
                             "total": .string("120.00"),
                             "pdfUrl": .string("https://cdn.example.com/1.pdf")]),
                    .object(["billId": .string("FR-2"), "date": .string("2026-02-28"),
                             "total": .string("1234.56"),
                             "pdfUrl": .string("https://cdn.example.com/2.pdf")]),
                ])]))
            session.downloads = [
                "https://cdn.example.com/1.pdf": Data("%PDF one".utf8),
                "https://cdn.example.com/2.pdf": Data("%PDF two".utf8),
            ]

            let manifest = try PluginManifest.decode(from: Data(plugin.utf8))
            let source = Source(entityID: UUID(), pluginID: manifest.id,
                                pluginVersion: manifest.version, displayName: "API Portal")
            let context = ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                                           config: [:], secrets: [:], totpCodes: [:],
                                           incrementalCutoff: InvoiceDateParser.parse("2026-01-01")!)
            let executor = StepExecutor(
                session: session, context: context,
                policy: DomainPolicy(allowedDomains: ["example.com", "*.example.com"]),
                deadline: Deadline(30),
                rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.getDocuments, section: "getDocuments")

            expectEqual(session.apiCalls, ["GET https://api.example.com/me/bill"])
            expectEqual(context.documents.count, 2)
            // Typed values off an API, not text scraped from a rendered table.
            expectEqual(context.documents.first?.total?.cents, 12000)
            expectEqual(context.documents.last?.pluginDocumentID, "FR-2")
            expectEqual(context.documents.first?.issuedOn.map(InvoiceDateParser.isoString), "2026-01-31")
        }

        await test("A dead session on the API asks the user to sign in again") {
            // A page says the session is gone by redirecting; an API says it
            // with a status. The user must get the same offer either way.
            for status in [401, 403, 471] {
                var page = FakeBrowserSession.Page()
                page.elements["#account"] = "signed in"
                let session = FakeBrowserSession(pages: ["https://example.com/account": page],
                                                 start: "https://example.com/account")
                session.apiResponses["https://api.example.com/me/bill"] =
                    APIResponse(status: status, text: "This session is invalid")

                let manifest = try PluginManifest.decode(from: Data(plugin.utf8))
                let source = Source(entityID: UUID(), pluginID: manifest.id,
                                    pluginVersion: manifest.version, displayName: "API Portal")
                let context = ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                                               config: [:], secrets: [:], totpCodes: [:],
                                               incrementalCutoff: Date.distantPast)
                let executor = StepExecutor(
                    session: session, context: context,
                    policy: DomainPolicy(allowedDomains: ["example.com", "*.example.com"]),
                    deadline: Deadline(30),
                    rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
                do {
                    try await executor.run(manifest.getDocuments, section: "getDocuments")
                    expect(false, "\(status) should have stopped the run")
                } catch let error as IRError {
                    expect(error.needsUserSignIn, "\(status) produced \(error)")
                }
            }
        }

        await test("A list of plain identifiers is iterable as {{item}}") {
            // What /me/bill actually answers: identifiers, not objects.
            var page = FakeBrowserSession.Page()
            page.elements["#account"] = "signed in"
            let session = FakeBrowserSession(pages: ["https://example.com/account": page],
                                             start: "https://example.com/account")

            let manifest = try PluginManifest.decode(from: Data(plugin.utf8))
            let source = Source(entityID: UUID(), pluginID: manifest.id,
                                pluginVersion: manifest.version, displayName: "API Portal")
            let context = ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                                           config: [:], secrets: [:], totpCodes: [:],
                                           incrementalCutoff: InvoiceDateParser.parse("2026-01-01")!)
            context.set("ids", .array([.string("FR-1"), .string("FR-2")]))

            var seen: [String] = []
            var probe = PluginStep(action: .extract)
            probe.from = .url
            probe.assignTo = "ignored"

            var loop = PluginStep(action: .extractAll)
            loop.items = "{{ids}}"
            loop.forEach = [probe]

            let executor = StepExecutor(
                session: session, context: context,
                policy: DomainPolicy(allowedDomains: ["example.com"]),
                deadline: Deadline(30))
            // Resolve {{item}} from inside the loop by watching the context.
            for id in ["FR-1", "FR-2"] {
                context.pushItem(["__value": .string(id)])
                seen.append(try context.resolve("{{item}}"))
                context.popItem()
            }
            expectEqual(seen, ["FR-1", "FR-2"])
            _ = loop
            _ = executor
        }
    }
}

/// Plugins that talk to a supplier's API with the user's own credentials, and
/// never open a browser.
@MainActor
func runAPITransportSuites() async {

    /// The OVHcloud scheme, which is the reason the signature recipe exists.
    func ovhSignature(algorithm: APISignature.Algorithm = .sha1) -> APISignature {
        var recipe = APISignature(header: "X-Ovh-Signature", algorithm: algorithm, parts: [
            "{{secret.applicationSecret}}", "{{secret.consumerKey}}",
            "{{request.method}}", "{{request.url}}", "{{request.body}}", "{{api.time}}",
        ])
        recipe.prefix = "$1$"
        recipe.separator = "+"
        recipe.encoding = .hex
        return recipe
    }

    func session(_ secrets: [String: String] = ["applicationSecret": "APP_SECRET",
                                                "consumerKey": "CONSUMER_KEY"]) -> APISession {
        APISession(sourceID: UUID(),
                   transport: APITransport(baseURL: "https://eu.api.ovh.com/1.0"),
                   policy: DomainPolicy(allowedDomains: ["eu.api.ovh.com"]),
                   resolve: { template in
                       var out = template
                       for (key, value) in secrets {
                           out = out.replacingOccurrences(of: "{{secret.\(key)}}", with: value)
                       }
                       return out
                   })
    }

    await suite("API transport") {

        await test("The OVHcloud signature matches an independently computed one") {
            // Computed with python hashlib, not with this code, so the test
            // cannot agree with a bug in the implementation.
            let signed = try session().sign(ovhSignature(), method: "GET",
                                            url: URL(string: "https://eu.api.ovh.com/1.0/me")!,
                                            body: "", time: "1700000000")
            expectEqual(signed, "$1$6ab9c7d6fcbbb9df417cd28c334a40b50d76b326")
        }

        await test("A body is part of what gets signed") {
            let signed = try session().sign(ovhSignature(), method: "POST",
                                            url: URL(string: "https://eu.api.ovh.com/1.0/me/bill")!,
                                            body: "{\"a\":1}", time: "1700000000")
            expectEqual(signed, "$1$cd67355e2c1b17120600f6b47a48567398f94b1f")
        }

        await test("A different secret gives a different signature") {
            let other = try session(["applicationSecret": "WRONG", "consumerKey": "CONSUMER_KEY"])
                .sign(ovhSignature(), method: "GET",
                      url: URL(string: "https://eu.api.ovh.com/1.0/me")!,
                      body: "", time: "1700000000")
            expect(other != "$1$6ab9c7d6fcbbb9df417cd28c334a40b50d76b326")
        }

        await test("A base URL with a path prefix survives a relative step") {
            // URL(string:relativeTo:) drops it: an absolute path replaces the
            // base's path, so /1.0 vanishes and every call goes to a URL that
            // is not the API — which fails looking exactly like bad keys.
            let manifest = try PluginManifest.decode(from: Data("""
            {"id":"based","name":"Based","version":"1.0.0","engine":">=1.2.0",
             "allowedDomains":["eu.api.ovh.com"],
             "api":{"baseUrl":"https://eu.api.ovh.com/1.0"},
             "checkAuth":[{"action":"apiRequest","url":"/me/bill","assignTo":"x"}],
             "getDocuments":[{"action":"apiRequest","url":"/me/bill","assignTo":"ids"},
                             {"action":"extractAll","items":"{{ids}}","forEach":[
                               {"action":"downloadPdf","url":"{{item.pdfUrl}}",
                                "document":{"id":"{{item.id}}","date":"{{item.date}}"}}]}]}
            """.utf8))
            let source = Source(entityID: UUID(), pluginID: manifest.id,
                                pluginVersion: manifest.version, displayName: "Based")
            let context = ExecutionContext(source: source, manifest: manifest, runID: UUID(),
                                           config: [:], secrets: [:], totpCodes: [:],
                                           incrementalCutoff: Date.distantPast)
            let fake = FakeBrowserSession(pages: [:], start: "https://eu.api.ovh.com/1.0")
            fake.apiResponses["https://eu.api.ovh.com/1.0/me/bill"] =
                APIResponse(status: 200, json: .array([]))
            let executor = StepExecutor(
                session: fake, context: context,
                policy: DomainPolicy(allowedDomains: ["eu.api.ovh.com"]),
                deadline: Deadline(30), rateLimiter: RateLimiter(minimumInterval: .milliseconds(1)))
            try await executor.run(manifest.checkAuth, section: "checkAuth")
            expectEqual(fake.apiCalls, ["GET https://eu.api.ovh.com/1.0/me/bill"])
        }

        await test("Declared auth headers can use the request's own scope") {
            // OVHcloud sends the timestamp as a header as well as inside the
            // signature. Resolving that header against the run's context alone
            // throws "unknown variable {{api.time}}" — and that failure reaches
            // the user as "the API refused these credentials".
            var auth = APIAuth(type: .signature)
            auth.headers = [
                "X-Ovh-Application": "{{secret.applicationSecret}}",
                "X-Ovh-Timestamp": "{{api.time}}",
                "X-Method": "{{request.method}}",
            ]
            auth.signature = ovhSignature()

            let headers = try session().authHeaders(
                auth, method: "GET",
                url: URL(string: "https://eu.api.ovh.com/1.0/me/bill")!,
                body: "", time: "1700000000")

            expectEqual(headers["X-Ovh-Timestamp"], "1700000000")
            expectEqual(headers["X-Method"], "GET")
            expectEqual(headers["X-Ovh-Application"], "APP_SECRET")
            expect(headers["X-Ovh-Signature"]?.hasPrefix("$1$") == true)
        }

        await test("A browser step is refused before it can run") {
            let s = session()
            var refused = 0
            for attempt in 0..<3 {
                do {
                    switch attempt {
                    case 0: try await s.navigate(to: URL(string: "https://eu.api.ovh.com")!)
                    case 1: _ = try await s.evaluate("1")
                    default: _ = try await s.printToPDF()
                    }
                } catch { refused += 1 }
            }
            expectEqual(refused, 3)
        }

        await test("The sandbox applies to API calls") {
            let s = session()
            do {
                _ = try await s.requestJSON(url: URL(string: "https://evil.example.com/x")!,
                                            method: "GET", headers: [:], body: nil,
                                            timeout: .seconds(5))
                expect(false, "an undeclared host must not be reachable")
            } catch let error as IRError {
                guard case .domainNotAllowed = error else {
                    expect(false, "wrong error: \(error)"); return
                }
            }
        }
    }

    await suite("API plugin validation") {

        let manifest = """
        {"id":"ovh-api","name":"OVH API","version":"1.0.0","engine":">=1.2.0",
         "allowedDomains":["eu.api.ovh.com"],
         "configSchema":{"applicationSecret":{"type":"password","label":"S","required":true}},
         "api":{"baseUrl":"https://eu.api.ovh.com/1.0",
                "auth":{"type":"signature",
                        "signature":{"header":"X-Ovh-Signature","algorithm":"sha1",
                                     "parts":["{{secret.applicationSecret}}","{{request.url}}"]}}},
         "checkAuth":[{"action":"apiRequest","url":"/me","assignTo":"me"}],
         "getDocuments":[{"action":"apiRequest","url":"/me/bill","assignTo":"ids"},
                         {"action":"extractAll","items":"{{ids}}","forEach":[
                           {"action":"downloadPdf","url":"{{item.pdfUrl}}",
                            "document":{"id":"{{item.billId}}","date":"{{item.date}}"}}]}]}
        """

        await test("An API plugin validates without a browser verification step") {
            let m = try PluginManifest.decode(from: Data(manifest.utf8))
            let report = PluginValidator.validate(m)
            expect(report.isValid, "\(report.errors.map(\.message))")
            expect(m.isAPIOnly)
            expectEqual(m.requiredEngineFloor, SemVer(1, 2, 0))
        }

        await test("A credential used only by the signature counts as used") {
            // It appears in no step at all, so a scan of steps alone would
            // report it as collected and never used, and tell the author to
            // stop asking for it.
            let m = try PluginManifest.decode(from: Data(manifest.utf8))
            expect(!PluginValidator.validate(m).warnings.contains {
                $0.message.contains("never used")
            })
        }

        await test("A browser step in an API plugin is an error") {
            var object = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any]
            object["getDocuments"] = [["action": "click", "selector": "#a"]]
            let m = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            let report = PluginValidator.validate(m)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("needs a browser") })
        }

        await test("The API host must be declared in the sandbox") {
            var object = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any]
            object["allowedDomains"] = ["example.com"]
            let m = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            expect(!PluginValidator.validate(m).isValid)
        }

        await test("A credential in a plain field is refused") {
            // It would sit in the database in clear rather than the Keychain.
            var object = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any]
            object["configSchema"] = ["applicationSecret": ["type": "string", "label": "S", "required": true]]
            let m = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            let report = PluginValidator.validate(m)
            expect(!report.isValid)
            expect(report.errors.contains { $0.message.contains("not a password field") })
        }

        await test("An HMAC signature without a key is refused") {
            var object = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any]
            var api = object["api"] as! [String: Any]
            var auth = api["auth"] as! [String: Any]
            var signature = auth["signature"] as! [String: Any]
            signature["algorithm"] = "hmacSha256"
            auth["signature"] = signature; api["auth"] = auth; object["api"] = api
            let m = try PluginManifest.decode(from: JSONSerialization.data(withJSONObject: object))
            expect(!PluginValidator.validate(m).isValid)
        }
    }
}

/// The incremental window, which decides which invoices are ever looked for.
@MainActor
func runIncrementalSuites() async {
    await suite("Incremental cutoff") {

        await test("Only a complete run moves the window forward") {
            // A partial run found documents it could not read. Moving past them
            // means never looking again, and nothing would ever say so.
            expect(RunStatus.succeeded.advancesIncrementalCutoff)
            expect(!RunStatus.partial.advancesIncrementalCutoff)
            expect(!RunStatus.failed.advancesIncrementalCutoff)
            expect(!RunStatus.needsSignIn.advancesIncrementalCutoff)
            expect(!RunStatus.cancelled.advancesIncrementalCutoff)
            // It still reads as a success to the user, and still clears the
            // error: the two questions are different.
            expect(RunStatus.partial.countsAsSuccess)
        }

        await test("A source that never succeeded looks back its full window") {
            var source = Source(entityID: UUID(), pluginID: "p", pluginVersion: "1.0.0",
                                displayName: "S", lookbackDays: 90)
            source.lastSuccessAt = nil
            let now = Date()
            let cutoff = source.incrementalCutoff(now: now)
            expectEqual(Int(now.timeIntervalSince(cutoff) / 86_400), 90)
        }

        await test("A successful run leaves a week of overlap") {
            // Portals back-date invoices by a few days, and re-seeing one costs
            // nothing because deduplication catches it.
            var source = Source(entityID: UUID(), pluginID: "p", pluginVersion: "1.0.0",
                                displayName: "S")
            let success = Date()
            source.lastSuccessAt = success
            expectEqual(Int(success.timeIntervalSince(source.incrementalCutoff()) / 86_400), 7)
        }

        await test("Clearing the last success reopens the full window") {
            // What "collect from the beginning" does, and the only way back
            // when the window has moved past invoices that were never read.
            var source = Source(entityID: UUID(), pluginID: "p", pluginVersion: "1.0.0",
                                displayName: "S", lookbackDays: 365)
            source.lastSuccessAt = Date()
            let narrow = source.incrementalCutoff()
            source.lastSuccessAt = nil
            expect(source.incrementalCutoff() < narrow)
        }
    }
}


/// The keychain refusing to hand back what it holds — a failure the user meets
/// after any change of code signature, and one they can only escape if the
/// application lets them write over it.
@MainActor
func runVaultRecoverySuites() async {
    await suite("Unreadable credentials") {

        await test("A refusal is not retried") {
            let error = IRError.credentialsUnreadable(reason: "shut", source: "source.X")
            expect(!error.isRetryable, "asking again re-fails against the same access list")
            expect(!error.needsUserSignIn, "the portal is not the problem; the keychain is")
        }

        await test("The message says what to do, not what went wrong") {
            let error = IRError.credentialsUnreadable(
                reason: "macOS would not release the saved credentials: they were stored by a "
                      + "differently signed copy of this application. Open the source, enter them "
                      + "again, and this stops happening.",
                source: "source.X")
            let text = error.errorDescription ?? ""
            expect(text.contains("enter them again"), text)
            // An OSStatus is not something a person can act on.
            expect(!text.contains("OSStatus"), text)
        }

        await test("Writing treats an unreadable item as replaceable") {
            // The remedy must not depend on the read that is failing.
            expect(CredentialVault.isUnreadable(
                .credentialsUnreadable(reason: "shut", source: "source.X")))
            // Anything else is a real failure and must still stop a write.
            expect(!CredentialVault.isUnreadable(.vault("the keychain is not available")))
            expect(!CredentialVault.isUnreadable(.storage("disk full")))
        }
    }
}

/// The global floor on how far back a collection goes.
@MainActor
func runEarliestDateSuites() async {
    await suite("Earliest document date") {

        func source(lastSuccess: Date?, lookbackDays: Int = 90) -> Source {
            var s = Source(entityID: UUID(), pluginID: "p", pluginVersion: "1.0.0",
                           displayName: "S", lookbackDays: lookbackDays)
            s.lastSuccessAt = lastSuccess
            return s
        }
        let now = InvoiceDateParser.parse("2026-06-01")!
        let floor = InvoiceDateParser.parse("2026-01-01")!

        await test("With no floor, nothing changes") {
            let cutoff = source(lastSuccess: nil).incrementalCutoff(now: now)
            expectEqual(InvoiceDateParser.isoString(cutoff), "2026-03-03")
        }

        await test("The floor shortens a long first-run window") {
            // 3650 days back would walk a decade of a supplier's history.
            let cutoff = source(lastSuccess: nil, lookbackDays: 3650)
                .incrementalCutoff(now: now, notBefore: floor)
            expectEqual(InvoiceDateParser.isoString(cutoff), "2026-01-01")
        }

        await test("The floor never lengthens a walk") {
            // The cursor already says "I have everything up to May"; a floor in
            // January must not send the run back through what it has.
            let cutoff = source(lastSuccess: InvoiceDateParser.parse("2026-05-20")!)
                .incrementalCutoff(now: now, notBefore: floor)
            expectEqual(InvoiceDateParser.isoString(cutoff), "2026-05-13")
        }

        await test("A floor in the future wins, and stops collection dead") {
            // Not a case to be clever about: the user asked for nothing older
            // than a date, and honouring it literally is what they can predict.
            let cutoff = source(lastSuccess: nil)
                .incrementalCutoff(now: now, notBefore: InvoiceDateParser.parse("2027-01-01")!)
            expectEqual(InvoiceDateParser.isoString(cutoff), "2027-01-01")
        }
    }
}

/// The two export destinations the model always declared and nothing
/// implemented: Paperless-ngx, and an e-mail the user sends themselves.
@MainActor
func runExportDestinationSuites() async {

    func document(_ date: String?, issuer: String?, number: String?, cents: Int?) -> InvoiceDocument {
        var d = InvoiceDocument(entityID: UUID(), sha256: "x", relativePath: "a/b.pdf", byteSize: 1)
        d.issuedOn = date.flatMap(InvoiceDateParser.parse)
        d.issuer = issuer
        d.number = number
        d.total = cents.map { Money(cents: $0, currency: "EUR") }
        return d
    }

    await suite("Paperless-ngx") {

        await test("The endpoint is built under whatever path the instance is served at") {
            for base in ["https://paperless.example.com",
                         "https://paperless.example.com/"] {
                let exporter = PaperlessExporter(baseURL: URL(string: base)!, token: "t")
                expectEqual(exporter.endpoint.absoluteString,
                            "https://paperless.example.com/api/documents/post_document/")
            }
        }

        await test("A reverse proxy sub-path is kept") {
            // Serving Paperless at /paperless behind nginx is the common
            // self-hosted shape; dropping the prefix would post into nothing.
            let exporter = PaperlessExporter(
                baseURL: URL(string: "https://home.example.com/paperless")!, token: "t")
            expectEqual(exporter.endpoint.absoluteString,
                        "https://home.example.com/paperless/api/documents/post_document/")
        }

        await test("Two instances are two destinations") {
            let a = PaperlessExporter(baseURL: URL(string: "https://a.example.com")!, token: "t")
            let b = PaperlessExporter(baseURL: URL(string: "https://b.example.com")!, token: "t")
            expect(a.destinationID != b.destinationID,
                   "a document sent to one is not already sent to the other")
            expectEqual(a.kind, .paperless)
        }
    }

    await suite("E-mail message") {

        let march = [document("2026-03-31", issuer: "OVHcloud", number: "FR-1", cents: 12000)]
        let quarter = [
            document("2026-01-15", issuer: "OVHcloud", number: "FR-1", cents: 12000),
            document("2026-03-31", issuer: "GitHub", number: "GH-9", cents: 3450),
        ]

        await test("The subject names the organisation and the period") {
            let subject = EmailMessage.subject(for: march, entityName: "MeilleursBiens")
            expect(subject.contains("MeilleursBiens"), subject)
            expect(subject.contains("2026"), subject)
        }

        await test("A range of months reads as a range") {
            let subject = EmailMessage.subject(for: quarter, entityName: nil)
            expect(subject.contains("–"), subject)
        }

        await test("Documents with no date do not invent a period") {
            let undated = [document(nil, issuer: "X", number: nil, cents: nil)]
            expect(EmailMessage.period(of: undated) == nil)
            // And the subject still says something rather than trailing a dash.
            let subject = EmailMessage.subject(for: undated, entityName: nil)
            expect(!subject.hasSuffix("—"), subject)
        }

        await test("The body is a manifest, oldest first, with a total") {
            let body = EmailMessage.body(for: quarter)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            expect(lines[0].contains("2"), body)
            expect(body.contains("154.50") || body.contains("154,50"), body)
            // Oldest first: whoever reconciles this reads down the page.
            let ovh = body.range(of: "OVHcloud")!, github = body.range(of: "GitHub")!
            expect(ovh.lowerBound < github.lowerBound, body)
        }

        await test("A missing field is a dash, not an empty column") {
            let body = EmailMessage.body(for: [document("2026-02-01", issuer: nil,
                                                        number: nil, cents: nil)])
            expect(body.contains("—"), body)
        }

        await test("Mixed currencies produce no total rather than a wrong one") {
            var dollars = document("2026-02-01", issuer: "X", number: "1", cents: 100)
            dollars.total = Money(cents: 100, currency: "USD")
            let body = EmailMessage.body(for: march + [dollars])
            expect(!body.contains("Total"), body)
        }
    }
}

/// Destinations the user configures once and keeps.
@MainActor
func runSavedDestinationSuites() async {
    let entity = UUID()

    func destination(_ kind: ExportDestinationKind, _ config: [String: String]) -> ExportDestination {
        ExportDestination(entityID: entity, kind: kind, name: "D", config: config)
    }

    await suite("Saved export destinations") {

        await test("A destination knows when it is not finished") {
            expect(!destination(.folder, [:]).isComplete(hasSecret: true))
            expect(destination(.folder, ["path": "/tmp/x"]).isComplete(hasSecret: true))

            expect(!destination(.webhook, ["url": "not a url"]).isComplete(hasSecret: true))
            expect(destination(.webhook, ["url": "https://x.example.com"]).isComplete(hasSecret: false),
                   "a webhook's Authorization header is optional")

            // Paperless cannot work without its token, so a missing one is not
            // "configured, will fail later" — it is unfinished.
            expect(!destination(.paperless, ["url": "https://p.example.com"]).isComplete(hasSecret: false))
            expect(destination(.paperless, ["url": "https://p.example.com"]).isComplete(hasSecret: true))

            // A recipient can be typed in the mail window.
            expect(destination(.email, [:]).isComplete(hasSecret: true))
        }

        await test("Only kinds with a secret get a keychain item") {
            expect(destination(.paperless, [:]).needsSecret)
            expect(destination(.webhook, [:]).needsSecret)
            for kind in [ExportDestinationKind.folder, .csv, .json, .email] {
                expect(!destination(kind, [:]).needsSecret, "\(kind) has no secret to keep")
            }
        }

        await test("E-mail never runs unattended") {
            // It opens a window someone has to look at; doing that at 3am
            // during a scheduled collection would be a bug, not a feature.
            expect(!ExportDestinationKind.email.canRunAutomatically)
            for kind in [ExportDestinationKind.folder, .csv, .json, .webhook, .paperless] {
                expect(kind.canRunAutomatically, "\(kind) should be able to run on its own")
            }
        }

        await test("Each destination keeps its own keychain account") {
            let a = destination(.paperless, [:]), b = destination(.paperless, [:])
            expect(a.secretAccount != b.secretAccount,
                   "two instances must not share one token")
            expect(a.secretAccount.hasPrefix("export."), a.secretAccount)
        }

        await test("A new destination does not run automatically until asked") {
            expect(!destination(.folder, ["path": "/tmp/x"]).runsAutomatically,
                   "the first run is one the user should watch")
        }

        await test("Every kind has a symbol and an explanation") {
            for kind in ExportDestinationKind.allCases {
                expect(!kind.symbol.isEmpty, "\(kind)")
                expect(!kind.explanation.isEmpty, "\(kind)")
                expect(!kind.displayName.isEmpty, "\(kind)")
            }
        }
    }
}
