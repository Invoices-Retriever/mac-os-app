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
