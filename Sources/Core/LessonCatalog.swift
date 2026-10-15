import Foundation

/// Kind of class session, inferred when the library does not say.
public enum SessionKind: String, CaseIterable, Codable, Sendable {
    case lecture = "Lecture", seminar = "Seminar", tutorial = "Tutorial", practice = "Practice"
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Lessons of one week (or of no known week) and the items shown for them.
public struct WeekSection: Identifiable, Equatable, Sendable {
    public var week: Int?
    public var groups: [LessonGroup]
    public var id: String { week.map { "week-\($0)" } ?? "week-none" }
    public var lessons: [Lecture] { groups.flatMap(\.lessons) }
}

/// One row on a home or course page: a single lesson, or a series such as Lecture 9.1–9.4 stacked together.
public struct LessonGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var courseID: UUID
    public var week: Int?
    public var kind: SessionKind
    public var lessons: [Lecture]
    public var isSeries: Bool { lessons.count > 1 }
    public var watchedCount: Int { lessons.filter(LessonCatalog.isWatched).count }
    /// The part to continue with: the first one not watched yet, else the last one.
    public var next: Lecture? { lessons.first { !LessonCatalog.isWatched($0) } ?? lessons.last }
    /// "9.3" for numbered parts such as Lecture 9.3; otherwise its position, "第 2 段".
    public func partLabel(_ lesson: Lecture) -> String {
        if let number = title.split(separator: " ").last.flatMap({ Int($0) }),
           let part = LessonCatalog.seriesPart(lesson.title), lesson.title.contains("\(number).\(part.part)") {
            return "\(number).\(part.part)"
        }
        return "第 \((lessons.firstIndex { $0.id == lesson.id } ?? 0) + 1) 段"
    }
    /// "9.1–9.4" for numbered parts, nil otherwise.
    public var partRange: String? {
        guard let first = lessons.first, let last = lessons.last else { return nil }
        let a = partLabel(first), b = partLabel(last)
        return a.hasPrefix("第") ? nil : a + "–" + b
    }
}

/// Week, session kind and series inferred from what the library already records:
/// the explicit fields first, then the folder layout (".../Week9/Lecture"), then the title.
/// Nothing here is written back; it only decides how lessons are grouped on screen.
public enum LessonCatalog {
    public static func week(_ lesson: Lecture) -> Int? {
        if let week = lesson.week { return week }
        if let path = lesson.directoryPath, let week = lastWeek(in: path) { return week }
        return firstMatch(#"(?i)\bweek\s*0*(\d{1,2})\b"#, in: lesson.title).flatMap { Int($0[1]) }
    }

    public static func kind(_ lesson: Lecture) -> SessionKind {
        // "Lecture" is what import records by default, so only another stored value is a real choice.
        if let stored = lesson.sessionType, let kind = SessionKind(rawValue: stored), kind != .lecture { return kind }
        if let kind = kind(in: lesson.title) { return kind }
        let folders = (lesson.directoryPath ?? "").split(separator: "/").reversed()
        for folder in folders { if let kind = kind(in: String(folder)) { return kind } }
        return .lecture
    }

    /// "Lecture 9.3" → ("Lecture 9", 3); "Week 10 Tutorial with Amir Q 3-4 - Dividend Policy" →
    /// ("Week 10 Tutorial with Amir - Dividend Policy", 3); "Part 2" likewise. Nil when the title has no part number.
    public static func seriesPart(_ title: String) -> (stem: String, part: Int)? {
        if let m = firstMatch(#"^(.*?[A-Za-z][^0-9]*?\d+)\.(\d+)\b"#, in: title), let part = Int(m[2]) {
            return (tidy(m[1]), part)
        }
        for pattern in [#"(?i)\bQ\s*(\d+)(?:\s*[-–]\s*\d+)?\b"#, #"(?i)\b(?:Part|Pt\.?)\s*(\d+)\b"#] {
            guard let range = title.range(of: pattern, options: .regularExpression),
                  let m = firstMatch(pattern, in: title), let part = Int(m[1]) else { continue }
            var stem = title; stem.removeSubrange(range)
            return (tidy(stem), part)
        }
        return nil
    }

    /// Lecture-capture exports are named like "FNCE90018_2026_SM2 W-s1-full"; show them as "Week 10 录像".
    /// Titles the user typed, and every other title, are shown as they are.
    public static func displayTitle(_ lesson: Lecture) -> String {
        let shown = lesson.displayTitle
        guard shown == lesson.title, isCaptureName(lesson.title) else { return shown }
        let kind = kind(lesson)
        let name = kind == .lecture ? "录像" : kind.rawValue + " 录像"
        return week(lesson).map { "Week \($0) " + name } ?? name
    }
    public static func isCaptureName(_ title: String) -> Bool {
        title.range(of: #"^[A-Z]{3,5}\d{4,6}_\d{4}_[A-Z0-9]+\s+[A-Z]-s\d+-full$"#, options: .regularExpression) != nil
    }

    public static func isWatched(_ lesson: Lecture) -> Bool {
        lesson.finished || (lesson.duration > 0 && lesson.state.position >= lesson.duration * 0.95)
    }

    /// Groups lessons into series. Lessons share a series when course, week, kind and title stem match;
    /// a stem with a single lesson stays a plain row.
    public static func groups(_ lessons: [Lecture]) -> [LessonGroup] {
        var buckets: [String: [(Int, Lecture)]] = [:], order: [String] = []
        for lesson in lessons {
            let week = week(lesson), kind = kind(lesson)
            let key: String
            let part: Int
            if let series = seriesPart(lesson.title) {
                key = "\(lesson.courseID)|\(week.map(String.init) ?? "-")|\(kind.rawValue)|\(series.stem.lowercased())"
                part = series.part
            } else { key = "lesson|\(lesson.id)"; part = 0 }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append((part, lesson))
        }
        var result: [LessonGroup] = []
        for key in order {
            let members = buckets[key]!.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.title.localizedStandardCompare($1.1.title) == .orderedAscending }.map(\.1)
            let first = members[0]
            if members.count > 1, let stem = seriesPart(first.title)?.stem {
                result.append(LessonGroup(id: "series|" + key, title: stem, courseID: first.courseID, week: week(first), kind: kind(first), lessons: members))
            } else {
                // A stem shared by one lesson only is not a series; keep the lesson's own title.
                for lesson in members {
                    result.append(LessonGroup(id: "lesson|\(lesson.id)", title: lesson.title, courseID: lesson.courseID, week: week(lesson), kind: kind(lesson), lessons: [lesson]))
                }
            }
        }
        return result.sorted {
            $0.kind.order != $1.kind.order ? $0.kind.order < $1.kind.order : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Newest week first; lessons without a known week come last.
    public static func sections(_ lessons: [Lecture]) -> [WeekSection] {
        let byWeek = Dictionary(grouping: lessons, by: week)
        return byWeek.keys.sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }.map { WeekSection(week: $0, groups: groups(byWeek[$0]!)) }
    }

    private static func lastWeek(in path: String) -> Int? {
        for folder in path.split(separator: "/").reversed() {
            if let m = firstMatch(#"(?i)^week\s*0*(\d{1,2})$"#, in: String(folder)), let week = Int(m[1]) { return week }
        }
        return nil
    }
    private static func kind(in text: String) -> SessionKind? {
        let lower = text.lowercased()
        if lower.contains("tutorial") { return .tutorial }
        if lower.contains("seminar") { return .seminar }
        if lower.contains("practice") || lower.contains("quiz") || lower.contains("workshop") { return .practice }
        if lower.contains("lecture") { return .lecture }
        return nil
    }
    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+([-–])\s+(?=[-–]|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
    }
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
