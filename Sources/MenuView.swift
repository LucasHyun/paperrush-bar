import AppKit
import SwiftUI

// MARK: - Helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        } else {
            r = 0.55; g = 0.55; b = 0.58
        }
        self.init(red: r, green: g, blue: b)
    }

    static func urgency(_ days: Int) -> Color {
        if days <= 1 { return .red }
        if days <= 3 { return .orange }
        if days <= 7 { return .yellow }
        if days <= 30 { return .green }
        return .secondary
    }
}

// MARK: - Root

struct MenuView: View {
    /// The panel is one window, so settings is a page inside it rather than a
    /// separate window that would steal focus and close the menu bar popover.
    private enum Page { case list, settings }

    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var category = "all"
    @State private var favoritesOnly = false
    @State private var submissionOnly = true
    @State private var page: Page = .list

    private var rows: [DeadlineItem] {
        store.visibleItems(query: query,
                           category: category,
                           favoritesOnly: favoritesOnly,
                           submissionOnly: submissionOnly)
    }

    var body: some View {
        Group {
            switch page {
            case .list:
                VStack(spacing: 0) {
                    header
                    Divider()
                    filters
                    Divider()
                    list
                    Divider()
                    footer
                }
            case .settings:
                SettingsView { page = .list }
            }
        }
        .frame(width: 400, height: 540)
        // Reading the language here makes every string re-render on a switch.
        .id(store.language.rawValue)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.t("app.name"))
                    .font(.system(size: 13, weight: .semibold))
                if let item = store.menuBarItem {
                    Text(verbatim: L10n.t("app.next", item.conference.displayName, item.ddayText))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: L10n.t("app.noDeadline"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    // Also a way to see the glyph move without waiting for midnight.
                    store.dropGrain()
                    store.wobble()
                    Task { await store.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("action.refresh"))
            }
            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var settingsMenu: some View {
        Menu {
            if let update = store.availableUpdate {
                Button(L10n.t("action.update", update.version)) { store.openUpdate() }
                Divider()
            }
            Picker(L10n.t("settings.language"), selection: $store.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(verbatim: lang.nativeName).tag(lang)
                }
            }
            Divider()
            Toggle(L10n.t("settings.launchAtLogin"), isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
            Picker(L10n.t("settings.notifications"), selection: $store.notifyMode) {
                ForEach(NotifyMode.allCases) { mode in
                    Text(verbatim: mode.label).tag(mode)
                }
            }
            Divider()
            Toggle(L10n.t("settings.menubarFavorites"), isOn: $store.menuBarFavoritesOnly)
            Toggle(L10n.t("settings.menubarSubmission"), isOn: $store.menuBarSubmissionOnly)
            Toggle(L10n.t("settings.urgencyAnimation"), isOn: $store.urgencyAnimation)
            Toggle(L10n.t("settings.notifyUpdates"), isOn: $store.notifyUpdates)
            Divider()
            Button(L10n.t("settings.open")) { page = .settings }
            Button(L10n.t("action.openExtras", String(store.extrasCount))) { store.openUserExtras() }
            Button(L10n.t("action.openSource")) { store.openSource() }
            Button(L10n.t("action.quit")) { NSApplication.shared.terminate(nil) }
        } label: {
            // A dot on the gear says an update is waiting, without a second control.
            Image(systemName: store.availableUpdate == nil ? "gearshape" : "gearshape.fill")
                .foregroundStyle(store.availableUpdate == nil ? Color.primary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Filters

    private var filters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField(L10n.t("search.placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "★ " + L10n.t("filter.favorites"), active: favoritesOnly) {
                        favoritesOnly.toggle()
                    }
                    chip(title: L10n.t("filter.submissionOnly"), active: submissionOnly) {
                        submissionOnly.toggle()
                    }
                    Divider().frame(height: 14)
                    ForEach(ConfCategory.order) { option in
                        chip(title: option.label, active: category == option.id) {
                            category = option.id
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.14),
                            in: Capsule())
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private var list: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(verbatim: L10n.t("list.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            DeadlineRow(item: item)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = store.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                Text(verbatim: error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Text(verbatim: footerText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.t("action.quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var footerText: String {
        var parts: [String] = []
        if let feed = store.feedUpdated {
            parts.append(L10n.t("footer.data", DateHelper.stampFormatter.string(from: feed)))
        }
        if let fetch = store.lastFetch {
            parts.append(L10n.t("footer.synced", DateHelper.stampFormatter.string(from: fetch)))
        }
        return parts.isEmpty ? L10n.t("footer.never") : parts.joined(separator: " · ")
    }
}

// MARK: - Row

struct DeadlineRow: View {
    @EnvironmentObject private var store: Store
    @State private var hovering = false
    let item: DeadlineItem

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                store.toggleFavorite(item.conference.id)
            } label: {
                Image(systemName: store.isFavorite(item.conference.id) ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(store.isFavorite(item.conference.id) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: item.conference.brandColor))
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: item.conference.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if item.deadline.estimated || item.conference.isEstimated {
                        badge(L10n.t("badge.estimated"))
                    }
                    if item.deadline.isVerified {
                        badge(L10n.t("badge.verified"))
                            .help(L10n.t("badge.verified.help"))
                    } else if item.deadline.isExtra {
                        badge(L10n.t("badge.extra"))
                    }
                }
                Text(verbatim: "\(item.labelText) · \(item.dateText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(verbatim: item.ddayText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.urgency(item.daysRemaining))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.urgency(item.daysRemaining).opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? Color.secondary.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(item.conference) }
        .help(item.conference.fullName + (item.conference.locationText.isEmpty ? "" : " · " + item.conference.locationText))
    }
}
