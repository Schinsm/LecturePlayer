import Foundation
import Darwin

public struct FileStamp: Codable, Hashable, Sendable {
    public var identity: String
    public var size: UInt64
    public var modified: Date
    public var changed: Date
    public var modifiedNanoseconds:Int64?
    public var changedNanoseconds:Int64?
    public static func read(_ url: URL) throws -> Self {
        var info=stat()
        guard url.path.withCString({lstat($0,&info)})==0 else {throw CocoaError(.fileReadUnknown)}
        guard (info.st_mode & S_IFMT)==S_IFREG else {throw Failure("不是普通文件")}
        return Self(identity:try DirectoryIndex.identity(url),size:UInt64(max(0,info.st_size)),
                    modified:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1e9),
                    changed:Date(timeIntervalSince1970:Double(info.st_ctimespec.tv_sec)+Double(info.st_ctimespec.tv_nsec)/1e9),
                    modifiedNanoseconds:Int64(info.st_mtimespec.tv_nsec),changedNanoseconds:Int64(info.st_ctimespec.tv_nsec))
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
    private let fingerprints:MediaFingerprintCache
    public init(cache:MediaFingerprintCache=MediaFingerprintCache()) {fingerprints=cache}
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
        struct Checked:Sendable {var url:URL;var media:IndexedMedia?;var issue:String?;var unstable=false}
        let files=result.files,stamps=result.stamps,cache=fingerprints
        var stable:[URL]=[]
        await withTaskGroup(of:Checked.self) {group in
            var cursor=0
            func dispatch() {
                guard cursor<files.count,!Task.isCancelled else{return}
                let url=files[cursor];cursor += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let stamp=try FileStamp.read(url)
                        guard stamps[url.path]==stamp,stamp.size>0 else {return Checked(url:url,issue:"正在写入，稍后重试："+url.path,unstable:true)}
                        var media:IndexedMedia?
                        if ImportPlanner.media.contains(url.pathExtension.lowercased()) {
                            let hash=try await cache.hash(url)
                            guard try FileStamp.read(url)==stamp else {return Checked(url:url,issue:"校验期间文件改变："+url.path,unstable:true)}
                            media=IndexedMedia(url:url,identity:stamp.identity,hash:hash)
                        }
                        return Checked(url:url,media:media)
                    } catch {return Checked(url:url,issue:url.path+"："+error.localizedDescription)}
                }
            }
            dispatch();dispatch()
            while let checked=await group.next() {
                if let issue=checked.issue {result.issues.append(issue);result.unstable = result.unstable || checked.unstable}
                else {stable.append(checked.url);if let media=checked.media {result.media.append(media)}}
                dispatch()
            }
        }
        try Task.checkCancellation()
        stable.sort{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
        result.media.sort{$0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending}
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
