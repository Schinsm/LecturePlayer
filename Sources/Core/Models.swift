import Foundation
import CryptoKit

public struct Course: Codable, Identifiable, Equatable, Sendable {
    public var directoryPath: String?
    public var id = UUID(); public var name: String; public var semester = ""; public var color = "blue"; public var order = 0; public var archived = false; public var glossary = "NPV=净现值\nFCF=自由现金流\nWACC=加权平均资本成本\nYTM=到期收益率"
    public init(name: String, order: Int = 0) { self.name = name; self.order = order }
}
public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var directoryPath: String?
    public var id = UUID(); public var courseID: UUID; public var parentID: UUID?; public var name: String; public var order = 0
    public init(name: String, courseID: UUID, parentID: UUID? = nil) { self.name = name; self.courseID = courseID; self.parentID = parentID }
}
public struct Mark: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(); public var seconds: Double; public var note: String
    public init(seconds: Double, note: String) { self.seconds = seconds; self.note = note }
}
public struct PlaybackState: Codable, Equatable, Sendable {
    public var position = 0.0; public var speed = 1.0; public var mode = "双语"; public var offset = 0.0; public var lastVisit: Date?
    // Keep the 0.2 Codable key "offset" for existing databases and backups.
    public var subtitleOffsetSeconds: Double {
        get { offset }
        set { if newValue.isFinite { offset = newValue } }
    }
    public var timingMapper: SubtitleTimingMapper { SubtitleTimingMapper(offset: subtitleOffsetSeconds) }
    public init() {}
    public mutating func record(_ seconds: Double, ready: Bool) { guard ready, seconds.isFinite, seconds >= 0 else { return }; position = seconds; lastVisit = Date() }
}
public struct Lecture: Codable, Identifiable, Equatable, Sendable {
    public var videoCaptions: VideoCaptionPreferences?
    public var readingGrouped: Bool?
    public var studyPanel: String?
    public var selectedTranslationVariantID: String?
    public var directoryChoice: String?
    public var subtitlePath: String?; public var subtitleBookmark: Data?; public var directoryPath: String?
    public var sidecars: [String: String]?; public var sidecarStatus: String?
    public var generatedFilePaths:[String]?
    public var id = UUID(); public var courseID: UUID; public var folderID: UUID?; public var title: String; public var path: String; public var bookmark: Data?; public var identity: String; public var transcriptVersion: String?; public var state = PlaybackState(); public var duration = 0.0; public var finished = false; public var marks: [Mark] = []
    public var week: Int?; public var sessionType: String?; public var topic: String?; public var customTitle: Bool?
    public var sources: [MediaSource]?; public var layout: VideoLayout?; public var swapped: Bool?; public var audioSourceID: UUID?; public var archived: Bool?
    public init(title: String, courseID: UUID, folderID: UUID?, url: URL, bookmark: Data?, identity: String) { self.title = title; self.courseID = courseID; self.folderID = folderID; self.path = url.path; self.bookmark = bookmark; self.identity = identity }
}
public struct Library: Codable, Equatable, Sendable {
    public var directoryRoot: String?; public var directoryBookmark: Data?
    public var schema = 5; public var courses: [Course] = []; public var folders: [Folder] = []; public var lectures: [Lecture] = []; public var lastLecture: UUID?
    public init() {}
    public func validate() throws {
        guard schema == 5 else { throw Failure("不支持的资料库版本 \(schema)") }
        guard Set(courses.map(\.id)).count == courses.count, Set(folders.map(\.id)).count == folders.count, Set(lectures.map(\.id)).count == lectures.count else { throw Failure("重复的资料 ID") }
        for folder in folders { guard courses.contains(where: { $0.id == folder.courseID }) else { throw Failure("目录的课程不存在") }; try checkMove(folder.id, to: folder.parentID) }
        for lecture in lectures {
            guard lecture.week == nil || (1...99).contains(lecture.week!), (1...2).contains(lecture.mediaSources.count), Set(lecture.mediaSources.map(\.id)).count == lecture.mediaSources.count, Set(lecture.mediaSources.map(\.role)).count == lecture.mediaSources.count, lecture.mediaSources.allSatisfy({ $0.relativeOffset.isFinite && abs($0.relativeOffset) <= 86400 && !$0.originalFilename.isEmpty && $0.originalFilename != "." && $0.originalFilename != ".." && !$0.originalFilename.contains("/") }) else { throw Failure("课程标记或媒体来源无效") }
            guard courses.contains(where: { $0.id == lecture.courseID }), lecture.folderID == nil || folders.contains(where: { $0.id == lecture.folderID && $0.courseID == lecture.courseID }), lecture.state.position.isFinite, lecture.state.position >= 0, lecture.state.offset.isFinite, [0.75,1,1.25,1.5,1.75,2,2.5].contains(lecture.state.speed) else { throw Failure("回放关系或进度无效") }
        }
    }
    public func checkMove(_ id: UUID, to parent: UUID?) throws {
        guard let source = folders.first(where: { $0.id == id }) else { throw Failure("目录不存在") }
        var cursor = parent; var visited: Set<UUID> = [id]
        while let current = cursor {
            guard visited.insert(current).inserted else { throw Failure("不能把目录移动到自身或子目录") }
            guard let folder = folders.first(where: { $0.id == current }), folder.courseID == source.courseID else { throw Failure("目标目录无效") }; cursor = folder.parentID
        }
    }
}
public struct Failure: LocalizedError, Sendable { public let message: String; public init(_ message: String) { self.message = message }; public var errorDescription: String? { message } }
public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func digest(_ string: String) -> String { digest(Data(string.utf8)) }
public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}
