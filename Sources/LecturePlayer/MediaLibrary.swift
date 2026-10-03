import AppKit
import Core

@MainActor final class MediaTransfer: ObservableObject {
    @Published var running = false; @Published var progress = 0.0; @Published var message = ""
    var worker: Task<Void, Error>?
    func cancel() { worker?.cancel() }
    func copy(_ pairs: [(URL, URL)]) async throws {
        guard !running else { throw Failure("已有复制任务正在进行") }
        running = true; progress = 0; message = "复制并校验媒体…"
        defer { running = false; worker = nil }
        let reporter = self
        let job = Task.detached {
            for (index, pair) in pairs.enumerated() {
                try MediaCopy.copy(from: pair.0, to: pair.1) { value in
                    Task { @MainActor in reporter.progress = (Double(index) + value) / Double(pairs.count) }
                }
            }
        }
        worker = job
        try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
        progress = 1; message = "校验完成"
    }
}
extension AppStore {
    func mediaRoot(change: Bool = false) throws -> URL {
        let preferences = UserDefaults.standard
        if !change, let data = preferences.data(forKey: "mediaRootBookmark") {
            var stale = false
            return try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择 Lecture Player 媒体目录。更改只影响新导入，不移动已有文件。建议在 Movies 下创建 LecturePlayer Media。"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        preferences.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "mediaRootBookmark")
        preferences.set(url.path, forKey: "mediaRootPath"); return url
    }
    @discardableResult func importLesson(row: ImportRow, managed: Bool, destinationRoot: URL? = nil) async throws -> UUID {
        guard let repository else { throw Failure("资料库不可用") }; let courseID = selectedCourse ?? UUID()
        let originalURLs = [row.video] + (row.secondary.map { [$0] } ?? [])
        let scoped = (originalURLs + (row.subtitle.map { [$0] } ?? [])).filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        guard Set(originalURLs).count == originalURLs.count else { throw Failure("两路视角不能使用同一文件") }
        let initialStamps = try await verifyStable(originalURLs + (row.subtitle.map { [$0] } ?? []))
        var media: [MediaSource] = []
        for (i, url) in originalURLs.enumerated() {
            try ImportPlanner.requireLocal(url)
            let identity = try Self.fileIdentity(url)
            guard !library.lectures.contains(where: { $0.mediaSources.contains(where: { $0.identity == identity }) }) else { throw Failure("此视频已经导入，请使用已有条目或合并") }
            let credential = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            media.append(MediaSource(role: i == 0 ? row.role : (row.role == .screen ? .camera : .screen), path: url.path, bookmark: credential, identity: identity))
        }
        for i in media.indices {
            let url = originalURLs[i]; media[i].contentHash = try await Task.detached { try DirectoryIndex.hash(url) }.value
        }
        var lesson = Lecture(title: row.title, courseID: courseID, folderID: selectedFolder, url: row.video, bookmark: nil, identity: media[0].identity)
        lesson.subtitlePath = row.subtitle?.path; lesson.week = row.week; lesson.sessionType = row.sessionType; lesson.topic = row.topic; lesson.customTitle = row.customTitle
        lesson.state.speed = UserDefaults.standard.double(forKey: "defaultSpeed") == 0 ? 1 : UserDefaults.standard.double(forKey: "defaultSpeed")
        let transcript = try row.subtitle.map { try SubtitleParser.parse(Data(contentsOf: $0), format: $0.pathExtension) }
        var createdDirectory: URL?
        do {
            if managed {
                let root = try destinationRoot ?? mediaRoot(); let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
                let directory = root.appendingPathComponent(lesson.id.uuidString); createdDirectory = directory
                var pairs: [(URL, URL)] = []
                for i in media.indices {
                    let target = directory.appendingPathComponent(media[i].id.uuidString).appendingPathComponent(media[i].originalFilename)
                    pairs.append((originalURLs[i], target)); media[i].path = target.path; media[i].managed = true
                }
                try await transfer.copy(pairs)
                for i in media.indices { media[i].bookmark = try URL(fileURLWithPath: media[i].path).bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
            }
            try Task.checkCancellation(); try verifyUnchanged(initialStamps); lesson.mediaSources = media
            if let transcript { try repository.write(transcript, for: lesson.id); lesson.transcriptVersion = transcript.version }
            var next = library
            if let root = library.directoryRoot { DirectoryIndex.classify(&lesson, root: URL(fileURLWithPath: root), library: &next); _ = DirectoryIndex.classifyAvailable(&lesson, root: URL(fileURLWithPath: root), library: &next) }
            guard next.courses.contains(where: { $0.id == lesson.courseID }) else { throw Failure("请把视频放进总目录下的学科文件夹，再刷新导入") }
            guard !next.lectures.contains(where: { existing in existing.mediaSources.contains { source in media.contains { $0.identity == source.identity } } }) else { throw Failure("导入期间视频已关联，未重复创建课件") }
            next.lectures.append(lesson); try repository.save(next); library = next
            return lesson.id
        } catch { if let createdDirectory { try? FileManager.default.removeItem(at: createdDirectory) }; throw error }
    }
    func copyExisting(_ id: UUID) {
        guard let item = library.lectures.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "复制已有媒体到媒体库？"; alert.informativeText = item.mediaSources.filter { !$0.managed }.map(\.originalFilename).joined(separator: "\n") + "\n源文件保留，校验成功后才更新引用。"; alert.addButton(withTitle: "复制"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            var folder: URL?
            do {
                let root = try mediaRoot(); let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
                let targetRoot = root.appendingPathComponent("transfer-\(UUID())"); folder = targetRoot
                var sources = item.mediaSources; var pairs: [(URL, URL)] = []
                for i in sources.indices where !sources[i].managed {
                    let destination = targetRoot.appendingPathComponent(item.id.uuidString).appendingPathComponent(sources[i].id.uuidString).appendingPathComponent(sources[i].originalFilename)
                    pairs.append((URL(fileURLWithPath: sources[i].path), destination)); sources[i].path = destination.path; sources[i].managed = true
                }
                try await transfer.copy(pairs)
                for i in sources.indices { sources[i].bookmark = try URL(fileURLWithPath: sources[i].path).bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                guard let index = library.lectures.firstIndex(where: { $0.id == id }) else { throw Failure("条目已不存在") }
                var next = library; next.lectures[index].mediaSources = sources; try repository?.save(next); library = next
                if current == id { open(id) }
            } catch { if let folder { try? FileManager.default.removeItem(at: folder) }; if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
}
