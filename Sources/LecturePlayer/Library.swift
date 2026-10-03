import AppKit
import SwiftUI
import Core
import UniformTypeIdentifiers

@MainActor final class AppStore: ObservableObject {
    var library = Library() {didSet{if !quietLibraryUpdate {objectWillChange.send(); refreshDirectoryPresentation()}}}
    private var quietLibraryUpdate=false
    let performanceProbe=MainThreadProbe()
    let lessonLoader = LessonLoadCoordinator()
    @Published private(set) var lessonLoading = false
    @Published private(set) var preparedReading: PreparedReading?
    private var lessonLoadTask: Task<Void, Never>?
    private var lessonSwitchAutoplay=false
    private var lessonLoadID = UUID()
    private var applyingLoadedReading = false
    private var readingBuild: Task<Void,Never>?
    private func rebuildPreparedReading() {
        readingBuild?.cancel()
        guard let transcript else {preparedReading=nil;return}
        let id=current, version=transcript.version, cues=transcript.cues
        readingBuild=Task { [weak self] in
            let work=Task.detached(priority:.userInitiated) { PreparedReading(cues) }
            let result=await withTaskCancellationHandler(operation:{await work.value},onCancel:{work.cancel()})
            guard !Task.isCancelled,let self,self.current==id,self.transcript?.version==version else{return}
            self.preparedReading=result
        }
    }
    private var memoryPressure: DispatchSourceMemoryPressure?
    let lessonStatuses=LessonStatusPresentation()
    let usagePresentation=UsagePresentation()
    var usageCache:UsageDataset?
    var usageCacheToken=""
    let navigation=DirectoryPresentation()
    let readerPresentation=ReaderPresentationState()
     @Published var transcript: Transcript? { didSet { if !applyingLoadedReading && oldValue?.cues != transcript?.cues { rebuildPreparedReading() } } }; @Published var current: UUID?; var selectedCourse:UUID? {get{navigation.course} set{navigation.course=newValue}}
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
    var fileSaveTasks:[UUID:Task<Void,Never>]=[:]
    var fileSavePending:[UUID:Bool]=[:]
    var rescanRequested = false
    var scanTask: Task<Void, Never>?
    var rootGeneration = UUID()
    var watchesEnabled = true
    let captions = CaptionPresentation()
    let pipPreferences: PictureInPicturePreferences
    let captionPreferences:GlobalCaptionPreferences
    let playlist=CoursePlaylistPresentation()
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
    init(root explicitRoot: URL? = nil,preferences:UserDefaults? = nil) {
        let defaults=preferences ?? explicitRoot.flatMap{UserDefaults(suiteName:"local.LecturePlayer.Isolated."+digest($0.path))} ?? .standard
        pipPreferences=PictureInPicturePreferences(defaults:defaults)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [lessonLoader] in Task { await lessonLoader.clear() } }; pressure.resume(); memoryPressure = pressure
        captionPreferences=GlobalCaptionPreferences(defaults:defaults)
        do {
            let root = explicitRoot ?? ProcessInfo.processInfo.environment["LECTURE_PLAYER_DATA"].map { URL(fileURLWithPath: $0) } ?? (Bundle.main.object(forInfoDictionaryKey: "LecturePlayerDataRoot") as? String).map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LecturePlayer")
            watchesEnabled = explicitRoot == nil && Bundle.main.object(forInfoDictionaryKey: "LecturePlayerDisableAutomaticMaintenance") as? Bool != true
            fingerprints=MediaFingerprintCache(storage:root.appendingPathComponent("Cache/media-fingerprints.json"))
            repository = try Repository(root: root); repository?.onWriteFailure = {[weak self] in self?.storageFailed($0)}; library = try repository!.load(); refreshDirectoryPresentation(); selectedCourse = library.courses.filter { $0.directoryPath != nil }.sorted { $0.order < $1.order }.first?.id
            if watchesEnabled {
                refreshPolicy=RefreshPolicy(rawValue:UserDefaults.standard.string(forKey:"directoryRefreshPolicy") ?? "automatic") ?? .automatic
                lastDirectoryAttempt=UserDefaults.standard.object(forKey:refreshPreferenceKey) as? Date
                scanSummary=UserDefaults.standard.string(forKey:refreshPreferenceKey+"-result") ?? "尚未扫描"
            }
            readerPresentation.save = {[weak self] id,panel in self?.updateLecture(id,quiet:true){$0.studyPanel=panel}}
            captionPreferences.initialize(legacy:library.lectures.first{$0.id==library.lastLecture}?.videoCaptions)
            captions.save = { [weak self] _,value in self?.captionPreferences.save(value) }
            translation.restore(self);processing.restore(self)
            Task { [weak self] in await self?.translation.writer.observeFailures { [weak self] _,error in self?.storageFailed(error) } }
            Task { [weak self] in await self?.translation.writer.observeFiles { [weak self] id,saved in
                guard let self,let lesson=self.library.lectures.first(where:{$0.id==id}),lesson.transcriptVersion==saved.transcript.version else{return}
                self.displayTranscript(saved.transcript,for:id)
                self.updateLecture(id){if let files=saved.sidecars {$0.sidecars=files};$0.sidecarStatus=saved.fileStatus;$0.generatedFilePaths=saved.currentFilePaths}
            }}
            directoryWatch.changed = { [weak self] in guard let self,self.refreshPolicy == .automatic else { return };self.refreshDirectory() }
            configureRefreshSchedule()
            playback.completionChanged = { [weak self] id,finished in self?.updateLecture(id,quiet:true){$0.finished=finished} }
            playback.save = { [weak self] id, seconds, duration in self?.updateLecture(id,quiet:true) { $0.state.record(seconds, ready: true); $0.duration = duration } }
            if watchesEnabled { Task { self.recoverSubtitleLocations(); self.refreshIfDue(startup:true) } }
            if let id = library.lastLecture, library.lectures.contains(where: { $0.id == id }) { open(id) }
        } catch { self.error = "资料库打开失败（未删除或重建）：\(error.localizedDescription)"; fatal = true }
    }
    deinit { refreshTimer?.invalidate(); lessonLoadTask?.cancel(); memoryPressure?.cancel() }
    func drainGeneration() async {
        if processing.running {processing.pause(self)} else {translation.pause();analysis.pause()}
        await requests.pause()
        await processing.worker?.value;await translation.task?.value;await analysis.worker?.value
        await translation.writer.flushFiles()
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func storageFailed(_ failure:Error) {
        if processing.running {processing.pause(self)}
        translation.pause();analysis.pause()
        Task {await requests.pause()}
        error="资料保存失败，已停止新的翻译和总结请求；待保存内容已保留。"+StorageIssue(failure).localizedDescription
        if let root=repository?.root {StorageDiagnostics.record(root:root,operation:.metadata,outcome:.failed,error:failure)}
    }
    func persist() {guard !fatal else{return};do {try repository?.save(library)}catch{storageFailed(error)}}
    func flushMetadataAsync() async { readerPresentation.flush(); do { try await repository?.commits.flushAsync() } catch { storageFailed(error) } }
    func flushMetadata() {readerPresentation.flush();do{try repository?.commits.flush()}catch{storageFailed(error)}}
    func updateLecture(_ id: UUID, quiet:Bool=false, _ action: (inout Lecture)->Void) {
        guard let i=library.lectures.firstIndex(where:{$0.id==id}) else{return}
        let old=library.lectures[i];var next=old;action(&next)
        guard old != next else{return}
        quietLibraryUpdate=quiet;library.lectures[i]=next;quietLibraryUpdate=false
        playlist.updateRow(next)
        repository?.commits.submit(old:old,new:next) {[weak self] message in if let message {self?.storageFailed(message)}}
    }
    func open(_ id: UUID) {openLesson(id,autoplay:false,restart:false)}
    private func openLesson(_ id:UUID,autoplay:Bool,restart:Bool) {
        let started = ProcessInfo.processInfo.systemUptime
        guard let item=library.lectures.first(where:{$0.id==id}), let root=repository?.root else{return}
        pipPreferences.flush(); readerPresentation.flush(); captions.flush(); playback.close()
        lessonLoadTask?.cancel(); let loadID=UUID(); lessonLoadID=loadID
        readerPresentation.configure(id,panel:item.studyPanel ?? "transcript")
        lessonSwitchAutoplay=autoplay;current=id; captions.configure(id,value:captionPreferences.value); transcript=nil; preparedReading=nil; lessonLoading=true
        quietLibraryUpdate=true; library.lastLecture=id; quietLibraryUpdate=false
        repository?.commits.setLastLesson(id) { [weak self] failure in if let failure { self?.storageFailed(failure) } }
        PerformanceTrace.record("lesson.initialState", ProcessInfo.processInfo.systemUptime-started)
        // Let SwiftUI paint the new title before starting any media setup.
        lessonLoadTask = Task { [weak self, lessonLoader] in
            await Task.yield()
            guard let self, self.lessonLoadID == loadID, !Task.isCancelled else { return }
            self.playback.load(item,autoplay:autoplay,restart:restart)
            do {
                let loaded = try await lessonLoader.load(item,root:root)
                guard self.lessonLoadID == loadID, !Task.isCancelled else { return }
                // A background translation may have delivered a newer revision while loading.
                if self.transcript == nil { self.applyingLoadedReading=true; self.preparedReading=loaded.reading; self.transcript=loaded.transcript; self.applyingLoadedReading=false }
                self.lessonLoading=false
                PerformanceTrace.record("lesson.readyReading",ProcessInfo.processInfo.systemUptime-started)
            } catch is CancellationError { }
            catch { guard self.lessonLoadID == loadID else { return }; self.lessonLoading=false; self.error="转写暂时无法载入："+error.localizedDescription }
        }
    }
    @discardableResult func switchFromPlaylist(to id:UUID)->Bool {
        guard let active=lecture,let target=library.lectures.first(where:{$0.id==id}),target.courseID==active.courseID,target.archived != true else{return false}
        if id==current {return true}
        let autoplay=lessonLoading ? lessonSwitchAutoplay : playback.shouldContinueOnSwitch
        openLesson(id,autoplay:autoplay,restart:target.finished)
        return true
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
        if library.lectures.first(where:{$0.id==id})?.transcriptVersion==value.version {lessonStatuses.accept(value,for:id)}
        if current==id {transcript=value.viewing(library.lectures.first{$0.id==id}?.selectedTranslationVariantID ?? transcript?.variantID ?? "openAI")}
    }
    func back() { lessonLoadTask?.cancel(); lessonLoadID=UUID(); lessonLoading=false; pipPreferences.flush(); readerPresentation.flush(); captions.flush(); playback.close(); current = nil; transcript = nil; preparedReading=nil }
    func saveTranscript(_ value: Transcript, lectureID: UUID) throws { try repository?.write(value, for: lectureID); displayTranscript(value,for:lectureID); saveVisibleTranslations(lectureID) }
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
