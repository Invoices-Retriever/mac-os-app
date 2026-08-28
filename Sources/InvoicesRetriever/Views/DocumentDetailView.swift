import SwiftUI
import IRCore

/// F6.6 and F6.7. Every field shows how confident the app is and where the
/// value came from, and every field can be corrected — after which it is
/// marked as checked by a human and nothing overwrites it.
struct DocumentDetailView: View {
    @Environment(AppModel.self) private var model
    let document: InvoiceDocument
    @Binding var previewURL: URL?

    @State private var fields: [String: String] = [:]
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                GroupBox("Details") {
                    VStack(spacing: 8) {
                        field("Issuer", key: "issuer")
                        field("Number", key: "number")
                        field("Date", key: "issuedOn", hint: "YYYY-MM-DD")
                        field("Total", key: "total", hint: "1234.56")
                        field("VAT", key: "vat")
                        field("VAT number", key: "vatNumber")
                    }
                    .padding(.vertical, 4)
                }

                if document.needsReview && !document.verifiedByHuman {
                    Label(t("Some of these were read off the PDF rather than declared by the plugin. Check them before exporting."),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Button(t("Save and mark as checked")) {
                    Task { await model.setVerified(document, fields: fields) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(fields.isEmpty)

                GroupBox("File") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(t("Path"), value: document.relativePath)
                            .textSelection(.enabled)
                        LabeledContent(t("Size"), value: "\(document.byteSize / 1024) kB")
                        LabeledContent(t("Source"), value: document.sourceID
                            .flatMap { model.sourceNames[$0] } ?? document.origin.displayName)
                        LabeledContent("SHA-256", value: String(document.sha256.prefix(16)) + "…")
                            .textSelection(.enabled)
                            .help(document.sha256)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                HStack {
                    Button(t("Preview")) { previewURL = model.library.url(for: document) }
                    Button(t("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.library.url(for: document)])
                    }
                    Spacer()
                    Button(t("Delete…"), role: .destructive) { isDeleting = true }
                }
            }
            .padding()
        }
        .onAppear(perform: loadFields)
        .onChange(of: document.id) { _, _ in loadFields() }
        .confirmationDialog("Delete this document?", isPresented: $isDeleting) {
            Button(t("Move the file to the Trash and forget it"), role: .destructive) {
                Task { await model.delete(document, removeFile: true) }
            }
            Button(t("Forget it but keep the file")) {
                Task { await model.delete(document, removeFile: false) }
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            // F7.7: never delete without saying exactly what will happen.
            Text(t("Nothing is removed from the supplier's portal. The file goes to the Trash, not straight to nowhere."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.issuer ?? "Unknown issuer").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(document.kind.displayName)
                if document.verifiedByHuman {
                    Badge(text: "Checked by you", colour: .green, symbol: "checkmark.seal")
                } else {
                    confidenceBadge
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var confidenceBadge: some View {
        let confidence = document.lowestConfidence
        let colour: Color = confidence >= 0.8 ? .green : (confidence >= 0.6 ? .yellow : .orange)
        return Badge(text: "Confidence \(Int(confidence * 100))%", colour: colour, symbol: "gauge.medium")
    }

    @ViewBuilder
    private func field(_ label: String, key: String, hint: String? = nil) -> some View {
        HStack {
            Text(label)
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(hint ?? "", text: Binding(
                get: { fields[key] ?? "" },
                set: { fields[key] = $0 }))
                .textFieldStyle(.roundedBorder)
            if let confidence = document.fieldConfidence[key], !document.verifiedByHuman {
                Circle()
                    .fill(confidence >= 0.8 ? Color.green : (confidence >= 0.6 ? .yellow : .orange))
                    .frame(width: 8, height: 8)
                    .help(t("Confidence %@%%", number(Int(confidence * 100))))
            }
        }
    }

    private func loadFields() {
        fields = [
            "issuer": document.issuer ?? "",
            "number": document.number ?? "",
            "issuedOn": document.issuedOn.map(InvoiceDateParser.isoString) ?? "",
            "total": document.total.map { String(format: "%.2f", Double($0.cents) / 100) } ?? "",
            "vat": document.vat.map { String(format: "%.2f", Double($0.cents) / 100) } ?? "",
            "vatNumber": document.vatNumber ?? "",
        ]
    }
}
