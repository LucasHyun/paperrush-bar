import Foundation

/// A change the scan found and would like to make, once the person approves it.
struct DeadlineProposal: Identifiable, Hashable {
    let conferenceId: String
    let conferenceName: String
    let type: String
    let label: String
    /// The date currently held, or nil when this deadline is not in the data at all.
    let replacedDate: String?
    let date: String
    let endDate: String?
    let timeUnknown: Bool
    let sourceUrl: String

    var id: String { "\(conferenceId)|\(type)|\(label)|\(date)" }
    var isAddition: Bool { replacedDate == nil }
}

/// An approved proposal, kept so it can be re-applied over the downloaded data.
struct Correction: Codable, Hashable {
    let conferenceId: String
    let type: String
    let label: String
    let replacedDate: String?
    let date: String
    let endDate: String?
    let timeUnknown: Bool
    let sourceUrl: String
    let verifiedAt: Date
}

enum ScoutError: LocalizedError {
    case unauthorized
    case rateLimited
    case http(Int)
    case noPages

    var errorDescription: String? {
        switch self {
        case .unauthorized: return L10n.t("scout.error.key")
        case .rateLimited: return L10n.t("scout.error.rate")
        case .http(let code): return "HTTP \(String(code))"
        case .noPages: return L10n.t("scout.error.noPages")
        }
    }
}

/// Reads each conference's own pages and asks Gemini what the schedule says now.
///
/// The same rule as the repository's weekly job: a date is only ever proposed when
/// its `sourceUrl` is a page we actually fetched **and** the date is legible in that
/// page's text. Everything else is dropped, so the model cannot invent a deadline.
enum GeminiScout {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
    static let apiKeyAccount = "gemini-api-key"
    static let maxPagesPerConference = 3
    static let pageCharLimit = 14_000
    static let concurrency = 3

    private static let userAgent = "PaperRushBar/1.0 (+https://github.com/LucasHyun/paperrush-bar)"
    private static let validTypes: Set<String> = [
        "abstract", "paper", "supplementary", "rebuttal", "notification",
        "camera", "conference", "workshop", "tutorial", "event",
    ]
    private static let months = ["January", "February", "March", "April", "May", "June",
                                 "July", "August", "September", "October", "November", "December"]

    // MARK: - Scan

    static func scan(conferences: [Conference],
                     key: String,
                     progress: (Int, Int) -> Void) async -> ([DeadlineProposal], String?) {
        let now = Date()
        // A conference whose every deadline has passed cannot tell us anything useful.
        let targets = conferences.filter { conf in
            conf.deadlines.contains { d in
                guard let parsed = DateHelper.parse(d.date) else { return false }
                return parsed > now
            }
        }.sorted { $0.name < $1.name }

        let total = targets.count
        guard total > 0 else { return ([], nil) }

        var found: [DeadlineProposal] = []
        var failure: String?
        var completed = 0

        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let slice = Array(targets[index..<min(index + concurrency, targets.count)])
            index += slice.count

            let batch: [([DeadlineProposal], String?)] = await withTaskGroup(
                of: ([DeadlineProposal], String?).self
            ) { group in
                for conf in slice {
                    group.addTask { await inspect(conference: conf, key: key) }
                }
                var out: [([DeadlineProposal], String?)] = []
                for await result in group { out.append(result) }
                return out
            }

            for (proposals, error) in batch {
                found.append(contentsOf: proposals)
                // A key or quota problem will hit every conference; report it once and stop.
                if let error, failure == nil { failure = error }
            }
            completed += slice.count
            progress(completed, total)

            if let failure, failure == ScoutError.unauthorized.errorDescription
                || failure == ScoutError.rateLimited.errorDescription { break }
        }

        let sorted = found.sorted { ($0.conferenceName, $0.date) < ($1.conferenceName, $1.date) }
        return (sorted, failure)
    }

    private static func inspect(conference: Conference, key: String) async -> ([DeadlineProposal], String?) {
        var pages: [String: String] = [:]
        for url in sourceURLs(for: conference).prefix(maxPagesPerConference) {
            if Task.isCancelled { return ([], nil) }
            if let text = await fetch(url) { pages[url.absoluteString] = text }
        }
        guard !pages.isEmpty else { return ([], nil) }

        do {
            let reported = try await ask(key: key, conference: conference, pages: pages)
            return (proposals(from: reported, conference: conference, pages: pages), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// Pages that might state this conference's dates, best first.
    static func sourceURLs(for conference: Conference) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ string: String?) {
            guard let string, string.hasPrefix("http"), !seen.contains(string),
                  let url = URL(string: string) else { return }
            seen.insert(string)
            out.append(url)
        }
        for deadline in conference.deadlines { add(deadline.sourceUrl) }
        for k in ["official", "dates", "submission", "authorGuide"] { add(conference.links[k]) }
        add(conference.website)
        return out
    }

    // MARK: - Fetching

    static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let text = plainText(from: html)
        // Under a couple of hundred characters it is a client-rendered shell, and the
        // dates only exist after JavaScript runs.
        guard text.count >= 200 else { return nil }
        return String(text.prefix(pageCharLimit))
    }

    /// Tags out, script and style blocks dropped, whitespace collapsed.
    static func plainText(from html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count / 2)
        var i = html.startIndex
        let end = html.endIndex

        while i < end {
            guard html[i] == "<" else {
                out.append(html[i])
                i = html.index(after: i)
                continue
            }
            var cursor = html.index(after: i)
            var name = ""
            while cursor < end, html[cursor].isLetter || html[cursor] == "/" {
                name.append(html[cursor])
                cursor = html.index(after: cursor)
            }
            while cursor < end, html[cursor] != ">" { cursor = html.index(after: cursor) }
            if cursor < end { cursor = html.index(after: cursor) }

            let lower = name.lowercased()
            if lower == "script" || lower == "style" || lower == "noscript" {
                if let close = html.range(of: "</\(lower)", options: [.caseInsensitive], range: cursor..<end) {
                    var after = close.upperBound
                    while after < end, html[after] != ">" { after = html.index(after: after) }
                    if after < end { after = html.index(after: after) }
                    i = after
                    continue
                }
            }
            out.append(" ")
            i = cursor
        }

        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                                      ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                      ("&rsquo;", "'"), ("&ndash;", "-"), ("&mdash;", "-")] {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - The model

    private static func ask(key: String, conference: Conference, pages: [String: String]) async throws -> [[String: Any]] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a query parameter, so the key stays out of URLs and logs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt(conference: conference, pages: pages)]]]],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 8192,
                "responseMimeType": "application/json",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 400, 401, 403: throw ScoutError.unauthorized
            case 429: throw ScoutError.rateLimited
            default: throw ScoutError.http(http.statusCode)
            }
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first
        else { return [] }

        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let payload = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let deadlines = object["deadlines"] as? [[String: Any]]
        else { return [] }
        return deadlines
    }

    private static func prompt(conference: Conference, pages: [String: String]) -> String {
        let current = conference.deadlines
            .map { "- \($0.type) | \($0.label) | \($0.date)\($0.estimated ? " (estimated)" : "")" }
            .joined(separator: "\n")
        let rendered = pages.map { "--- PAGE: \($0.key) ---\n\($0.value)" }.joined(separator: "\n\n")
        let today = DateHelper.dayOnlyParser.string(from: Date())

        return """
        You are reading the official pages of one academic conference and extracting its schedule.

        Today is \(today). The conference is \(conference.name) \(String(conference.year)).

        Dates currently on record:
        \(current.isEmpty ? "(none)" : current)

        Pages, as plain text:

        \(rendered)

        Return JSON only:

        {"deadlines":[{"type":"paper","label":"Paper Submission","date":"2027-02-08T23:59:00-12:00","endDate":null,"timeUnknown":false,"sourceUrl":"<the page this date is printed on>"}]}

        Rules:
        - Only report a date printed on one of the pages above, and set sourceUrl to that page's URL exactly as given. Never use your own knowledge of this conference.
        - type is one of: abstract, paper, supplementary, rebuttal, notification, camera, conference, workshop, tutorial, event.
        - Anywhere on Earth (AoE) means a -12:00 offset. Use the stated offset when there is one.
        - With no time of day, write "YYYY-MM-DD" and set timeUnknown to true.
        - Report every submission-related milestone you can see, including separate cycles or rounds, and say which in the label.
        - Omit a date you cannot find on these pages. An empty list is a fine answer.
        """
    }

    // MARK: - Verification

    private static func proposals(from reported: [[String: Any]],
                                  conference: Conference,
                                  pages: [String: String]) -> [DeadlineProposal] {
        var out: [DeadlineProposal] = []
        let cutoff = Date().addingTimeInterval(-86_400)

        for entry in reported {
            guard let type = entry["type"] as? String, validTypes.contains(type),
                  let label = (entry["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
                  let date = entry["date"] as? String, isWellFormed(date),
                  let source = entry["sourceUrl"] as? String,
                  let pageText = pages[source]
            else { continue }

            // The guard that matters: the date has to be legible on the page cited.
            guard dateIsOnPage(date, text: pageText) else { continue }
            guard let parsed = DateHelper.parse(date), parsed > cutoff else { continue }

            let endDate = entry["endDate"] as? String
            if let endDate, !isWellFormed(endDate) { continue }
            let timeUnknown = (entry["timeUnknown"] as? Bool) ?? (date.count <= 10)

            let existing = conference.deadlines.first { $0.type == type && $0.label == label }
                ?? conference.deadlines.first { candidate in
                    guard candidate.type == type, candidate.estimated,
                          let a = DateHelper.parse(candidate.date), let b = DateHelper.parse(date) else { return false }
                    return abs(a.timeIntervalSince(b)) < 45 * 86_400
                }

            if let existing {
                guard existing.date != date else { continue }
                out.append(DeadlineProposal(conferenceId: conference.id, conferenceName: conference.displayName,
                                            type: type, label: existing.label, replacedDate: existing.date,
                                            date: date, endDate: endDate, timeUnknown: timeUnknown, sourceUrl: source))
            } else {
                out.append(DeadlineProposal(conferenceId: conference.id, conferenceName: conference.displayName,
                                            type: type, label: label, replacedDate: nil,
                                            date: date, endDate: endDate, timeUnknown: timeUnknown, sourceUrl: source))
            }
        }
        return out
    }

    static func isWellFormed(_ date: String) -> Bool {
        guard date.count == 10 || date.count == 25 || date.count == 20 else { return false }
        return DateHelper.parse(date) != nil
    }

    /// True when the date is written somewhere on the page, in any of the spellings
    /// conference sites actually use.
    static func dateIsOnPage(_ date: String, text: String) -> Bool {
        guard date.count >= 10 else { return false }
        let year = String(date.prefix(4))
        guard let month = Int(date.dropFirst(5).prefix(2)),
              let day = Int(date.dropFirst(8).prefix(2)),
              (1...12).contains(month), (1...31).contains(day),
              text.contains(year) else { return false }

        let name = months[month - 1]
        let abbr = String(name.prefix(3))
        let dd = String(format: "%02d", day)
        let mm = String(format: "%02d", month)
        let spellings = [
            "\(name) \(day)", "\(name) \(dd)", "\(abbr) \(day)", "\(abbr). \(day)",
            "\(day) \(name)", "\(day) \(abbr)", "\(dd) \(name)",
            "\(month)/\(day)/\(year)", "\(mm)/\(dd)/\(year)",
            "\(year)-\(mm)-\(dd)", "\(day).\(month).\(year)", "\(dd).\(mm).\(year)",
        ]
        let haystack = text.lowercased()
        return spellings.contains { haystack.contains($0.lowercased()) }
    }
}
