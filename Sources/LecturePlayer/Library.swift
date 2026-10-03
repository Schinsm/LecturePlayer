import AppKit
import SwiftUI
import Core
import UniformTypeIdentifiers

@MainActor final class AppStore: ObservableObject {
    var library = Library() {didSet{if !quietLibraryUpdate {objectWillChange.send(); refreshDirectoryPresentation()}}}
    private var quietLibraryUpdate=false
    let performanceProbe=MainThreadProbe()
    let usagePresentation=UsagePresentation()
    var usageCache:UsageDataset?
    var usageCacheToken=""
    let navigation=DirectoryPresentation()
    let readerPresentation=ReaderPresentationState()
     @Published var transcript: Transcript?; @Published var current: UUID?; var selectedCourse:UUID? {get{navigation.course} set{navigation.course=newValue}}
    var selectedFolder:UUID? {get{navigation.folder} set{navigation.folder=newValue}}
     @Published var error: String?; @Published var fatal = false
    @Published var importStatus=""
    @Published var scanning = false; @Published var directoryFiles: [URL] = []; @Published var pendingFiles: [URL] = [] {didSet{refreshDirectoryPresentation()}}; @Published var showingLocations = false
    @Published var scanSummary = "尚未扫描"
    @Published var scanIssues: [String] = []
    @Published var scanConflicts: [UUID: [String]] = [:]
    @Published var scanResult: DirectoryScanResult?
    @Published var refreshPolicy = RefreshPolicy.automatic
    @Published var lastDirectoryAttempt: Date?
    var refreshTimer: Timer?
    var unlinkedCount: Int { library.lectures.filter { $0.directoryPath == nil && $0.archived != true }.count }
    var fingerprints=MediaFingerprintCache()
    lazy var scanner = DirectoryScanner(cache:fingerprints); let directoryWatch = DirectoryWatch()
    var rescanRequested = false
    var scanTask: Task<Void, Never>?
    var rootGeneration = UUID()
    var watchesEnabled = true
    let captions = CaptionPresentation()
    let requests=RequestScheduler()
    let processing = ImportProcessingCoordinator()
    let analysis = AnalysisJob(); let transfer = MediaTransfer(); let translation = TranslationJob(); let playback = Playback(); var repository: Repository?
    var lecture: Lecture? { library.lectures.first { $0.id == current } }
    var breadcrumb: String {
        guard let lecture else { return "" }
        var names: [String] = []; var cursor = lecture.folderID
        while let id = cursor, let folder = library.folders.first(where: { $0.id == id }) { names.insert(folder.name, at: 0); cursor = folder.parentID }
        names.insert(library.courses.first(where: { $0.id == lecture.courseID })?.name ?? "", at: 0)
        return names.joined(separator: " / ")
    }
    init(root explicitRoot: URL? = nil) {
        do {
            let root = explicitRoot ?? ProcessInfo.processInfo.environment["LECTURE_PLAYER_DATA"].map { URL(fileURLWithPath: $0) } ?? (Bundle.main.object(forInfoDictionaryKey: "LecturePlayerDataRoot") as? String).map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LecturePlayer")
            watchesEnabled = explicitRoot == nil && Bundle.main.object(forInfoDictionaryKey: "LecturePlayerDisableAutomaticMaintenance") as? Bool != true
            fingerprints=MediaFingerprintCache(storage:root.appendingPathComponent("Cache/media-fingerprints.json"))
            repository = try Repository(root: root); library = try repository!.load(); refreshDirectoryPresentation(); selectedCourse = library.courses.filter { $0.directoryPath != nil }.sorted { $0.order < $1.order }.first?.id
            let upgradeSnapshot = root.appendingPathComponent("before-v086.json")
            if !library.lectures.isEmpty, !FileManager.default.fileExists(atPath: upgradeSnapshot.path) { try repository!.writeRecoverySnapshot(library, to: upgradeSnapshot) }
            if watchesEnabled {
                refreshPolicy=RefreshPolicy(rawValue:UserDefaults.standard.string(forKey:"directoryRefreshPolicy") ?? "automatic") ?? .automatic
                lastDirectoryAttempt=UserDefaults.standard.object(forKey:refreshPreferenceKey) as? Date
                scanSummary=UserDefaults.standard.string(forKey:refreshPreferenceKey+"-result") ?? "尚未扫描"
            }
            readerPresentation.save = {[weak self] id,panel in self?.updateLecture(id,quiet:true){$0.studyPanel=panel}}
            captions.save = { [weak self] id,value in self?.updateLecture(id) {$0.videoCaptions=value} }
            translation.restore(self);processing.restore(self)
            Task { [weak self] in await self?.translation.writer.observeFiles { [weak self] id,saved in
                guard let self,let lesson=self.library.lectures.first(where:{$0.id==id}),lesson.transcriptVersion==saved.transcript.version else{return}
                self.displayTranscript(saved.transcript,for:id)
                self.updateLecture(id){if let files=saved.sidecars {$0.sidecars=files};$0.sidecarStatus=saved.fileStatus}
            }}
            directoryWatch.changed = { [weak self] in guard let self,self.refreshPolicy == .automatic else { return };self.refreshDirectory() }
            configureRefreshSchedule()
            playback.save = { [weak self] id, seconds, duration in self?.updateLecture(id,quiet:true) { $0.state.record(seconds, ready: true); $0.duration = duration } }
            if watchesEnabled { Task { self.recoverSubtitleLocations(); self.refreshIfDue(startup:true) } }
            if let id = library.lastLecture, library.lectures.contains(where: { $0.id == id }) { open(id) }
        } catch { self.error = "资料库打开失败（未删除或重建）：\(error.localizedDescription)"; fatal = true }
    }
    deinit { refreshTimer?.invalidate() }
    func drainGeneration() async {
        if processing.running {processing.pause(self)} else {translation.pause();analysis.pause()}
        await requests.pause()
        await processing.worker?.value;await translation.task?.value;await analysis.worker?.value
        await translation.writer.flushFiles()
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func persist() { guard !fatal else { return }; perform { try repository?.save(library) } }
    func flushMetadata() {readerPresentation.flush();perform {try repository?.commits.flush()}}
    func updateLecture(_ id: UUID, quiet:Bool=false, _ action: (inout Lecture)->Void) {
        guard let i=library.lectures.firstIndex(where:{$0.id==id}) else{return}
        let old=library.lectures[i];var next=old;action(&next)
        guard old != next else{return}
        quietLibraryUpdate=quiet;library.lectures[i]=next;quietLibraryUpdate=false
        repository?.commits.submit(old:old,new:next) {[weak self] message in if let message {self?.error="设置暂未保存，可重试："+message}}
    }
    func open(_ id: UUID) {
        readerPresentation.flush();captions.flush(); playback.close(); guard let item = library.lectures.first(where: { $0.id == id }) else { return }
        readerPresentation.configure(id,panel:item.studyPanel ?? "transcript");current = id; captions.configure(id,value:item.videoCaptions ?? VideoCaptionPreferences()); transcript = nil; perform { transcript = try repository?.read(item) }; library.lastLecture = id; persist(); playback.load(item)
    }
    func openSelectedDirectory() {
        if let path=library.folders.first(where:{$0.id==selectedFolder})?.directoryPath ?? library.courses.first(where:{$0.id==selectedCourse})?.directoryPath ?? library.directoryRoot {NSWorkspace.shared.open(URL(fileURLWithPath:path))}
    }
    func selectTranslation(_ id:String) {
        guard let lesson=lecture else{return}
        updateLecture(lesson.id){$0.selectedTranslationVariantID=id}
        transcript=transcript?.viewing(id)
    }
    func displayTranscript(_ value:Transcript, for id:UUID) {
        if current==id {transcript=value.viewing(library.lectures.first{$0.id==id}?.selectedTranslationVariantID ?? transcript?.variantID ?? "openAI")}
    }
    func back() { captions.flush(); playback.close(); flushMetadata(); current = nil; transcript = nil }
    func saveTranscript(_ value: Transcript, lectureID: UUID) throws { try repository?.write(value, for: lectureID); if current == lectureID { transcript = value }; saveVisibleTranslations(lectureID) }
    func addCourse(_ name: String) { let course = Course(name: name, order: library.courses.count); library.courses.append(course); selectedCourse = course.id; selectedFolder = nil; persist() }
    func addFolder(_ name: String) { guard let course = selectedCourse else { return }; library.folders.append(Folder(name: name, courseID: course, parentID: selectedFolder)); persist() }
    func importPair(video: URL, subtitle: URL?, title: String) throws {
        guard let courseID = selectedCourse else { throw Failure("请先创建或选择课程") }
        try ImportPlanner.requireLocal(video)
        let identity = try Self.fileIdentity(video)
        guard !library.lectures.contains(where: { $0.identity == identity }) else { throw Failure("此视频已经导入；请使用已有回放或重新定位") }
        let bookmark = try video.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        var lecture = Lecture(title: title, courseID: courseID, folderID: selectedFolder, url: video, bookmark: bookmark, identity: identity)
        lecture.state.speed = UserDefaults.standard.double(forKey: "defaultSpeed") == 0 ? 1 : UserDefaults.standard.double(forKey: "defaultSpeed")
        if let subtitle { try ImportPlanner.requireLocal(subtitle); let t = try SubtitleParser.parse(Data(contentsOf: subtitle), format: subtitle.pathExtension); try repository?.write(t, for: lecture.id); lecture.transcriptVersion = t.version; lecture.subtitlePath = subtitle.path }
        var next = library; next.lectures.append(lecture); try repository?.save(next); library = next
    }
    static func fileIdentity(_ url: URL) throws -> String { let a = try FileManager.default.attributesOfItem(atPath: url.path); return "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? "")" }
    func relocate(sourceID: UUID? = nil) {
        guard let item = lecture, let target = sourceID ?? item.mediaSources.first?.id else { return }
        linkMedia(item.id, sourceID: target)
    }
    func replaceSubtitle() {
        guard !translation.busy else {error="请先暂停翻译或总结，等待保存完成后再更换字幕。";return}
        guard let item = lecture, let url = chooseFiles(types: [.init(filenameExtension: "vtt")!, .init(filenameExtension: "srt")!, .plainText]).first else { return }
        perform {
            try ImportPlanner.requireLocal(url)
            let t = try SubtitleParser.parse(Data(contentsOf: url), format: url.pathExtension)
            if item.transcriptVersion == t.version { updateLecture(item.id) { $0.subtitlePath = url.path }; saveVisibleTranslations(item.id); return }
            let a = NSAlert(); a.messageText = "导入新字幕版本？"; a.informativeText = "旧字幕和译文保留在资料库文件中。新版本不会沿用旧版本的译文映射。"; a.addButton(withTitle: "导入"); a.addButton(withTitle: "取消"); guard a.runModal() == .alertFirstButtonReturn else { return }
            try repository?.write(t, for: item.id); updateLecture(item.id) { $0.transcriptVersion = t.version; $0.subtitlePath = url.path }; transcript = t
        }
    }
}
@MainActor func chooseFiles(types: [UTType], multiple: Bool = false) -> [URL] { let p = NSOpenPanel(); p.allowedContentTypes = types; p.allowsMultipleSelection = multiple; p.canChooseDirectories = false; return p.runModal() == .OK ? p.urls : [] }
@MainActor func askName(_ title: String, initial: String = "") -> String? { let alert = NSAlert(); alert.messageText = title; let input = NSTextField(string: initial); input.frame = NSRect(x:0,y:0,width:300,height:24); alert.accessoryView = input; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消"); alert.window.initialFirstResponder = input; guard alert.runModal() == .alertFirstButtonReturn else { return nil }; let value = input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); return value.isEmpty ? nil : value }
