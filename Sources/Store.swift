import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // Source of truth: paperrush (github.com/awsaf49/paperrush), updated by its own GitHub Action.
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/awsaf49/paperrush/main/js/data.js")!
    static let projectURL = URL(string: "https://github.com/awsaf49/paperrush")!

    @Published private(set) var conferences: [Conference] = []
    @Published private(set) var items: [DeadlineItem] = []
    @Published private(set) var feedUpdated: Date?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var now = Date()

    @Published var favorites: Set<String> = [] {
        didSet {
            defaults.set(Array(favorites), forKey: Keys.favorites)
            rebuild()
            scheduleNotifications()
        }
    }

    @Published var menuBarFavoritesOnly: Bool {
        didSet { defaults.set(menuBarFavoritesOnly, forKey: Keys.menuBarFavoritesOnly) }
    }

    @Published var menuBarSubmissionOnly: Bool {
        didSet { defaults.set(menuBarSubmissionOnly, forKey: Keys.menuBarSubmissionOnly) }
    }

    @Published var notifyMode: NotifyMode {
        didSet {
            defaults.set(notifyMode.rawValue, forKey: Keys.notifyMode)
            scheduleNotifications()
        }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            L10n.apply(language)
            scheduleNotifications()   // notification text is localized too
        }
    }

    private let defaults = UserDefaults.standard
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    private enum Keys {
        static let favorites = "favorites"
        static let menuBarFavoritesOnly = "menuBarFavoritesOnly"
        static let menuBarSubmissionOnly = "menuBarSubmissionOnly"
        static let notifyMode = "notifyMode"
        static let language = "language"
        static let lastFetch = "lastFetch"
    }

    private init() {
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        menuBarFavoritesOnly = defaults.bool(forKey: Keys.menuBarFavoritesOnly)
        menuBarSubmissionOnly = defaults.object(forKey: Keys.menuBarSubmissionOnly) as? Bool ?? true
        notifyMode = NotifyMode(rawValue: defaults.string(forKey: Keys.notifyMode) ?? "all") ?? .all
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "system") ?? .system
        if let t = defaults.object(forKey: Keys.lastFetch) as? Date { lastFetch = t }
        L10n.apply(language)
        loadFromDisk()
    }

    // MARK: - Lifecycle

    func bootstrap() {
        // Refresh right away, then keep it fresh in the background.
        Task { await refresh(force: false) }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor in await Store.shared.refresh(force: false) }
        }
        // Keeps the D-day label honest across midnight.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                Store.shared.now = Date()
                Store.shared.rebuild()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await Store.shared.refresh(force: false) }
        }
    }

    // MARK: - Data

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperRushBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("conferences.json")
    }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: cacheURL), apply(data) { return }
        if let bundled = Bundle.main.url(forResource: "conferences", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            _ = apply(data)
        }
    }

    @discardableResult
    private func apply(_ data: Data) -> Bool {
        guard let feed = try? JSONDecoder().decode(ConferenceFeed.self, from: data),
              !feed.conferences.isEmpty else { return false }
        conferences = feed.conferences
        feedUpdated = feed.lastUpdated.flatMap { DateHelper.parse($0) }
        rebuild()
        return true
    }

    private func rebuild() {
        var out: [DeadlineItem] = []
        for conf in conferences {
            for dl in conf.deadlines {
                guard let date = DateHelper.parse(dl.date) else { continue }
                out.append(DeadlineItem(conference: conf, deadline: dl, date: date))
            }
        }
        items = out.sorted { $0.date < $1.date }
    }

    func refresh(force: Bool) async {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 6 * 3600 { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: Store.sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "PaperRushBar", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            guard let text = String(data: data, encoding: .utf8),
                  let json = Store.extractJSONObject(from: text, after: "CONFERENCES_DATA") else {
                throw NSError(domain: "PaperRushBar", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: L10n.t("error.parse")])
            }
            guard apply(json) else {
                throw NSError(domain: "PaperRushBar", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: L10n.t("error.decode")])
            }
            try? json.write(to: cacheURL, options: .atomic)
            lastFetch = Date()
            defaults.set(lastFetch, forKey: Keys.lastFetch)
            errorMessage = nil
            scheduleNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// data.js holds `const CONFERENCES_DATA = { ... };` followed by other declarations,
    /// so we pull out exactly one balanced object, string literals included.
    static func extractJSONObject(from js: String, after marker: String) -> Data? {
        guard let markerRange = js.range(of: marker) else { return nil }
        guard let start = js[markerRange.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < js.endIndex {
            let ch = js[index]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = js.index(after: index)
                        return String(js[start..<end]).data(using: .utf8)
                    }
                }
            }
            index = js.index(after: index)
        }
        return nil
    }

    // MARK: - Derived views

    var upcoming: [DeadlineItem] {
        items.filter { $0.date > now }
    }

    func visibleItems(query: String, category: String, favoritesOnly: Bool, submissionOnly: Bool) -> [DeadlineItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = upcoming.filter { item in
            if favoritesOnly && !favorites.contains(item.conference.id) { return false }
            if category != "all" && item.conference.category != category { return false }
            if submissionOnly && !item.isSubmission { return false }
            if !q.isEmpty {
                let haystack = [item.conference.name, item.conference.fullName,
                                item.conference.city, item.conference.country,
                                item.deadline.label, item.labelText].joined(separator: " ").lowercased()
                if !haystack.contains(q) { return false }
            }
            return true
        }
        // Favorites float to the top, everything else stays in date order.
        return filtered.sorted { a, b in
            let fa = favorites.contains(a.conference.id)
            let fb = favorites.contains(b.conference.id)
            if fa != fb { return fa }
            return a.date < b.date
        }
    }

    var menuBarItem: DeadlineItem? {
        upcoming.first { item in
            if menuBarSubmissionOnly && !item.isSubmission { return false }
            if menuBarFavoritesOnly && !favorites.contains(item.conference.id) { return false }
            return true
        }
    }

    var menuBarTitle: String {
        guard let item = menuBarItem else { return "—" }
        return "\(item.conference.name) \(item.ddayText)"
    }

    // MARK: - Actions

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func open(_ conference: Conference) {
        if let url = conference.url { NSWorkspace.shared.open(url) }
    }

    func openSource() { NSWorkspace.shared.open(Store.projectURL) }

    // MARK: - Notifications

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard notifyMode != .off else { return }

        let targets = upcoming
            .filter { $0.isSubmission }
            .filter { notifyMode == .all || favorites.contains($0.conference.id) }
            .prefix(20)

        let calendar = Calendar.current
        for item in targets {
            for offset in [7, 3, 1] {
                guard let fireDay = calendar.date(byAdding: .day, value: -offset, to: item.date) else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: fireDay)
                comps.hour = 9
                comps.minute = 0
                guard let fireDate = calendar.date(from: comps), fireDate > Date() else { continue }

                let content = UNMutableNotificationContent()
                content.title = "\(item.conference.displayName) D-\(String(offset))"
                content.body = "\(item.labelText) · \(item.dateText)"
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "\(item.id)|\(String(offset))",
                    content: content,
                    trigger: trigger
                )
                center.add(request, withCompletionHandler: nil)
            }
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
                objectWillChange.send()
            } catch {
                errorMessage = L10n.t("error.loginItem", error.localizedDescription)
                objectWillChange.send()
            }
        }
    }
}
