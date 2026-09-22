import AppKit
import SwiftUI

/// The panel's second page: the Gemini key, and the scan it pays for.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    let onBack: () -> Void

    @State private var draftKey = ""

    private var keyURL: URL { URL(string: "https://aistudio.google.com/apikey")! }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    keySection
                    Divider()
                    scanSection
                    if !store.proposals.isEmpty {
                        Divider()
                        proposalsSection
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 400, height: 540)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                Text(verbatim: L10n.t("settings.back"))
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(verbatim: L10n.t("settings.title"))
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.t("settings.key.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: L10n.t("settings.key.blurb"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                SecureField("AIza…", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button(L10n.t("settings.key.save")) {
                    if store.saveGeminiKey(draftKey) { draftKey = "" }
                }
                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 8) {
                Image(systemName: store.hasGeminiKey ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(store.hasGeminiKey ? Color.green : Color.secondary)
                    .font(.system(size: 11))
                Text(verbatim: store.hasGeminiKey ? L10n.t("settings.key.stored") : L10n.t("settings.key.missing"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.hasGeminiKey {
                    Button(L10n.t("settings.key.remove")) { store.removeGeminiKey() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }

            Link(destination: keyURL) {
                Text(verbatim: L10n.t("settings.key.get"))
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: Scan

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.t("settings.scan.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: L10n.t("settings.scan.blurb"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch store.scanState {
            case .idle:
                Button(L10n.t("settings.scan.start")) { store.startScan() }
                    .disabled(!store.hasGeminiKey)
            case .running(let done, let total):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    HStack {
                        Text(verbatim: L10n.t("settings.scan.progress", String(done), String(total)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.t("settings.scan.cancel")) { store.cancelScan() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                }
            case .finished(let checked):
                HStack(spacing: 8) {
                    Text(verbatim: store.proposals.isEmpty
                         ? L10n.t("settings.scan.clean", String(checked))
                         : L10n.t("settings.scan.found", String(store.proposals.count)))
                        .font(.system(size: 11))
                    Spacer()
                    Button(L10n.t("settings.scan.again")) { store.startScan() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }

            if let error = store.scanError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Proposals

    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: L10n.t("settings.changes.title"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.t("settings.changes.applyAll")) { store.applyAll() }
                    .font(.system(size: 11))
                Button(L10n.t("settings.changes.dismiss")) { store.dismissProposals() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            ForEach(store.proposals) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: proposal.conferenceName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(verbatim: L10n.deadlineLabel(proposal.label))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(L10n.t("settings.changes.apply")) { store.apply(proposal) }
                            .font(.system(size: 10))
                    }
                    HStack(spacing: 6) {
                        if let old = proposal.replacedDate {
                            Text(verbatim: String(old.prefix(10)))
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: L10n.t("settings.changes.new"))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right").font(.system(size: 8))
                        Text(verbatim: String(proposal.date.prefix(10)))
                            .fontWeight(.semibold)
                        Spacer()
                        Button {
                            store.openSource(of: proposal)
                        } label: {
                            Image(systemName: "link").font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(proposal.sourceUrl)
                    }
                    .font(.system(size: 11, design: .rounded))
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
