import Foundation
import CryptoKit
import Darwin

public struct IndexedMedia: Sendable {
    public var url: URL; public var identity: String; public var hash: String?
    public init(url: URL, identity: String, hash: String? = nil) { self.url = url; self.identity = identity; self.hash = hash }
}
public enum DirectoryIndex {
    public static func canonical(_ url: URL) -> URL {
        let resolved: String? = url.withUnsafeFileSystemRepresentation { input in
            guard let input, let output = realpath(input, nil) else { return nil }
            defer { free(output) }; return String(cString: output)
        }
        if let resolved { return URL(fileURLWithPath: resolved) }
        guard url.path != "/" else { return url }
        return canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }
    public static func identity(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? "")"
    }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func relativeDirectory(_ url: URL, root: URL) -> [String]? {
        let parent = canonical(url).deletingLastPathComponent().pathComponents, base = canonical(root).pathComponents
        guard parent.starts(with: base), parent.count > base.count else { return nil }
        return Array(parent.dropFirst(base.count))
    }
    public static func classify(_ lesson: inout Lecture, root: URL, library: inout Library) {
        guard let parts = relativeDirectory(URL(fileURLWithPath: lesson.path), root: root), let name = parts.first else { lesson.directoryPath = nil; return }
        let coursePath = canonical(root).appendingPathComponent(name).path
        let courseID: UUID
        if let existing = library.courses.first(where: { $0.directoryPath == coursePath }) { courseID = existing.id }
        else if library.courses.filter({ $0.directoryPath == nil && $0.name == name }).count == 1,
                let index = library.courses.firstIndex(where: { $0.directoryPath == nil && $0.name == name }) {
            library.courses[index].directoryPath = coursePath; courseID = library.courses[index].id
        }
        else { var course = Course(name: name); course.directoryPath = coursePath; library.courses.append(course); courseID = course.id }
        var parent: UUID?; var directory = URL(fileURLWithPath: coursePath)
        for part in parts.dropFirst() {
            directory.appendPathComponent(part)
            if let existing = library.folders.first(where: { $0.directoryPath == directory.path }) { parent = existing.id }
            else { var folder = Folder(name: part, courseID: courseID, parentID: parent); folder.directoryPath = directory.path; library.folders.append(folder); parent = folder.id }
        }
        lesson.courseID = courseID; lesson.folderID = parent; lesson.directoryPath = directory.path
    }
    /// Ambiguous identical copies never silently rebind an existing lesson.
    public static func match(_ source: MediaSource, files: [IndexedMedia]) -> IndexedMedia? {
        let same = files.filter { $0.identity == source.identity }
        if same.count == 1 { return same[0] }
        if same.count > 1 { return nil }
        guard let hash = source.contentHash else { return nil }
        let copies = files.filter { $0.hash == hash }
        return copies.count == 1 ? copies[0] : nil
    }
}

public enum SidecarWriter {
    /// Only overwrites bytes previously written by us. Edited or unknown files get a new version.
    public static func write(_ transcript: Transcript, lesson: Lecture, beside subtitle: URL, hideSpeakers: Bool = false) throws -> [String: String] {
        guard transcript.translatedCount > 0 else { return lesson.sidecars ?? [:] }
        guard let media=lesson.mediaSources.first(where:{$0.role == .screen}) ?? (lesson.mediaSources.count==1 ? lesson.mediaSources.first : nil) else{throw Failure("无法确定译文保存的视频目录")}
        let directory=URL(fileURLWithPath:media.path).deletingLastPathComponent()
        let stem = subtitle.deletingPathExtension().lastPathComponent + ".lectureplayer-" + lesson.id.uuidString.prefix(8) + "-" + transcript.version.prefix(8) + "." + transcript.variantID.lowercased()
        var results = (lesson.sidecars ?? [:]).filter { FileManager.default.fileExists(atPath: $0.key) }
        for (suffix, kind) in [("zh.vtt", ExportKind.chineseVTT), ("bilingual.md", .markdown)] {
            let data = try Exporter.render(transcript, kind: kind, translatedOnly: kind == .chineseVTT, marks: lesson.marks, hideSpeakers: hideSpeakers, grouped: lesson.readingGrouped ?? true)
            let desiredHash = digest(data)
            let base = directory.appendingPathComponent(stem + "." + suffix)
            var target = base
            if let existing = try? Data(contentsOf: target) {
                if digest(existing) == desiredHash { results[target.path] = desiredHash; continue }
                if results[target.path] != digest(existing) { target = directory.appendingPathComponent(stem + "." + desiredHash.prefix(12) + "." + suffix) }
            }
            if FileManager.default.fileExists(atPath: target.path) {
                let existing = try Data(contentsOf: target)
                guard digest(existing) == desiredHash || results[target.path] == digest(existing) else { throw Failure("译文文件已被修改，未覆盖：\(target.lastPathComponent)") }
                try data.write(to: target, options: .atomic)
            } else { try data.write(to: target, options: .withoutOverwriting) }
            results[target.path] = desiredHash
        }
        return results
    }
}
