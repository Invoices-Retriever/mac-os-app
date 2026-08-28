import Foundation
import IRCore

@MainActor
func runRecorderSuites() async {

    await suite("Plugin recorder") {

        await test("allowedDomains comes from where the recording actually went") {
            // Narrower than anyone writes by hand, because it cannot include a
            // host that was never visited.
            let domains = PluginRecorder.allowedDomains(
                from: ["www.ovh.com", "auth.eu.ovhcloud.com", "manager.eu.ovhcloud.com"])
            expect(domains.contains("ovh.com"))
            expect(domains.contains("*.ovh.com"))
            expect(domains.contains("ovhcloud.com"))
            expect(domains.contains("*.ovhcloud.com"))
            expect(!domains.contains("*.com"), "a whole TLD must never be granted")
        }

        await test("A wildcard appears only where a subdomain was used") {
            let apexOnly = PluginRecorder.allowedDomains(from: ["example.com"])
            expectEqual(apexOnly, ["example.com"])
        }

        await test("A compound suffix keeps three labels") {
            let domains = PluginRecorder.allowedDomains(from: ["billing.acme.co.uk"])
            expect(domains.contains("acme.co.uk"), "got \(domains)")
            expect(!domains.contains("co.uk"), "co.uk is not a registrable domain")
        }

        await test("A field's label becomes a readable config key") {
            var event = PluginRecorder.Event(kind: .type, url: "https://x.example")
            event.label = "Identifiant client OVH"
            expectEqual(PluginRecorder.configKey(for: event, taken: []), "identifiantClientOvh")

            var password = PluginRecorder.Event(kind: .type, url: "https://x.example")
            password.fieldType = "password"
            password.label = ""
            expectEqual(PluginRecorder.configKey(for: password, taken: []), "password")
        }

        await test("Two fields with the same label do not collide") {
            var event = PluginRecorder.Event(kind: .type, url: "https://x.example")
            event.label = "Code"
            expectEqual(PluginRecorder.configKey(for: event, taken: ["code"]), "code2")
        }

        await test("A recorded event has nowhere to put a typed value") {
            // The guarantee is structural rather than a rule someone follows:
            // Event carries a selector, a field type and a label, and there is
            // no field a value could be written into.
            let event = PluginRecorder.Event(kind: .type, url: "https://x.example",
                                             selector: "#password", label: "Mot de passe",
                                             fieldType: "password")
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            expect(!json.lowercased().contains("\"value\""), "an Event gained a value field: \(json)")
        }

        await test("The observer script reads no field values") {
            // If this ever stops being true, a password reaches a JSON file
            // headed for a pull request.
            let script = RecorderScriptSource.observer
            expect(script.contains("kind: 'type'"), "the type event went away")
            for leak in ["el.value,", "value: el.value", "e.target.value"] {
                expect(!script.contains(leak), "the observer reads a value: \(leak)")
            }
        }

        await test("A recording with a sign-in and a table produces a runnable draft") {
            let recorder = PluginRecorder()
            await recorder.record(.init(kind: .navigate, url: "https://www.example.com/login"))
            await recorder.record(.init(kind: .type, url: "https://www.example.com/login",
                                        selector: "#account", label: "Customer number", fieldType: "text"))
            await recorder.record(.init(kind: .type, url: "https://www.example.com/login",
                                        selector: "#password", label: "Password", fieldType: "password"))
            await recorder.record(.init(kind: .click, url: "https://www.example.com/login",
                                        selector: "#login-submit", label: "Sign in"))
            await recorder.record(.init(kind: .navigate, url: "https://billing.example.com/history"))

            let analysis = PluginRecorder.PageAnalysis(
                found: true, url: "https://billing.example.com/history", title: "Invoices",
                rowSelector: "table tbody tr", rowCount: 12,
                columns: [
                    .init(selector: "td:nth-of-type(1)", kind: .reference, samples: ["F-2026-001"]),
                    .init(selector: "td:nth-of-type(2)", kind: .date, samples: ["31/01/2026"]),
                    .init(selector: "td:nth-of-type(3)", kind: .money, samples: ["120,00 €"]),
                ],
                link: .init(selector: "a.download", href: "https://cdn.example.com/a.pdf", isPdf: true))
            await recorder.setAnalysis(analysis)

            let draft = await recorder.makeDraft(id: "example", name: "Example", countries: ["FR"])

            // The whole point: what comes out has to be a plugin the engine and
            // the CI both accept, not a sketch.
            let report = PluginValidator.validate(draft.manifest)
            expect(report.isValid, "invalid draft: \(report.errors.map(\.message))")

            expectEqual(draft.manifest.id, "example")
            expect(draft.manifest.effectiveStatus == .unverified)
            expectEqual(draft.manifest.secretConfigKeys, ["password"])
            expect(draft.manifest.allowedDomains.contains("example.com"))
            expect(draft.manifest.allowedDomains.contains("*.example.com"))

            // The password is referenced, never embedded.
            expect(draft.json.contains("{{secret.password}}"))
            expect(!draft.json.lowercased().contains("hunter"))

            // checkAuth must be able to answer "no", or the app can never tell
            // an expired session from a working one.
            expect(draft.manifest.checkAuth.last?.action == .checkElementExists)

            let emits = draft.manifest.getDocuments.contains { step in
                step.nestedSteps.contains { $0.action.producesDocument }
            }
            expect(emits, "the draft collects nothing")
        }

        await test("A recording with no invoice table says so instead of pretending") {
            let recorder = PluginRecorder()
            await recorder.record(.init(kind: .navigate, url: "https://www.example.com/"))
            let draft = await recorder.makeDraft(id: "example", name: "Example", countries: [])
            expect(draft.warnings.contains { $0.contains("table") || $0.contains("tableau") },
                   "no warning about the missing table: \(draft.warnings)")
        }
    }
}
