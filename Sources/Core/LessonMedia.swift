import Foundation

public enum MediaRole: String, Codable, CaseIterable, Sendable { case screen = "屏幕", camera = "摄像头" }
public enum VideoLayout: String, Codable, CaseIterable, Sendable { case screen = "屏幕单看", camera = "摄像头单看", horizontal = "左右并排", vertical = "上下排列", inset = "画中画" }
public struct MediaSource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: MediaRole
    public var path: String
    public var bookmark: Data?
    public var contentHash: String?
    public var identity: String
    public var originalFilename: String
    public var managed: Bool
    public var relativeOffset: Double
    public init(id: UUID = UUID(), role: MediaRole = .screen, path: String, bookmark: Data? = nil, identity: String = "", managed: Bool = false, relativeOffset: Double = 0) {
        self.id = id; self.role = role; self.path = path; self.bookmark = bookmark; self.identity = identity
        self.originalFilename = URL(fileURLWithPath: path).lastPathComponent; self.managed = managed; self.relativeOffset = relativeOffset
    }
}
extension Lecture {
    public var displayTitle: String {
        if customTitle != false { return title }
        let parts = [week.map { String(format: "Week %02d", $0) }, sessionType?.isEmpty == false ? sessionType : nil, topic?.isEmpty == false ? topic : title].compactMap { $0 }
        return parts.isEmpty ? title : parts.joined(separator: " · ")
    }
    public var mediaSources: [MediaSource] {
        get { sources ?? [MediaSource(id: id, path: path, bookmark: bookmark, identity: identity)] }
        set { sources = newValue; if let first = newValue.first { path = first.path; bookmark = first.bookmark; identity = first.identity } }
    }
    public func matches(week: Int?, type: String?) -> Bool { (week == nil || self.week == week) && (type == nil || sessionType == type) }
}
public enum LibraryMigration {
    public static func upgrade(_ source: Library) throws -> Library {
        guard source.schema == 1 || source.schema == 2 || source.schema == 3 || source.schema == 4 || source.schema == 5 else { throw Failure("不支持的资料库版本 \(source.schema)") }
        var result = source
        if result.schema == 1 {
            for i in result.lectures.indices { result.lectures[i].sources = result.lectures[i].mediaSources }
            result.schema = 2
        }
        result.schema = 5
        try result.validate(); return result
    }
}
