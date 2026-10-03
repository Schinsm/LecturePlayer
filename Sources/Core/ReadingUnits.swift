import Foundation

public enum SpeakerLabel {
    private static let pattern = #"(?im)^\s*(?:speaker|说话人|演讲者|发言人|说话者|讲话者|讲者)\s*(\d+)\s*[:：]\s*"#
    private static let expression = try! NSRegularExpression(pattern: pattern)
    public static func clean(_ text: String, hide: Bool = true) -> String {
        hide ? expression.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"") : text
    }
    // Only treat mistranslated equipment labels as metadata when the source has a speaker marker.
    private static let translatedExpression = try! NSRegularExpression(pattern: #"(?im)(?:^|(?<=\s))(?:speaker|说话人|演讲者|发言人|说话者|讲话者|讲者|扬声器)\s*\d+\s*[:：]\s*"#)
    public static func cleanTranslation(_ text:String,source:String,hide:Bool=true)->String {
        guard hide else{return text}
        guard identity(source) != nil else{return clean(text)}
        return translatedExpression.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"")
    }
    public static func identity(_ text: String) -> String? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
public struct ReadingSpan: Equatable, Sendable {
    public var cueID: String
    public var range: NSRange
}
public struct ReadingText: Equatable, Sendable {
    public var text: String
    public var spans: [ReadingSpan]
    public func cue(atUTF16 index: Int) -> String? {
        spans.first { NSLocationInRange(index, $0.range) }?.cueID
    }
}
public struct TranscriptReadingUnit: Identifiable, Equatable, Sendable {
    public var cues: [Cue]
    public var id: String { cues[0].id }
    public var ids: [String] { cues.map(\.id) }
    public func content(translations: [String:Translation], mode: String, hideSpeakers: Bool = true) -> ReadingText {
        var text = "", spans: [ReadingSpan] = []
        func append(_ value: String, cue: Cue, separator: String, translated:Bool=false) {
            if !text.isEmpty { text += separator }
            let start = (text as NSString).length
            text += !translated ? SpeakerLabel.clean(value,hide:hideSpeakers) : SpeakerLabel.cleanTranslation(value,source:cue.en,hide:hideSpeakers)
            spans.append(ReadingSpan(cueID: cue.id, range: NSRange(location: start, length: (text as NSString).length-start)))
        }
        if mode != "中文" { for cue in cues { append(cue.en, cue: cue, separator: " ") } }
        if mode != "英文" {
            for (i,cue) in cues.enumerated() {
                let value = translations[cue.id]?.text ?? (mode == "中文" ? cue.en : "[此片段未翻译]")
                append(value, cue: cue, separator: i == 0 && mode != "中文" ? "\n" : " ",translated:translations[cue.id] != nil)
            }
        }
        return ReadingText(text: text, spans: spans)
    }
}
public enum ReadingUnits {
    public static func sentenceEnds(_ raw: String) -> Bool {
        let text = SpeakerLabel.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”)]}"))
        let lower = text.lowercased()
        if ["mr.","mrs.","ms.","dr.","prof.","e.g.","i.e.","vs.","etc.","u.s.","u.k."].contains(where: { lower.hasSuffix($0) }) { return false }
        return text.range(of: #"[.!?。！？]$"#, options: .regularExpression) != nil
    }
    public static func make(_ cues: [Cue], grouped: Bool = true, video: Bool = false) -> [TranscriptReadingUnit] {
        guard grouped else { return cues.map { TranscriptReadingUnit(cues: [$0]) } }
        var result: [TranscriptReadingUnit] = [], current: [Cue] = [], words = 0
        for cue in cues {
            let count = SpeakerLabel.clean(cue.en).split(whereSeparator: \.isWhitespace).count
            if let previous = current.last, let first = current.first {
                let gap = cue.start-previous.end
                let stop = gap < 0 || gap > 800 || sentenceEnds(previous.en)
                    || SpeakerLabel.identity(previous.en) != SpeakerLabel.identity(cue.en)
                    || current.count >= (video ? 3 : 8) || cue.end-first.start > (video ? 12000 : 30000)
                    || words+count > (video ? 24 : 80)
                if stop { result.append(TranscriptReadingUnit(cues: current)); current = []; words = 0 }
            }
            current.append(cue); words += count
        }
        if !current.isEmpty { result.append(TranscriptReadingUnit(cues: current)) }
        return result
    }
}
public enum ReadingSearch {
    public static func matches(_ units: [TranscriptReadingUnit], translations: [String:Translation], query: String, hideSpeakers: Bool = true) -> Set<String> {
        guard !query.isEmpty else {return []}
        var ids = Set<String>()
        for unit in units {
            let content = unit.content(translations: translations, mode: "双语", hideSpeakers: hideSpeakers)
            let text = content.text as NSString
            var range = NSRange(location: 0, length: text.length)
            while range.length > 0 {
                let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard found.location != NSNotFound else {break}
                for span in content.spans where NSIntersectionRange(span.range, found).length > 0 {ids.insert(span.cueID)}
                let next = found.location + max(1,found.length)
                range = NSRange(location: next, length: text.length-next)
            }
        }
        return ids
    }
}
