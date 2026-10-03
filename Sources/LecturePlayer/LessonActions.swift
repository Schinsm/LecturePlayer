import AppKit
import Core

extension AppStore {
    func adjustMediaOffset() {
        guard let item = lecture, item.mediaSources.count == 2 else { return }
        let source = item.mediaSources[1]
        guard let text = askName("第二视角相对时间（秒）：视频时间 = 主时间轴 + 此值", initial: String(source.relativeOffset)), let offset = Double(text), offset.isFinite, abs(offset) <= 86400 else { return }
        playback.persist(); updateLecture(item.id) { var sources = $0.mediaSources; sources[1].relativeOffset = offset; $0.mediaSources = sources }; open(item.id)
    }
    func chooseMerge(primaryID: UUID) {
        guard let primary = library.lectures.first(where: { $0.id == primaryID }) else { return }
        let candidates = library.lectures.filter { $0.id != primaryID && $0.courseID == primary.courseID && $0.mediaSources.count == 1 && $0.archived != true }
        guard !candidates.isEmpty else { error = "同课程内没有可合并的单视频条目"; return }
        let alert = NSAlert(); alert.messageText = "选择摄像头条目"; alert.informativeText = "主条目（屏幕）：" + primary.displayTitle
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28)); picker.addItems(withTitles: candidates.map(\.displayTitle)); alert.accessoryView = picker
        alert.addButton(withTitle: "预览合并"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }; merge(primaryID: primaryID, secondaryID: candidates[picker.indexOfSelectedItem].id)
    }
    func merge(primaryID: UUID, secondaryID: UUID) {
        guard !translation.running else{error="请先暂停翻译并等待保存完成";return}
        guard primaryID != secondaryID, let primary = library.lectures.first(where: { $0.id == primaryID }), let other = library.lectures.first(where: { $0.id == secondaryID }), primary.mediaSources.count == 1, other.mediaSources.count == 1 else { error = "请选择两堂单视频课件"; return }
        let prompt = NSAlert(); prompt.messageText = "合并为双视频课件？"; prompt.informativeText = "主条目：\(primary.displayTitle)\n保留主条目的时间轴、进度与校准。另一条目归档保留，字幕冲突也保留在原条目中。主条目视角设为屏幕，另一条目设为摄像头。"; prompt.addButton(withTitle: "合并"); prompt.addButton(withTitle: "取消"); guard prompt.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let repository else { throw Failure("资料库不可用") }
            if primary.transcriptVersion == other.transcriptVersion, var original = try repository.read(primary), let additional = try repository.read(other) {
                for (id,variant) in additional.variants ?? [:] {
                    original.ensureVariant(id)
                    for (key,value) in variant.translations where original.variants?[id]?.translations[key]==nil {original.variants?[id]?.translations[key]=value}
                }
                try repository.write(original, for: primaryID)
            }
            var next = library
            let a = next.lectures.firstIndex { $0.id == primaryID }!, b = next.lectures.firstIndex { $0.id == secondaryID }!
            var first = primary.mediaSources[0], second = other.mediaSources[0]; first.role = .screen; second.role = .camera
            next.lectures[a].mediaSources = [first, second]; next.lectures[b].archived = true
            try repository.save(next); library = next
            if current == primaryID { open(primaryID) }
        }
    }
    func exportStudyPackage() {
        playback.persist()
        guard let item = lecture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "资料包包含英文字幕、中文译文、总结与章节、书签和学习进度；视频可选。将创建新的 .lecturestudy 文件夹，不覆盖已有资料。"
        let include = NSButton(checkboxWithTitle: "包含视频（可能较大）", target: nil, action: nil); include.state = .off; panel.accessoryView = include
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent(item.displayTitle.replacingOccurrences(of: "/", with: "-") + "-\(Int(Date().timeIntervalSince1970)).lecturestudy")
        Task { do { try await writeStudyPackage(item: item, destination: destination, includeMedia: include.state == .on); NSWorkspace.shared.activateFileViewerSelecting([destination]) } catch { if !(error is CancellationError) { self.error = error.localizedDescription } } }
    }
    func writeStudyPackage(item: Lecture, destination: URL, includeMedia: Bool) async throws {
        guard let repository else { throw Failure("资料库不可用") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("目标已存在，不覆盖学习包") }
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".study-\(UUID())")
            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                var single = Library(); single.courses = library.courses.filter { $0.id == item.courseID }; var safe = item; safe.folderID = nil; safe.bookmark = nil; safe.subtitleBookmark = nil
                var sources = item.mediaSources
                var pairs: [(URL, URL)] = []
                for i in sources.indices {
                    sources[i].bookmark = nil
                    if includeMedia { let relative = "Media/\(sources[i].id)/\(sources[i].originalFilename)"; pairs.append((URL(fileURLWithPath: sources[i].path), stage.appendingPathComponent(relative))); sources[i].path = relative }
                }
                safe.mediaSources = sources; single.lectures = [safe]
                var transcripts: [String: Transcript] = [:]
                for url in try FileManager.default.contentsOfDirectory(at: repository.root.appendingPathComponent("transcripts"), includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(item.id.uuidString) && url.pathExtension == "json" {
                    let t = try Codec.decode(Transcript.self, Data(contentsOf: url)).viewing(item.selectedTranslationVariantID); transcripts[url.deletingPathExtension().lastPathComponent] = t
                    let subtitle = stage.appendingPathComponent("Subtitles", isDirectory: true); try FileManager.default.createDirectory(at: subtitle, withIntermediateDirectories: true)
                    try t.original.write(to: subtitle.appendingPathComponent(t.version + "." + t.format))
                    try Exporter.render(t, kind: .markdown, marks: item.marks, hideSpeakers: UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true, grouped:item.readingGrouped ?? true).write(to: subtitle.appendingPathComponent(t.version + "." + t.variantID.lowercased() + ".md"))
                }
                let records = try AnalysisRepository.readAll(root: repository.root).filter { $0.lessonID == item.id }
                let analyses = try Backup.analysisPayload(records)
                for record in records where record.completed != nil {
                    guard let source = transcripts["\(item.id)-\(record.sourceVersion)"] else { throw Failure("总结缺少对应字幕版本") }
                    let directory = stage.appendingPathComponent("Analysis", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let markdown = try AnalysisMarkdown.export(record, transcript: source, offset: item.state.offset, title: item.displayTitle)
                    try Data(markdown.utf8).write(to: directory.appendingPathComponent(record.sourceVersion + ".md"), options: .atomic)
                }
                let package = Backup(library: single, transcripts: transcripts, analyses: analyses); try package.validate(); try Codec.encode(package).write(to: stage.appendingPathComponent("Library.json"))
                try Data("Lecture Player 学习包\nLibrary.json 包含元数据、各字幕版本的译文与总结、书签和进度，可通过恢复备份载入。包含视频时路径相对此目录；恢复后可重新定位到 Media。API Key 不在学习包内。\n".utf8).write(to: stage.appendingPathComponent("README.txt"))
                if !pairs.isEmpty { try await transfer.copy(pairs) }
                try FileManager.default.moveItem(at: stage, to: destination)
            } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
}
