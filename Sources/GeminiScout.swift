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
    /// Google's message rides along: "rejected the key" alone does not say whether the
    /// key is wrong, the API is off for the project, or something else entirely.
    case unauthorized(String)
    /// Seconds Google asked us to wait, when it said.
    case rateLimited(TimeInterval?)
    /// The model answered 404 -- retired, or not offered to this key. Never shown: it
    /// moves the scan on to the next model.
    case modelUnavailable
    /// Every model we know of, and every Flash model the key lists, answered 404.
    case noModel
    case api(Int, String)
    case transport(String)
    case noPages

    var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return message.isEmpty ? L10n.t("scout.error.key") : L10n.t("scout.error.key") + " (" + message + ")"
        case .rateLimited: return L10n.t("scout.error.rate")
        case .modelUnavailable, .noModel: return L10n.t("scout.error.noModel")
        case .api(let code, let message):
            return message.isEmpty ? "Gemini HTTP \(String(code))" : "Gemini \(String(code)): \(message)"
        case .transport(let message): return message
        case .noPages: return L10n.t("scout.error.noPages")
        }
    }

    /// Worth stopping the whole scan for: it will go the same way for every conference.
    var isFatal: Bool {
        switch self {
        case .unauthorized, .rateLimited, .noModel: return true
        default: return false
        }
    }

    private static func retryDelay(in raw: String) -> TimeInterval? {
        for pattern in [#"retry in ([0-9.]+)s"#, #""retryDelay"\s*:\s*"([0-9.]+)s""#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            return TimeInterval(raw[range])
        }
        return nil
    }

    /// Google's error body says what went wrong far better than the status code does.
    init(status: Int, body: Data) {
        let raw = String(data: body, encoding: .utf8) ?? ""
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = String(((error?["message"] as? String) ?? "").prefix(200))
        switch status {
        case 404: self = .modelUnavailable
        case 401, 403: self = .unauthorized(message)
        case 429:
            // Each model has its own daily quota, so a spent day moves on to the next
            // model; a spent minute is waited out.
            self = raw.contains("PerDay") ? .modelUnavailable : .rateLimited(ScoutError.retryDelay(in: raw))
        case 400 where raw.contains("API_KEY_INVALID"): self = .unauthorized(message)
        default: self = .api(status, message)
        }
    }
}

/// The model a scan is using, shared by the conferences being read at the same time.
///
/// Starts from `GeminiScout.preferredModels`. A 404 drops that name for every request,
/// so three in flight do not each rediscover it. When the list runs out, the key's own
/// model list is asked -- once -- for Flash models it can still call.
actor ModelPicker {
    private let key: String
    private var candidates: [String]
    private var tried: Set<String> = []
    private var discovery: Task<[String], Never>?
    private(set) var working: String?

    init(key: String) {
        self.key = key
        self.candidates = GeminiScout.preferredModels
    }

    func current() async -> String? {
        if let first = candidates.first { return first }
        let task: Task<[String], Never>
        if let existing = discovery {
            task = existing
        } else {
            let key = self.key
            task = Task { await GeminiScout.listFlashModels(key: key) }
            discovery = task
        }
        let listed = await task.value
        candidates = listed.filter { !tried.contains($0) }
        return candidates.first
    }

    func drop(_ model: String) {
        tried.insert(model)
        candidates.removeAll { $0 == model }
        if working == model { working = nil }
    }

    /// The free tier allows 15 requests a minute per model. Slots go out 60/14 s apart
    /// to every request in flight, so a full scan stays under it instead of running
    /// into it and stopping halfway.
    private var nextSlot = Date.distantPast
    private static let slotInterval: TimeInterval = 60.0 / 14.0

    func waitForSlot() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(ModelPicker.slotInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    /// Google said how long to wait; nobody asks again before then.
    func backOff(_ seconds: TimeInterval) {
        nextSlot = max(nextSlot, Date().addingTimeInterval(seconds))
    }

    func confirm(_ model: String) {
        if working == nil { working = model }
    }
}

/// Reads each conference's own pages and asks Gemini what the schedule says now.
///
/// The same rule as the repository's weekly job: a date is only ever proposed when
/// its `sourceUrl` is a page we actually fetched **and** the date is legible in that
/// page's text. Everything else is dropped, so the model cannot invent a deadline.
enum GeminiScout {
    static let apiBase = "https://generativelanguage.googleapis.com/v1beta"

    /// Tried in order until one answers. Flash-Lite first: reading a few pages for dates
    /// is well within it, and its free-tier limits leave room for fifty conferences in a
    /// row. The `-latest` aliases follow Google's releases; the pinned names cover a key
    /// or a moment where an alias is missing. No 2.5 model: Google now serves those only
    /// to keys that used them before, so a key made today gets a 404 for them.
    static let preferredModels = [
        "gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite",
        "gemini-flash-latest", "gemini-3.6-flash", "gemini-3.8-flash",
    ]
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

    struct ScanResult {
        let proposals: [DeadlineProposal]
        /// The first error, or the one that stopped the scan.
        let failure: String?
        /// The model that answered, when one did.
        let model: String?
        /// Conferences the model actually answered for.
        let answered: Int
        /// Conferences skipped because none of their pages could be read.
        let unreadable: Int
    }

    private enum Outcome {
        case answered([DeadlineProposal])
        case unreadable
        case failed(ScoutError)
        case cancelled
    }

    static func scan(conferences: [Conference],
                     key: String,
                     progress: (Int, Int) -> Void) async -> ScanResult {
        let now = Date()
        // A conference whose every deadline has passed cannot tell us anything useful.
        let targets = conferences.filter { conf in
            conf.deadlines.contains { d in
                guard let parsed = DateHelper.parse(d.date) else { return false }
                return parsed > now
            }
        }.sorted { $0.name < $1.name }

        let total = targets.count
        let models = ModelPicker(key: key)
        var found: [DeadlineProposal] = []
        var failure: String?
        var answered = 0
        var unreadable = 0
        var completed = 0

        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let slice = Array(targets[index..<min(index + concurrency, targets.count)])
            index += slice.count

            let batch: [Outcome] = await withTaskGroup(of: Outcome.self) { group in
                for conf in slice {
                    group.addTask { await inspect(conference: conf, key: key, models: models) }
                }
                var out: [Outcome] = []
                for await outcome in group { out.append(outcome) }
                return out
            }

            var fatal = false
            for outcome in batch {
                switch outcome {
                case .answered(let proposals):
                    answered += 1
                    found.append(contentsOf: proposals)
                case .unreadable:
                    unreadable += 1
                case .failed(let error):
                    // Keep the first error, unless a later one is the reason we stop.
                    if failure == nil || error.isFatal { failure = error.localizedDescription }
                    fatal = fatal || error.isFatal
                case .cancelled:
                    break
                }
            }
            completed += slice.count
            progress(completed, total)
            if fatal { break }
        }

        let sorted = found.sorted { ($0.conferenceName, $0.date) < ($1.conferenceName, $1.date) }
        return ScanResult(proposals: sorted, failure: failure, model: await models.working,
                          answered: answered, unreadable: unreadable)
    }

    private static func inspect(conference: Conference, key: String, models: ModelPicker) async -> Outcome {
        var pages: [String: String] = [:]
        for url in sourceURLs(for: conference).prefix(maxPagesPerConference) {
            if Task.isCancelled { return .cancelled }
            if let text = await fetch(url) { pages[url.absoluteString] = text }
        }
        guard !pages.isEmpty else { return .unreadable }

        var waits = 0
        while let model = await models.current() {
            await models.waitForSlot()
            if Task.isCancelled { return .cancelled }
            do {
                let reported = try await ask(model: model, key: key, conference: conference, pages: pages)
                await models.confirm(model)
                return .answered(proposals(from: reported, conference: conference, pages: pages))
            } catch ScoutError.modelUnavailable {
                await models.drop(model)
            } catch ScoutError.rateLimited(let delay) where waits < 4 {
                waits += 1
                await models.backOff(min((delay ?? 30) + 1, 90))
            } catch let error as ScoutError {
                return .failed(error)
            } catch {
                if Task.isCancelled { return .cancelled }
                return .failed(.transport(error.localizedDescription))
            }
        }
        return .failed(.noModel)
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

    /// The Flash models this key can call, Lite first and newest first within each --
    /// the fallback for the day every name in `preferredModels` has been retired.
    static func listFlashModels(key: String) async -> [String] {
        guard let url = URL(string: apiBase + "/models?pageSize=1000") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = root["models"] as? [[String: Any]] else { return [] }

        let excluded = ["preview", "exp", "image", "tts", "live", "audio", "embedding", "thinking", "native"]
        let names: [String] = listed.compactMap { entry in
            guard let full = entry["name"] as? String,
                  let methods = entry["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            let name = full.hasPrefix("models/") ? String(full.dropFirst(7)) : full
            guard name.hasPrefix("gemini-"), name.contains("flash"),
                  !name.hasPrefix("gemini-1."), !name.hasPrefix("gemini-2."),
                  !excluded.contains(where: { name.contains($0) }) else { return nil }
            return name
        }
        return names.sorted { a, b in
            let (liteA, liteB) = (a.contains("lite"), b.contains("lite"))
            if liteA != liteB { return liteA }
            return a.compare(b, options: .numeric) == .orderedDescending
        }
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

    private static func ask(model: String, key: String, conference: Conference,
                            pages: [String: String]) async throws -> [[String: Any]] {
        guard let url = URL(string: "\(apiBase)/models/\(model):generateContent") else {
            throw ScoutError.modelUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a query parameter, so the key stays out of URLs and logs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        // No temperature and no output cap. Google advises leaving temperature alone on
        // the 3.x models, which are tuned for the default, and a cap can be spent on
        // thinking before any JSON is written. The answer is a few hundred tokens anyway.
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt(conference: conference, pages: pages)]]]],
            "generationConfig": ["responseMimeType": "application/json"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScoutError(status: http.statusCode, body: data)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return [] }
        // A thinking model may hand back its reasoning as parts of its own; only the
        // answer is JSON.
        let text = parts.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()

        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Models sometimes leave a comma before a closing brace, which JSON forbids.
        let repaired = json.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                ?? (try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]),
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
        - Report only dates of the \(String(conference.year)) edition. The pages may describe another edition, most often the previous one; if so, report none of that edition's dates.
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
                ?? conference.deadlines.first {
                    $0.type == type && $0.date.prefix(10) == date.prefix(10) && sameWords($0.label, label)
                }
                ?? conference.deadlines.first { candidate in
                    guard candidate.type == type, candidate.estimated,
                          let a = DateHelper.parse(candidate.date), let b = DateHelper.parse(date) else { return false }
                    return abs(a.timeIntervalSince(b)) < 45 * 86_400
                }

            // Printed on the page is not enough: the page may be another edition's.
            guard fitsEdition(date, type: type, year: conference.year, replacing: existing?.date) else { continue }

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

    /// Whether `date` can belong to the `year` edition.
    ///
    /// An entry for next year's edition cites last year's pages until the new site
    /// exists, and a date read from those is real, legible and wrong -- how 3DV 2028 and
    /// AAAI 2028 once took their 2027 dates as "confirmed". A `year` edition's dates fall
    /// between January of `year - 1` and the January after it; the conference itself is
    /// in `year`; and a real schedule change never moves a date by half a year. (Dates
    /// already in the past are dropped before this, which covers moving one backwards.)
    static func fitsEdition(_ date: String, type: String, year: Int, replacing old: String?) -> Bool {
        guard year > 0 else { return true }
        let day = String(date.prefix(10))
        if type == "conference" {
            guard day.hasPrefix(String(year)) else { return false }
        } else {
            guard day >= "\(String(year - 1))-01-01", day <= "\(String(year + 1))-01-31" else { return false }
        }
        if let old, let a = DateHelper.parse(old), let b = DateHelper.parse(date),
           abs(a.timeIntervalSince(b)) > 180 * 86_400 {
            return false
        }
        return true
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
        if spellings.contains(where: { containsStandalone(haystack, $0.lowercased()) }) { return true }

        // Day-first ranges ("16-21 May 2027"), ordinals ("16th May", "May 16th") and
        // "Sept": how conferences write their own dates, and why every main conference --
        // nearly always a range -- used to come back as not printed.
        var names = [name.lowercased(), abbr.lowercased() + #"\.?"#]
        if month == 9 { names.append(#"sept\.?"#) }
        let monthPattern = "(?:" + names.joined(separator: "|") + ")"
        let ordinal = "(?:st|nd|rd|th)?"
        let dash = "[-\u{2013}\u{2014}]"
        // One literal each: a long chain of `+` is what makes Swift give up type-checking.
        let dayFirst = #"(?<!\d)0?\#(day)\#(ordinal)(?:\s*\#(dash)\s*\d{1,2}\#(ordinal))?\s+(?:of\s+)?\#(monthPattern)(?![a-z])"#
        let monthFirst = #"(?<![a-z])\#(monthPattern)\s+0?\#(day)\#(ordinal)(?!\d)"#
        return [dayFirst, monthFirst].contains { haystack.range(of: $0, options: .regularExpression) != nil }
    }

    private static let ordinalWords: Set<String> = ["first", "second", "third", "fourth", "fifth",
                                                    "1st", "2nd", "3rd", "4th", "5th"]

    /// Round and cycle numbers, not years: "AAMAS 2027 Early Registration" is still
    /// "Early Registration".
    private static func markers(in words: Set<String>) -> Set<String> {
        words.filter { ordinalWords.contains($0) || ($0.count <= 2 && $0.allSatisfy(\.isNumber)) }
    }

    private static let labelNoise: Set<String> = ["the", "of", "and", "for", "a", "an", "deadline", "date", "dates", "due"]

    /// Labels made of mostly the same words: the model rewording a milestone from one
    /// scan to the next ("Abstract Submission (Blue Sky Ideas)", "Blue Sky Ideas
    /// Abstract Submission"), which should not come back as a new deadline.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        // Plural-blind too: "Tutorials Proposal Deadline" is "Tutorial Proposal Deadline".
        func singular(_ word: String) -> String {
            word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        }
        func words(_ label: String) -> Set<String> {
            let raw = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return Set(raw.filter { !labelNoise.contains($0) }.map(singular))
        }
        let (wa, wb) = (words(a), words(b))
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        // "Round 1" and "Round 2", "First Cycle" and "Second Cycle" are different
        // milestones however much else their labels share.
        guard markers(in: wa) == markers(in: wb) else { return false }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count) >= 0.6
    }

    /// True when `needle` occurs with no digit touching either end. A plain substring
    /// test let "october 1" match inside "october 15" and "1 oct" inside "21 oct",
    /// which for the first three days of every month quietly disabled the guard.
    static func containsStandalone(_ haystack: String, _ needle: String) -> Bool {
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let range = haystack.range(of: needle, range: from..<haystack.endIndex) {
            let before: Character? = range.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: range.lowerBound)] : nil
            let after: Character? = range.upperBound < haystack.endIndex
                ? haystack[range.upperBound] : nil
            if !(before?.isNumber ?? false) && !(after?.isNumber ?? false) { return true }
            from = haystack.index(after: range.lowerBound)
        }
        return false
    }
}
