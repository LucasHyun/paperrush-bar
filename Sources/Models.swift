import Foundation

// MARK: - Raw feed models (paperrush js/data.js)

struct ConferenceFeed: Decodable {
    let lastUpdated: String?
    let conferences: [Conference]

    enum CodingKeys: String, CodingKey { case lastUpdated, conferences }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastUpdated = try? c.decode(String.self, forKey: .lastUpdated)
        conferences = (try? c.decode([Conference].self, forKey: .conferences)) ?? []
    }
}

struct ConfLocation: Decodable {
    let city: String?
    let country: String?
    let flag: String?
    let venue: String?
}

struct Deadline: Hashable {
    let type: String
    let label: String
    let date: String
    let endDate: String?
    let status: String
    let estimated: Bool
    let timeUnknown: Bool

    /// True when this deadline came from an overlay file rather than upstream.
    var isExtra: Bool = false
}

extension Deadline: Decodable {
    enum CodingKeys: String, CodingKey {
        case type, label, date, endDate, status, estimated, timeUnknown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedType = (try? c.decode(String.self, forKey: .type)) ?? "other"
        type = decodedType
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? Deadline.defaultLabel(for: decodedType)
        endDate = try? c.decode(String.self, forKey: .endDate)
        status = (try? c.decode(String.self, forKey: .status)) ?? "upcoming"
        estimated = (try? c.decode(Bool.self, forKey: .estimated)) ?? false
        timeUnknown = (try? c.decode(Bool.self, forKey: .timeUnknown)) ?? false
    }

    static func defaultLabel(for type: String) -> String {
        switch type {
        case "paper": return "Paper Submission"
        case "abstract": return "Abstract Deadline"
        case "supplementary": return "Supplementary Material"
        case "rebuttal": return "Rebuttal"
        case "notification": return "Notification"
        case "camera": return "Camera Ready"
        case "conference": return "Conference"
        default: return type.capitalized
        }
    }
}

struct Conference: Identifiable, Hashable {
    let id: String
    let name: String
    let fullName: String
    let year: Int
    let category: String
    let website: String
    let brandColor: String
    let city: String
    let country: String
    let flag: String
    var deadlines: [Deadline]
    let links: [String: String]
    let isEstimated: Bool

    /// `"patch"` in an overlay file means "add these deadlines to the upstream entry"
    /// instead of the default "use this only until upstream has the conference".
    let overlayMode: String?

    /// True when this entry comes from an overlay file rather than upstream.
    var isExtra: Bool = false

    var isPatch: Bool { overlayMode == "patch" }

    /// Upstream entry + the overlay deadlines it is missing.
    func patched(with overlay: Conference) -> Conference {
        let additions = overlay.deadlines.filter { !covers($0) }
        guard !additions.isEmpty else { return self }
        var copy = self
        copy.deadlines = (deadlines + additions).sorted { $0.date < $1.date }
        return copy
    }

    /// An overlay deadline is redundant once upstream lists the same thing — exactly
    /// (same type, same day) or, for a date we only estimated, close enough that the
    /// official one is clearly the same milestone.
    private func covers(_ candidate: Deadline) -> Bool {
        for existing in deadlines where existing.type == candidate.type {
            if existing.date.prefix(10) == candidate.date.prefix(10) { return true }
            if candidate.estimated, !existing.estimated,
               let a = DateHelper.parse(existing.date),
               let b = DateHelper.parse(candidate.date),
               abs(a.timeIntervalSince(b)) < 45 * 86400 {
                return true
            }
        }
        return false
    }

    /// Best URL to open for this conference.
    var url: URL? {
        let candidates = [website,
                          links["official"] ?? "",
                          links["submission"] ?? "",
                          links["dates"] ?? "",
                          links["previousEdition"] ?? ""]
        for candidate in candidates where candidate.hasPrefix("http") {
            if let u = URL(string: candidate) { return u }
        }
        return URL(string: "https://paperrush.dev/")
    }

    var displayName: String { "\(name) \(String(year))" }

    var locationText: String {
        let parts = [city, country].filter { !$0.isEmpty && $0 != "TBD" }
        guard !parts.isEmpty else { return "" }
        let joined = parts.joined(separator: ", ")
        return flag.isEmpty ? joined : "\(flag) \(joined)"
    }
}

extension Conference: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, fullName, year, category, website, brandColor
        case location, deadlines, links, isEstimated
        case overlayMode = "mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Unknown"
        fullName = (try? c.decode(String.self, forKey: .fullName)) ?? name
        year = (try? c.decode(Int.self, forKey: .year)) ?? 0
        category = (try? c.decode(String.self, forKey: .category)) ?? "other"
        website = (try? c.decode(String.self, forKey: .website)) ?? ""
        brandColor = (try? c.decode(String.self, forKey: .brandColor)) ?? "#8E8E93"
        let loc = try? c.decode(ConfLocation.self, forKey: .location)
        city = loc?.city ?? ""
        country = loc?.country ?? ""
        flag = loc?.flag ?? ""
        deadlines = (try? c.decode([Deadline].self, forKey: .deadlines)) ?? []
        links = (try? c.decode([String: String].self, forKey: .links)) ?? [:]
        isEstimated = (try? c.decode(Bool.self, forKey: .isEstimated)) ?? false
        overlayMode = try? c.decode(String.self, forKey: .overlayMode)
    }
}

// MARK: - Flattened item used by the UI

struct DeadlineItem: Identifiable, Hashable {
    let conference: Conference
    let deadline: Deadline
    let date: Date

    var id: String { "\(conference.id)|\(deadline.type)|\(deadline.date)" }

    /// Deadlines that matter for "when do I have to submit".
    var isSubmission: Bool {
        ["paper", "abstract"].contains(deadline.type)
    }

    var isDateOnly: Bool { deadline.date.count <= 10 || deadline.timeUnknown }

    var daysRemaining: Int { DateHelper.daysRemaining(to: date) }

    var ddayText: String {
        let d = daysRemaining
        if d < 0 { return "D+\(String(-d))" }
        if d == 0 { return L10n.t("dday.today") }
        return "D-\(String(d))"
    }

    /// Localized when we know the label, original English otherwise.
    var labelText: String { L10n.deadlineLabel(deadline.label) }

    var dateText: String {
        isDateOnly ? DateHelper.dayFormatter.string(from: date)
                   : DateHelper.dayTimeFormatter.string(from: date)
    }
}

// MARK: - Dates

enum DateHelper {
    static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let dayOnlyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Set from L10n so dates follow the language chosen in the app.
    static var locale: Locale = .current {
        didSet {
            dayFormatter = make("MMMdE")
            dayTimeFormatter = make("MMMdEHm")
            stampFormatter = make("MMMdHm")
        }
    }

    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static var dayFormatter: DateFormatter = make("MMMdE")
    static var dayTimeFormatter: DateFormatter = make("MMMdEHm")
    static var stampFormatter: DateFormatter = make("MMMdHm")

    /// Handles both "2027-04-06" and "2026-08-28T11:00:00-07:00".
    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count <= 10 {
            guard let d = dayOnlyParser.date(from: s) else { return nil }
            // A date without a time is treated as end-of-day, local time.
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: d) ?? d
        }
        return isoFull.date(from: s) ?? isoFractional.date(from: s)
    }

    static func daysRemaining(to date: Date, from now: Date = Date()) -> Int {
        let cal = Calendar.current
        let a = cal.startOfDay(for: now)
        let b = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

// MARK: - Categories

struct CategoryOption: Identifiable, Hashable {
    let id: String
    var label: String { L10n.categoryLabel(id) }
}

enum ConfCategory {
    static let order: [CategoryOption] = [
        CategoryOption(id: "all"),
        CategoryOption(id: "cv"),
        CategoryOption(id: "ml"),
        CategoryOption(id: "nlp"),
        CategoryOption(id: "speech"),
        CategoryOption(id: "robotics"),
        CategoryOption(id: "other")
    ]
}

enum NotifyMode: String, CaseIterable, Identifiable {
    case off, favorites, all
    var id: String { rawValue }
    var label: String { L10n.t("notify.\(rawValue)") }
}
