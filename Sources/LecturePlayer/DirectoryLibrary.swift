import AppKit
import Core
import UniformTypeIdentifiers

extension AppStore {
    func addSecondVideo(_ id: UUID) {
        guard let item = library.lectures.first(where: { $0.id == id }), item.mediaSources.count == 1 else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = URL(fileURLWithPath: item.path).deletingLastPathComponent(); panel.message = "选择第二视角；s1 为屏幕，s2 为摄像头。原进度、字幕和译文保持不变。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let role = item.mediaSources[0].role == .screen ? MediaRole.camera : .screen
        let alert = NSAlert(); alert.messageText = "添加\(role.rawValue)视角？"; alert.informativeText = url.lastPathComponent + "\n识别：" + (ImportPlanner.role(for: url)?.rawValue ?? "未知，可在课件详情更改角色")
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await attachSecond(id, url: url) } catch { self.error = error.localizedDescription } }
    }
    func attachSecond(_ id: UUID, url: URL) async throws {
        guard let item = library.lectures.first(where: { $0.id == id }), item.mediaSources.count == 1 else { throw Failure("一堂课最多两路视频") }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try ImportPlanner.requireLocal(url); let stamps = try await verifyStable([url]); let identity = try Self.fileIdentity(url)
        guard !library.lectures.contains(where: { $0.mediaSources.contains { $0.identity == identity } }) else { throw Failure("视频已关联课件，请使用合并功能") }
        var source = MediaSource(role: item.mediaSources[0].role == .screen ? .camera : .screen, path: url.path, bookmark: try url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil), identity: identity)
        source.contentHash = try await Task.detached { try DirectoryIndex.hash(url) }.value
        try verifyUnchanged(stamps)
        let active = current == id; if active { playback.persist() }
        guard let index = library.lectures.firstIndex(where: { $0.id == id }), library.lectures[index].mediaSources.count == 1 else { throw Failure("课件已改变，请重试") }
        var next = library; next.lectures[index].mediaSources.append(source); next.lectures[index].layout = .inset
        try repository?.save(next); library = next; if active { open(id) }
    }
    func selectDirectoryRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择独立总目录，内部按 学科 / Week 文件夹 放置视频与字幕。仅索引，不搬移源文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            rootGeneration = UUID()
            var next = library; next.directoryRoot = url.path; next.directoryBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try repository?.save(next); library = next
        }
        refreshDirectory()
    }
    func refreshDirectory() {
        guard let path = library.directoryRoot else { return }
        if scanning { rescanRequested = true; return }
        recordDirectoryAttempt()
        scanning = true; rescanRequested = false; scanSummary = "正在扫描…"
        let generation = rootGeneration
        scanTask = Task {
            defer {
                scanning = false; scanTask = nil
                if watchesEnabled && !rescanRequested { UserDefaults.standard.set(scanSummary,forKey:refreshPreferenceKey+"-result") }
                if rescanRequested { rescanRequested = false; refreshDirectory() }
            }
            do {
                let root = try resolveDirectoryRoot(path)
                let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
                let result = try await scanner.scan(root)
                guard library.directoryRoot == path, generation == rootGeneration else { rescanRequested = true; return }
                var next = library; next.directoryRoot = result.root.path
                DirectoryIndex.buildTree(result.directories, root: result.root, library: &next)
                var conflicts: [UUID: [String]] = [:]
                for i in next.lectures.indices {
                    var item = next.lectures[i]; var sources = item.mediaSources
                    for j in sources.indices {
                        if let match = DirectoryIndex.match(sources[j], files: result.media) {
                            sources[j].path = match.url.path; sources[j].identity = match.identity; sources[j].contentHash = match.hash
                            sources[j].bookmark = try match.url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                        }
                    }
                    item.mediaSources = sources
                    // Incomplete enumeration must not erase a previously known association.
                    if result.issues.isEmpty || sources.contains(where: { source in result.media.contains { $0.identity == source.identity } }) {
                        let locations = DirectoryIndex.classifyAvailable(&item, root: result.root, library: &next)
                        if !locations.isEmpty { conflicts[item.id] = locations }
                    }
                    if let version = item.transcriptVersion, let directory = item.directoryPath {
                        let matches = result.files.filter { ImportPlanner.subtitles.contains($0.pathExtension.lowercased()) && $0.deletingLastPathComponent().path == directory }.filter { (try? Data(contentsOf: $0)).map(digest) == version }
                        if matches.count == 1 { item.subtitlePath = matches[0].path }
                    }
                    next.lectures[i] = item
                }
                // Keep records referenced by lessons; hide non-existent empty directories only on a complete scan.
                if result.issues.isEmpty {
                    let paths = Set(result.directories.map(\.path))
                    var used = Set(next.lectures.compactMap(\.folderID))
                    for item in next.lectures { var cursor = item.folderID; while let id = cursor, let folder = next.folders.first(where: { $0.id == id }) { used.insert(id); cursor = folder.parentID } }
                    next.folders.removeAll { $0.directoryPath != nil && !paths.contains($0.directoryPath!) && !used.contains($0.id) }
                    next.courses.removeAll { course in course.directoryPath != nil && !paths.contains(course.directoryPath!) && !next.lectures.contains(where: { $0.courseID == course.id }) && !next.folders.contains(where: { $0.courseID == course.id }) }
                }
                try repository?.save(next); library = next
                navigation.refreshAvailability();scanResult = result; scanConflicts = conflicts; scanIssues = result.issues
                directoryFiles = result.files
                let identities = Set(next.lectures.flatMap(\.mediaSources).map(\.identity))
                pendingFiles = result.media.filter { !identities.contains($0.identity) }.map(\.url)
                scanSummary = "\(result.issues.isEmpty ? "已完成" : "部分完成") · \(result.completed.formatted(date: .omitted, time: .standard)) · \(result.media.count) 个视频 · \(DirectoryIndex.pendingGroups(pendingFiles).count) 堂待确认"
                if let id = selectedFolder, !next.folders.contains(where: { $0.id == id }) { selectedFolder = nil }
                if let id = selectedCourse, !next.courses.contains(where: { $0.id == id }) { selectedCourse = nil; selectedFolder = nil }
                if selectedCourse == nil, !next.lectures.contains(where: { $0.directoryPath == nil }) {
                    let visiblePath = next.lectures.compactMap(\.directoryPath).first ?? result.media.first?.url.deletingLastPathComponent().path
                    selectedCourse = next.courses.first(where: { course in course.directoryPath.map { directory in visiblePath.map { DirectoryIndex.contains($0, in: directory) } ?? false } ?? false })?.id
                }
                if watchesEnabled && refreshPolicy == .automatic { directoryWatch.update([result.root, result.root.deletingLastPathComponent()] + result.directories) }
                for item in library.lectures where item.subtitlePath != nil { saveVisibleTranslations(item.id) }
                if result.unstable && refreshPolicy == .automatic { directoryWatch.schedule() }
            } catch is CancellationError { scanSummary = "扫描已取消；显示上次结果" }
            catch { scanSummary = "刷新失败；显示上次结果"; scanIssues = [error.localizedDescription] }
        }
    }
    func resolveDirectoryRoot(_ path: String) throws -> URL {
        if let bookmark = library.directoryBookmark {
            var stale = false
            do { return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope,.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            catch {
                // Non-sandboxed builds can read an ordinary bookmark; validate the stored selection.
                let ordinary = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard DirectoryIndex.canonical(ordinary).path == DirectoryIndex.canonical(URL(fileURLWithPath: path)).path,
                      FileManager.default.isReadableFile(atPath: ordinary.path) else { throw Failure("课程目录授权失效，请重新选择总目录") }
                return ordinary
            }
        }
        return URL(fileURLWithPath: path)
    }
    func linkSubtitle(_ id: UUID) {
        guard let item = library.lectures.first(where: { $0.id == id }), let url = chooseFiles(types: [.init(filenameExtension: "vtt")!, .init(filenameExtension: "srt")!, .plainText]).first else { return }
        perform {
            let data = try Data(contentsOf: url)
            guard digest(data) == item.transcriptVersion else { throw Failure("字幕内容与已保存版本不同。请选原字幕；更换版本请使用播放菜单。") }
            updateLecture(id) { $0.subtitlePath = url.path }; saveVisibleTranslations(id)
        }
    }
    @discardableResult func saveVisibleTranslations(_ id: UUID) -> Task<Void,Never>? {
        guard let item=library.lectures.first(where:{$0.id==id}),let version=item.transcriptVersion,
              let url=try? repository?.transcriptURL(id,version) else{return nil}
        return Task {do {
            let result=try await translation.writer.saveFiles(lesson:item,url:url)
            guard library.lectures.first(where:{$0.id==id})?.transcriptVersion==version else{return}
            displayTranscript(result.transcript,for:id)
            updateLecture(id){$0.sidecars=result.sidecars;$0.sidecarStatus=result.fileStatus}
        }catch{updateLecture(id){$0.sidecarStatus="译文已存资料库；文件待保存："+error.localizedDescription}}}
    }

}

extension AppStore {
    func swapRoles(_ id: UUID) {
        let active = current == id; if active { playback.persist() }
        updateLecture(id) { item in var sources = item.mediaSources; for i in sources.indices { sources[i].role = sources[i].role == .screen ? .camera : .screen }; item.mediaSources = sources }
        if active { open(id) }
    }
    func linkMedia(_ id: UUID, sourceID: UUID) {
        guard let item = library.lectures.first(where: { $0.id == id }), let source = item.mediaSources.first(where: { $0.id == sourceID }),
              let url = chooseFiles(types: [.mpeg4Movie,.quickTimeMovie]).first else { return }
        let alert = NSAlert(); alert.messageText = "确认重新关联原课件？"
        alert.informativeText = "原位置：\(source.path)\n新位置：\(url.path)\n" + (source.contentHash == nil ? "没有旧校验值，名称只能作为线索。请确认这是原视频。" : "提交前将校验视频内容一致。") + "\n保留进度、校准和全部译文。"
        alert.addButton(withTitle: "确认关联"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await relinkMedia(id, sourceID: sourceID, url: url); refreshDirectory() } catch { self.error = error.localizedDescription } }
    }
    func relinkMedia(_ id: UUID, sourceID: UUID, url: URL) async throws {
        guard let item = library.lectures.first(where: { $0.id == id }), let source = item.mediaSources.first(where: { $0.id == sourceID }) else { throw Failure("原课件已改变") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let stamps = try await verifyStable([url]); let hash = try await Task.detached { try DirectoryIndex.hash(url) }.value
        try verifyUnchanged(stamps)
        if let old = source.contentHash, old != hash { throw Failure("所选视频内容不同，未改变原课件") }
        let identity = try Self.fileIdentity(url)
        guard !library.lectures.contains(where: { $0.mediaSources.contains { $0.id != sourceID && $0.identity == identity } }) else { throw Failure("此视频已关联另一视角或课件") }
        if current == id { playback.persist() }
        var next = library; guard let index = next.lectures.firstIndex(where: { $0.id == id }) else { throw Failure("原课件不存在") }
        var updated = next.lectures[index]; var sources = updated.mediaSources
        guard let j = sources.firstIndex(where: { $0.id == sourceID }), sources[j] == source else { throw Failure("关联已改变，请重新预览") }
        try repository?.writeRecoverySnapshot(library)
        sources[j].path = url.path; sources[j].identity = identity; sources[j].contentHash = hash; sources[j].managed = false
        sources[j].bookmark = try url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        updated.mediaSources = sources
        if let root = next.directoryRoot { _ = DirectoryIndex.classifyAvailable(&updated, root: URL(fileURLWithPath: root), library: &next) }
        next.lectures[index] = updated; try repository?.save(next); library = next
        // Explicit relinking replaces unavailable AVPlayer items. Reopen paused at the saved position.
        if current == id { open(id) }
    }
    func verifyStable(_ urls: [URL]) async throws -> [URL: FileStamp] {
        let stamps = try Dictionary(uniqueKeysWithValues: urls.map { ($0, try FileStamp.read($0)) })
        try await Task.sleep(for: .seconds(1)); try verifyUnchanged(stamps)
        guard stamps.values.allSatisfy({ $0.size > 0 }) else { throw Failure("文件尚未写入完成，请稍后重试") }
        return stamps
    }
    func verifyUnchanged(_ stamps: [URL: FileStamp]) throws {
        for (url, before) in stamps where try FileStamp.read(url) != before { throw Failure("文件仍在变化，未提交：\(url.lastPathComponent)") }
    }
    func recoverSubtitleLocations() {
        for item in library.lectures where item.transcriptVersion != nil {
            if item.subtitlePath == nil, let version = item.transcriptVersion {
                let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent()
                let files = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                let matches = files.filter { ImportPlanner.subtitles.contains($0.pathExtension.lowercased()) && !ImportPlanner.isGenerated($0) }.filter { (try? Data(contentsOf: $0)).map(digest) == version }
                if matches.count == 1 { updateLecture(item.id) { $0.subtitlePath = matches[0].path } }
            }
            saveVisibleTranslations(item.id)
        }
    }
}

extension AppStore {
    func chooseDirectory(_ id: UUID) {
        guard let locations = scanConflicts[id], !locations.isEmpty else { return }
        let panel = NSAlert(); panel.messageText = "选择课件归属目录"
        panel.informativeText = "两路视频位于不同目录。只设置课件显示位置，不移动文件。"
        let choices = NSPopUpButton(frame: NSRect(x: 0,y: 0,width: 540,height: 28)); choices.addItems(withTitles: locations)
        panel.accessoryView = choices; panel.addButton(withTitle: "保存归属"); panel.addButton(withTitle: "取消")
        guard panel.runModal() == .alertFirstButtonReturn, let chosen = choices.titleOfSelectedItem else { return }
        perform { try repository?.writeRecoverySnapshot(library); updateLecture(id) { $0.directoryChoice = chosen }; refreshDirectory() }
    }
}
