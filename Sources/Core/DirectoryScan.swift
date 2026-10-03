import Foundation

public struct FileStamp: Equatable, Sendable {
    public var identity: String
    public var size: UInt64
    public var modified: Date
    public var changed: Date
    public static func read(_ url: URL) throws -> Self {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Self(identity: try DirectoryIndex.identity(url), size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                    modified: a[.modificationDate] as? Date ?? .distantPast, changed: a[.creationDate] as? Date ?? .distantPast)
    }
}
public struct DirectoryScanResult: Sendable {
    public var root: URL
    public var directories: [URL] = []
    public var files: [URL] = []
    public var media: [IndexedMedia] = []
    public var stamps: [String: FileStamp] = [:]
    public var issues: [String] = []
    public var unstable = false
    public var completed = Date()
}
/// A scan owns no library records. Failure to read a subtree never means it was deleted.
public actor DirectoryScanner {
    private var hashes: [String: (FileStamp, String)] = [:]
    public init() {}
    public func scan(_ root: URL, settle: Duration = .seconds(1)) async throws -> DirectoryScanResult {
        var result = DirectoryScanResult(root: DirectoryIndex.canonical(root))
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else { throw Failure("总目录不可读取：\(root.path)") }
        func visit(_ folder: URL) {
            do {
                let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey], options: [])
                for url in children where ImportPlanner.includes(url) {
                    do {
                        let v = try url.resourceValues(forKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
                        if v.isSymbolicLink == true { continue }
                        if v.isDirectory == true { result.directories.append(url); visit(url) }
                        else if v.isRegularFile == true, ImportPlanner.media.union(ImportPlanner.subtitles).contains(url.pathExtension.lowercased()), !ImportPlanner.isGenerated(url) {
                            try ImportPlanner.requireLocal(url); result.stamps[url.path] = try FileStamp.read(url); result.files.append(url)
                        }
                    } catch { result.issues.append("\(url.path)：\(error.localizedDescription)") }
                }
            } catch { result.issues.append("\(folder.path)：\(error.localizedDescription)") }
        }
        // A root failure is fatal rather than an apparently successful empty scan.
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        visit(result.root)
        try await Task.sleep(for: settle)
        var stable: [URL] = []
        for url in result.files {
            try Task.checkCancellation()
            do {
                let stamp = try FileStamp.read(url)
                guard result.stamps[url.path] == stamp, stamp.size > 0 else {
                    result.unstable = true; result.issues.append("正在写入，稍后重试：\(url.path)"); continue
                }
                if ImportPlanner.media.contains(url.pathExtension.lowercased()) {
                    let hash: String
                    if let cached = hashes[url.path], cached.0 == stamp { hash = cached.1 }
                    else { hash = try DirectoryIndex.hash(url) }
                    guard try FileStamp.read(url) == stamp else { result.unstable = true; result.issues.append("校验期间文件改变：\(url.path)"); continue }
                    hashes[url.path] = (stamp, hash)
                    result.media.append(IndexedMedia(url: url, identity: stamp.identity, hash: hash))
                }
                stable.append(url)
            } catch { result.issues.append("\(url.path)：\(error.localizedDescription)") }
        }
        result.files = stable; result.completed = Date()
        return result
    }
}

public extension DirectoryIndex {
    static func contains(_ path: String, in directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
    /// Reuse records by physical path; folders exist independently of imported lessons.
    static func buildTree(_ directories: [URL], root: URL, library: inout Library) {
        for directory in directories.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            var placeholder = Lecture(title: "", courseID: UUID(), folderID: nil, url: directory.appendingPathComponent(".index"), bookmark: nil, identity: "")
            classify(&placeholder, root: root, library: &library)
        }
    }
    /// Returns a conflict rather than selecting a different physical directory silently.
    static func classifyAvailable(_ lesson: inout Lecture, root: URL, library: inout Library) -> [String] {
        let available = lesson.mediaSources.map { URL(fileURLWithPath: $0.path) }.filter {
            FileManager.default.fileExists(atPath: $0.path) && relativeDirectory($0, root: root) != nil
        }
        let parents = Set(available.map { canonical($0).deletingLastPathComponent().path })
        guard !parents.isEmpty else { lesson.directoryPath = nil; return [] }
        if parents.count > 1 {
            if let chosen = lesson.directoryChoice, parents.contains(chosen) {
                let original = lesson.path; lesson.path = URL(fileURLWithPath: chosen).appendingPathComponent(".index").path
                classify(&lesson, root: root, library: &library); lesson.path = original; return []
            }
            return parents.sorted()
        }
        let original = lesson.path; lesson.path = available[0].path
        classify(&lesson, root: root, library: &library); lesson.path = original
        return []
    }
    static func pendingGroups(_ urls: [URL]) -> [[URL]] {
        var used = Set<URL>(); var groups: [[URL]] = []
        for url in urls.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) where !used.contains(url) {
            var group = [url]
            if let companion = ImportPlanner.companion(for: url, in: urls) { group.append(companion) }
            used.formUnion(group); groups.append(group.sorted { ImportPlanner.role(for: $0) == .screen && ImportPlanner.role(for: $1) != .screen })
        }
        return groups
    }
}
