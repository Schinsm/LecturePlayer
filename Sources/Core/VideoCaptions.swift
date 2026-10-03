import Foundation

public struct VideoCaptionPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var mode = "双语"
    public var fontSize = 22.0
    public var position: String? = nil
    public var margin: Double? = nil
    public var transparency: Double? = nil
    public var grouped: Bool? = nil
    public init() {}
}

public struct VideoCaptionLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var english: String?
    public var chinese: String?
    public static func make(cues: [Cue], activeIDs: [String], translations: [String:Translation], mode: String) -> [VideoCaptionLine] {
        let active = Set(activeIDs)
        return cues.filter { active.contains($0.id) }.map { cue in
            let zh = translations[cue.id]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = zh?.isEmpty == false
            return VideoCaptionLine(id: cue.id, english: mode == "中文" && available ? nil : cue.en,
                                    chinese: mode == "英文" || !available ? nil : zh)
        }
    }
}
