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

    // The overlay ships inside the app, but this repo's own weekly Gemini job keeps the
    // published copy fresher — so read that and treat the bundled one as the fallback.
    static let extrasURL = URL(string: "https://raw.githubusercontent.com/LucasHyun/paperrush-bar/main/Resources/extras.json")!
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/LucasHyun/paperrush-bar/releases/latest")!

    struct UpdateInfo: Equatable {
        let version: String
        let url: URL
    }

    /// Set when GitHub has a release newer than the running build. Checked once a day.
    @Published private(set) var availableUpdate: UpdateInfo?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    @Published private(set) var conferences: [Conference] = []
    @Published private(set) var extrasCount = 0
    @Published private(set) var items: [DeadlineItem] = []
    @Published private(set) var feedUpdated: Date?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var now = Date()

    /// The menu bar glyph. Redrawn whenever the nearest deadline or the clock moves,
    /// so the sand level tracks how much time is left.
    @Published private(set) var menuBarIcon: NSImage = HourglassIcon.image(fill: nil, grain: nil)
    /// Bumped on every redraw; the label uses it as an identity so SwiftUI cannot
    /// decide two NSImages are "the same" and skip the frame.
    @Published private(set) var iconVersion = 0
    /// False once the sand has a colour; the label must then stop forcing template rendering.
    @Published private(set) var iconIsTemplate = true
    private var grainProgress: Double?
    private var grainStep = 0
    private var grainTimer: Timer?
    private var lastTickDay: Date?

    /// When the nearest deadline is close, sand trickles on its own — the closer, the
    /// faster. Off by choice, or automatically when the system asks for reduced motion.
    @Published var urgencyAnimation: Bool {
        didSet {
            defaults.set(urgencyAnimation, forKey: Keys.urgencyAnimation)
            urgencyTier = -1
            scheduleUrgencyTrickle()
        }
    }
    private var urgencyTimer: Timer?
    private var urgencyTier = -1

    /// The anxious wobble: a short, damped side-to-side tilt, like tapping a foot.
    private var tilt: Double = 0
    private var wobbleTimer: Timer?
    private var wobbleStep = 0
    private var grainsSinceWobble = 0

    @Published var favorites: Set<String> = [] {
        didSet {
            defaults.set(Array(favorites), forKey: Keys.favorites)
            rotationIndex = 0
            rebuild()
            scheduleNotifications()
        }
    }

    @Published var menuBarSubmissionOnly: Bool {
        didSet {
            defaults.set(menuBarSubmissionOnly, forKey: Keys.menuBarSubmissionOnly)
            menuBarSelectionChanged()
        }
    }

    /// One line holds one deadline, so when several are being tracked the menu bar
    /// takes turns showing them.
    @Published var menuBarRotate: Bool {
        didSet {
            defaults.set(menuBarRotate, forKey: Keys.menuBarRotate)
            menuBarSelectionChanged()
        }
    }

    private var rotationIndex = 0
    private var rotationTimer: Timer?
    /// Past a handful the cycle is too slow to be a glance, so it stays at the nearest few.
    private static let rotationSlots = 5
    private static let rotationInterval: TimeInterval = 7

    @Published var notifyMode: NotifyMode {
        didSet {
            defaults.set(notifyMode.rawValue, forKey: Keys.notifyMode)
            scheduleNotifications()
        }
    }

    /// Separate from `notifyMode`: someone who wants no deadline reminders may still
    /// want to hear that a new version exists, and the reverse.
    @Published var notifyUpdates: Bool {
        didSet { defaults.set(notifyUpdates, forKey: Keys.notifyUpdates) }
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

    /// Conferences as published by paperrush.
    private var upstream: [Conference] = []
    /// Conferences shipped with the app that upstream does not cover yet.
    private var bundledExtras: [Conference] = []
    /// The same overlay, as published by this app's repository (preferred when present).
    private var remoteExtras: [Conference] = []
    /// Conferences the user added in their own extras.json.
    private var userExtras: [Conference] = []
    /// Dates this Mac checked against the conference's own page and the person approved.
    private var corrections: [Correction] = []

    // MARK: Scan state

    enum ScanState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(checked: Int)
    }

    @Published private(set) var hasGeminiKey = Keychain.get(account: GeminiScout.apiKeyAccount) != nil
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var proposals: [DeadlineProposal] = []
    @Published private(set) var scanError: String?
    private var scanTask: Task<Void, Never>?

    private enum Keys {
        static let favorites = "favorites"
        static let menuBarSubmissionOnly = "menuBarSubmissionOnly"
        static let notifyMode = "notifyMode"
        static let language = "language"
        static let urgencyAnimation = "urgencyAnimation"
        static let lastFetch = "lastFetch"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let menuBarRotate = "menuBarRotate"
        static let notifyUpdates = "notifyUpdates"
        static let notifiedUpdateVersion = "notifiedUpdateVersion"
    }

    private init() {
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        menuBarSubmissionOnly = defaults.object(forKey: Keys.menuBarSubmissionOnly) as? Bool ?? true
        notifyMode = NotifyMode(rawValue: defaults.string(forKey: Keys.notifyMode) ?? "all") ?? .all
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "system") ?? .system
        urgencyAnimation = defaults.object(forKey: Keys.urgencyAnimation) as? Bool ?? true
        menuBarRotate = defaults.object(forKey: Keys.menuBarRotate) as? Bool ?? true
        notifyUpdates = defaults.object(forKey: Keys.notifyUpdates) as? Bool ?? true
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
        // Keeps the D-day label honest across midnight, and lets one grain fall when it does.
        lastTickDay = Calendar.current.startOfDay(for: Date())
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                let store = Store.shared
                store.now = Date()
                store.rebuild()
                let today = Calendar.current.startOfDay(for: store.now)
                if let last = store.lastTickDay, last != today { store.dropGrain() }
                store.lastTickDay = today
            }
        }
        dropGrain()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await Store.shared.refresh(force: false) }
        }
        // Reduce Motion toggled in System Settings: stop or resume the trickle at once.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Store.shared.urgencyTier = -1
                Store.shared.scheduleUrgencyTrickle()
            }
        }
        scheduleUrgencyTrickle()
    }

    // MARK: - Data

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperRushBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var cacheURL: URL { supportDirectory.appendingPathComponent("conferences.json") }
    private var remoteExtrasCacheURL: URL { supportDirectory.appendingPathComponent("extras-remote.json") }
    private var correctionsURL: URL { supportDirectory.appendingPathComponent("verified-dates.json") }

    /// The user's own overlay, edited by hand.
    var userExtrasURL: URL { supportDirectory.appendingPathComponent("extras.json") }

    private func loadFromDisk() {
        loadExtras()
        if let data = try? Data(contentsOf: cacheURL), apply(data) { return }
        if let bundled = Bundle.main.url(forResource: "conferences", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            _ = apply(data)
        } else {
            merge()   // extras alone are better than an empty list
        }
    }

    private func loadExtras() {
        bundledExtras = Store.decodeConferences(at: Bundle.main.url(forResource: "extras", withExtension: "json"))
        remoteExtras = Store.decodeConferences(at: remoteExtrasCacheURL)
        userExtras = Store.decodeConferences(at: userExtrasURL)
        if let data = try? Data(contentsOf: correctionsURL),
           let saved = try? JSONDecoder().decode([Correction].self, from: data) {
            corrections = saved
        }
    }

    private func saveCorrections() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        try? data.write(to: correctionsURL, options: .atomic)
    }

    /// The published overlay replaces the bundled one wholesale — same file, newer.
    private var overlay: [Conference] { remoteExtras.isEmpty ? bundledExtras : remoteExtras }

    private static func decodeConferences(at url: URL?) -> [Conference] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(ConferenceFeed.self, from: data) else { return [] }
        return feed.conferences.map { conf in
            var copy = conf
            copy.isExtra = true
            copy.deadlines = conf.deadlines.map { deadline in
                var d = deadline
                d.isExtra = true
                return d
            }
            return copy
        }
    }

    @discardableResult
    private func apply(_ data: Data) -> Bool {
        guard let feed = try? JSONDecoder().decode(ConferenceFeed.self, from: data),
              !feed.conferences.isEmpty else { return false }
        upstream = feed.conferences
        feedUpdated = feed.lastUpdated.flatMap { DateHelper.parse($0) }
        merge()
        return true
    }

    /// Overlay order: bundled extras < user extras < upstream.
    ///
    /// A normal overlay entry only fills a gap: once upstream ships the same id it is
    /// dropped entirely, so nothing goes stale. An entry marked `"mode": "patch"` instead
    /// adds its deadlines to the upstream entry — that is how a conference upstream tracks
    /// only partially (KDD's second submission cycle, say) gets completed.
    private func merge() {
        var byId: [String: Conference] = [:]
        for conf in overlay { byId[conf.id] = conf }
        for conf in userExtras { byId[conf.id] = conf }

        for conf in upstream {
            if let overlay = byId[conf.id], overlay.isPatch {
                byId[conf.id] = conf.patched(with: overlay)
            } else {
                byId[conf.id] = conf
            }
        }

        conferences = applyCorrections(to: Array(byId.values))
        extrasCount = conferences.reduce(into: 0) { count, conf in
            count += conf.deadlines.contains { $0.isExtra } ? 1 : 0
        }
        rebuild()
    }

    /// Lay approved, page-verified dates over whatever the downloads say.
    ///
    /// A correction remembers the date it replaced and only applies while that is still
    /// what the data holds. Once the source moves on the correction is stale and drops
    /// itself, so an old verified date can never bury a newer published one.
    private func applyCorrections(to list: [Conference]) -> [Conference] {
        guard !corrections.isEmpty else { return list }
        var byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var surviving: [Correction] = []

        for correction in corrections {
            guard var conf = byId[correction.conferenceId] else { surviving.append(correction); continue }
            let index = conf.deadlines.firstIndex { $0.type == correction.type && $0.label == correction.label }

            if let index {
                let current = conf.deadlines[index]
                if current.date == correction.date {
                    // The source caught up; the correction has done its job.
                    continue
                }
                guard current.date == correction.replacedDate else { continue }
                conf.deadlines[index] = Deadline(
                    type: current.type, label: current.label, date: correction.date,
                    endDate: correction.endDate, status: current.status, estimated: false,
                    timeUnknown: correction.timeUnknown, sourceUrl: correction.sourceUrl,
                    isExtra: current.isExtra, isVerified: true)
            } else {
                guard correction.replacedDate == nil else { continue }
                conf.deadlines.append(Deadline(
                    type: correction.type, label: correction.label, date: correction.date,
                    endDate: correction.endDate, status: "upcoming", estimated: false,
                    timeUnknown: correction.timeUnknown, sourceUrl: correction.sourceUrl,
                    isExtra: true, isVerified: true))
            }
            conf.deadlines.sort { $0.date < $1.date }
            byId[conf.id] = conf
            surviving.append(correction)
        }

        if surviving.count != corrections.count {
            corrections = surviving
            saveCorrections()
        }
        return Array(byId.values)
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
        updateIcon()
        scheduleUrgencyTrickle()
        scheduleRotation()
    }

    // MARK: - Urgency trickle

    /// Seconds between grains for the time left, or nil when it should stay still.
    private static func trickleInterval(hoursLeft: Double) -> TimeInterval? {
        switch hoursLeft {
        case ..<0: return nil          // passed; the next deadline takes over on rebuild
        case ..<12: return 0.9         // last half day: a continuous stream
        case ..<24: return 3           // D-1
        case ..<72: return 8           // D-3
        default: return nil            // a week or more out: just the level
        }
    }

    private func scheduleUrgencyTrickle() {
        var interval: TimeInterval?
        if urgencyAnimation,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let item = menuBarItem {
            interval = Store.trickleInterval(hoursLeft: item.date.timeIntervalSince(now) / 3600)
        }

        // Only touch the timer when the tier changes, so the minute tick does not
        // keep resetting the rhythm.
        let tier: Int
        switch interval {
        case nil: tier = 0
        case .some(let s) where s < 1: tier = 3
        case .some(let s) where s < 5: tier = 2
        default: tier = 1
        }
        guard tier != urgencyTier else { return }
        urgencyTier = tier

        urgencyTimer?.invalidate()
        urgencyTimer = nil
        guard let interval else { return }
        urgencyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in Store.shared.dropGrain() }
        }
        urgencyTimer?.tolerance = interval * 0.2
    }

    // MARK: - Menu bar glyph

    private func updateIcon() {
        let hoursLeft = menuBarItem.map { $0.date.timeIntervalSince(now) / 3600 }
        let fill = hoursLeft.map { HourglassIcon.fill(daysRemaining: $0 / 24) }
        menuBarIcon = HourglassIcon.label(fill: fill, grain: grainProgress, tilt: tilt,
                                          hoursLeft: hoursLeft, title: menuBarTitle)
        iconIsTemplate = (hoursLeft.map(HourglassIcon.urgencyTier) ?? 0) == 0
        iconVersion &+= 1
    }

    /// ~0.55 s of damped side-to-side tilt. Fired every few grains once the trickle is
    /// in its urgent tiers, so the glass looks restless rather than merely draining.
    func wobble() {
        guard wobbleTimer == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let steps = 11
        let amplitude = 9.0
        wobbleStep = 0
        wobbleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                let store = Store.shared
                store.wobbleStep += 1
                let t = Double(store.wobbleStep) / Double(steps)
                if store.wobbleStep >= steps {
                    store.wobbleTimer?.invalidate()
                    store.wobbleTimer = nil
                    store.tilt = 0
                } else {
                    // Three swings, fading out: sin gives the swing, (1 - t) the fade.
                    store.tilt = amplitude * sin(t * .pi * 3) * (1 - t)
                }
                store.updateIcon()
            }
        }
    }

    /// One grain falls from the throat to the floor over ~0.6 s. Fired at launch, when a
    /// refresh lands, and when the day rolls over — never continuously, which in a menu
    /// bar is a distraction and a battery drain.
    func dropGrain() {
        guard grainTimer == nil, menuBarItem != nil else { return }

        // Once the trickle is on, every few grains the glass also gives a little shake:
        // about every 40 s at D-3, every 12 s at D-1, every 6 s in the last half day.
        if urgencyTier >= 1 {
            grainsSinceWobble += 1
            let every = [1: 5, 2: 4, 3: 8][urgencyTier] ?? 5
            if grainsSinceWobble >= every {
                grainsSinceWobble = 0
                wobble()
            }
        }

        let steps = 22
        grainStep = 0
        grainTimer = Timer.scheduledTimer(withTimeInterval: 0.8 / Double(steps), repeats: true) { _ in
            Task { @MainActor in
                let store = Store.shared
                store.grainStep += 1
                if store.grainStep >= steps {
                    store.grainTimer?.invalidate()
                    store.grainTimer = nil
                    store.grainProgress = nil
                } else {
                    store.grainProgress = Double(store.grainStep) / Double(steps)
                }
                store.updateIcon()
            }
        }
    }

    func refresh(force: Bool) async {
        // Cheap, and it picks up hand edits to the user's extras.json.
        loadExtras()
        merge()

        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 6 * 3600 { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // The overlay is published alongside the app and refreshed weekly; a failure here
        // is not worth surfacing, since the cached or bundled copy still stands.
        await fetchPublishedOverlay()
        await checkForUpdate()

        do {
            let data = try await Store.download(Store.sourceURL)
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
            dropGrain()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "PaperRushBar", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    /// Once a day, ask GitHub for the latest release and remember it if it is newer.
    /// Quiet on every failure: an update notice is a nicety, not something to alarm about.
    private func checkForUpdate() async {
        if let last = defaults.object(forKey: Keys.lastUpdateCheck) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        guard let data = try? await Store.download(Store.latestReleaseURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        defaults.set(Date(), forKey: Keys.lastUpdateCheck)
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        availableUpdate = Store.isNewer(latest, than: Store.currentVersion)
            ? UpdateInfo(version: latest, url: page) : nil
        if let update = availableUpdate { announce(update) }
    }

    /// Say it once per version and never again. Nobody downloads a zip and then goes
    /// looking for a gear menu, so the app has to speak first -- but an update notice
    /// that reappears every day is how people learn to silence an app for good.
    private func announce(_ update: UpdateInfo) {
        guard notifyUpdates,
              defaults.string(forKey: Keys.notifiedUpdateVersion) != update.version else { return }
        defaults.set(update.version, forKey: Keys.notifiedUpdateVersion)

        let content = UNMutableNotificationContent()
        content.title = L10n.t("update.notify.title", update.version)
        content.body = L10n.t("update.notify.body")
        content.sound = .default
        content.userInfo = ["url": update.url.absoluteString]
        // No trigger: delivered now rather than left pending, where the next
        // scheduleNotifications() would clear it along with the deadline reminders.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update|" + update.version,
                                  content: content, trigger: nil),
            withCompletionHandler: nil)
    }

    /// Numeric dotted comparison; "1.10.0" is newer than "1.9.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (pa, pb) = (parts(a), parts(b))
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x > y }
        }
        return false
    }

    func openUpdate() {
        if let url = availableUpdate?.url { NSWorkspace.shared.open(url) }
    }

    private func fetchPublishedOverlay() async {
        guard let data = try? await Store.download(Store.extrasURL),
              let feed = try? JSONDecoder().decode(ConferenceFeed.self, from: data),
              !feed.conferences.isEmpty else { return }
        try? data.write(to: remoteExtrasCacheURL, options: .atomic)
        loadExtras()
        merge()
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

    /// Everything eligible for the menu bar, nearest first.
    ///
    /// Starring a conference is already the person saying "this one is mine", so the
    /// menu bar follows the stars rather than a separate setting to find and switch on.
    /// With nothing starred there is nothing to narrow by, so it shows the field.
    var menuBarCandidates: [DeadlineItem] {
        let eligible = upcoming.filter { !menuBarSubmissionOnly || $0.isSubmission }
        let starred = eligible.filter { favorites.contains($0.conference.id) }
        return starred.isEmpty ? eligible : starred
    }

    /// What the menu bar is showing right now.
    ///
    /// Cycling stops as soon as the nearest deadline is inside D-3: draining sand and a
    /// reddening glyph only mean something while they keep describing one conference,
    /// and by then there is a single deadline worth looking at anyway.
    var menuBarItem: DeadlineItem? {
        let candidates = menuBarCandidates
        guard let nearest = candidates.first else { return nil }
        guard isCycling(candidates) else { return nearest }
        return candidates[rotationIndex % min(candidates.count, Store.rotationSlots)]
    }

    private func isCycling(_ candidates: [DeadlineItem]) -> Bool {
        guard menuBarRotate, candidates.count > 1, let nearest = candidates.first else { return false }
        return nearest.date.timeIntervalSince(now) / 3600 >= 72
    }

    /// Restart the cycle from the top whenever what it cycles over changes, so a newly
    /// starred conference is shown at once rather than after a lap.
    private func menuBarSelectionChanged() {
        rotationIndex = 0
        updateIcon()
        scheduleUrgencyTrickle()
        scheduleRotation()
    }

    private func scheduleRotation() {
        let wanted = isCycling(menuBarCandidates)
        if !wanted {
            rotationTimer?.invalidate()
            rotationTimer = nil
            if rotationIndex != 0 { rotationIndex = 0; updateIcon() }
            return
        }
        guard rotationTimer == nil else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Store.rotationInterval, repeats: true) { _ in
            Task { @MainActor in
                let store = Store.shared
                store.rotationIndex &+= 1
                store.updateIcon()
            }
        }
        rotationTimer?.tolerance = Store.rotationInterval * 0.3
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

    /// Creates the user's overlay file if needed, then reveals it in Finder.
    func openUserExtras() {
        let url = userExtrasURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Store.userExtrasTemplate.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let userExtrasTemplate = """
    {
      "note": "Your own conferences, merged on top of the paperrush dataset. Same schema as the app's bundled extras.json, and re-read on every refresh. An entry is used only until upstream has the same id; to instead ADD deadlines to a conference upstream already tracks, give the entry that id plus \\"mode\\": \\"patch\\".",
      "conferences": [],
      "_example_move_this_into_conferences": [
        {
          "id": "example-2027",
          "name": "EXAMPLE",
          "fullName": "An Example Conference",
          "year": 2027,
          "category": "ml",
          "website": "https://example.org/",
          "brandColor": "#FF6B6B",
          "location": { "city": "Seoul", "country": "South Korea", "flag": "🇰🇷", "venue": null },
          "deadlines": [
            {
              "type": "paper",
              "label": "Paper Submission",
              "date": "2027-05-20T23:59:00-12:00",
              "endDate": null,
              "status": "upcoming",
              "estimated": false
            }
          ],
          "links": { "official": "https://example.org/" },
          "isEstimated": false,
          "datesTBD": false
        }
      ]
    }

    """

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

    // MARK: - Gemini scan

    func saveGeminiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = Keychain.set(trimmed, account: GeminiScout.apiKeyAccount)
        hasGeminiKey = ok
        if ok { scanError = nil }
        return ok
    }

    func removeGeminiKey() {
        Keychain.remove(account: GeminiScout.apiKeyAccount)
        hasGeminiKey = false
        proposals = []
        scanState = .idle
        scanError = nil
    }

    var isScanning: Bool {
        if case .running = scanState { return true }
        return false
    }

    /// Read every conference's own pages and collect what disagrees with the data.
    /// Nothing is applied here — the person decides, because a wrong deadline is
    /// worse than a missing one.
    func startScan() {
        guard !isScanning, let key = Keychain.get(account: GeminiScout.apiKeyAccount) else { return }
        proposals = []
        scanError = nil
        scanState = .running(done: 0, total: conferences.count)

        let snapshot = conferences
        scanTask = Task { [weak self] in
            let (found, failure) = await GeminiScout.scan(conferences: snapshot, key: key) { done, total in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.scanState = .running(done: done, total: total)
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.scanTask = nil
                if Task.isCancelled {
                    self.scanState = .idle
                    return
                }
                self.proposals = found
                self.scanError = failure
                self.scanState = .finished(checked: snapshot.count)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .idle
    }

    func dismissProposals() {
        proposals = []
        scanState = .idle
        scanError = nil
    }

    func apply(_ proposal: DeadlineProposal) {
        corrections.removeAll {
            $0.conferenceId == proposal.conferenceId && $0.type == proposal.type && $0.label == proposal.label
        }
        corrections.append(Correction(
            conferenceId: proposal.conferenceId, type: proposal.type, label: proposal.label,
            replacedDate: proposal.replacedDate, date: proposal.date, endDate: proposal.endDate,
            timeUnknown: proposal.timeUnknown, sourceUrl: proposal.sourceUrl, verifiedAt: Date()))
        saveCorrections()
        proposals.removeAll { $0.id == proposal.id }
        merge()
        scheduleNotifications()
    }

    func applyAll() {
        for proposal in proposals { apply(proposal) }
    }

    func openSource(of proposal: DeadlineProposal) {
        if let url = URL(string: proposal.sourceUrl) { NSWorkspace.shared.open(url) }
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
