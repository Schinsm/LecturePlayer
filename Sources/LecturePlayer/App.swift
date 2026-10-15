import SwiftUI
import AppKit
import AVKit
import Core

typealias LPState<Value> = SwiftUI.State<Value>

@main struct LecturePlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("Lecture Player", id: "main") { RootView(store: store).onAppear{delegate.drainBeforeTerminate={await store.drainGeneration()};delegate.beforeTerminate={store.readingColumns.flush();store.pipPreferences.flush();store.captions.flush();store.readerPresentation.flush();store.playback.persist();try store.repository?.commits.flush()}}.frame(minWidth: 900, minHeight: 560).background(WindowPersistence()).onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.readingColumns.flush();store.pipPreferences.flush();store.captions.flush(); store.playback.persist(); store.flushMetadata(); store.analysis.cancel();store.translation.cancel();store.processing.worker?.cancel() }.onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in store.readingColumns.flush();store.pipPreferences.flush();store.captions.flush(); store.playback.persist(); store.flushMetadata() } }.defaultSize(width:1200,height:780)
        Settings { PreferencesView(store:store) }
        .commands { CommandGroup(after:.newItem) {Button("在 Finder 打开当前目录"){store.openSelectedDirectory()}.disabled(store.library.directoryRoot==nil)}
            CommandGroup(after:.sidebar) {
                ReaderColumnsMenu(columns:store.readingColumns).disabled(store.current==nil)
            }
        }
    }
}
struct RootView: View {
    @ObservedObject var store: AppStore
    @AppStorage("appearance") var appearance="系统"
    @LPState private var importing = false
    @ObservedObject private var onboarding=OnboardingPresentation.shared
    @LPState private var dropped:[URL] = []
    var body: some View {
        Group { if store.fatal { ContentUnavailableView("无法打开资料库", systemImage:"exclamationmark.triangle",description:Text(store.error ?? "")) } else if store.current != nil { PlayerPage(store:store) } else { LibraryPage(store:store, importing:$importing) } }
            .background(LocalTranslationHost(job:store.translation))
            .preferredColorScheme(appearance=="深色" ? .dark : appearance=="浅色" ? .light : nil)
            .toolbar { if store.current == nil {
                Menu { Button("查看待导入") { dropped=store.directoryFiles;importing=true }; Button("选择文件…") { dropped=chooseFiles(types:[.mpeg4Movie,.quickTimeMovie,.init(filenameExtension:"vtt")!,.init(filenameExtension:"srt")!,.plainText],multiple:true);if !dropped.isEmpty { importing=true } } } label: { Image(systemName:"plus") }.help("导入课件").accessibilityLabel("导入课件").disabled(store.library.directoryRoot == nil)
            } }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in store.refreshIfDue() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didWakeNotification)) { _ in store.refreshIfDue() }
            .onAppear { if !store.fatal { onboarding.presentIfNeeded(library:store.library) } }
            .sheet(isPresented:$onboarding.showing) { OnboardingView(store:store) }
            .sheet(isPresented: $store.showingLocations) { DataLocations(store: store) }
            .sheet(isPresented:$importing) { ImportView(store:store, initialURLs:dropped) }
            .dropDestination(for:URL.self) {urls,_ in guard store.current == nil,(store.selectedCourse != nil || store.library.directoryRoot != nil) else{return false};dropped=urls;importing=true;return true}
            .alert("操作未完成",isPresented:Binding(get:{ store.error != nil },set:{ if !$0 { store.error = nil } })) { if store.error?.hasPrefix("设置暂未保存") == true {Button("重试保存"){store.error=nil;store.flushMetadata()}};Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
struct LibraryPage: View {
    @ObservedObject var store: AppStore; @Binding var importing: Bool
    @LPState private var search = ""; @LPState private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.openSettings) private var openSettings
    @LPState private var details: LessonSelection?
    @LPState private var selectedLessons = Set<UUID>()
    @LPState private var chapterBatch = false
    @LPState private var expandedSeries = Set<String>()
    @LPState private var fileLesson:LessonSelection?
    @LPState private var analysisLesson:LessonSelection?
    @ObservedObject var navigation:DirectoryPresentation
    init(store:AppStore,importing:Binding<Bool>){self.store=store;_importing=importing;navigation=store.navigation}
    var courses: [Course] { store.library.courses.filter { $0.directoryPath?.hasPrefix((store.library.directoryRoot ?? "") + "/") == true }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var items: [Lecture] { store.library.lectures.filter { item in
        let location = store.selectedCourse == nil ? item.directoryPath == nil : item.directoryPath != nil && item.courseID == store.selectedCourse && (store.selectedFolder == nil || (item.directoryPath.map { DirectoryIndex.contains($0, in: selectedPath ?? "") } ?? false))
        return location && item.archived != true && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var selectedPath: String? { store.library.folders.first { $0.id == store.selectedFolder }?.directoryPath ?? store.library.courses.first { $0.id == store.selectedCourse }?.directoryPath }
    var candidates: [[URL]] { navigation.index.pending.filter { group in
        guard let path = selectedPath else { return false }
        return group.contains { DirectoryIndex.contains($0.path, in: path) } && (search.isEmpty || group.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(search) })
    } }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            DirectorySidebar(navigation:navigation,store:store)
        } detail: {
            if navigation.weekHome { WeekHome(store:store) } else { coursePage }
        }.navigationTitle(navigation.weekHome ? "按周" : store.library.folders.first{$0.id==store.selectedFolder}?.name ?? store.library.courses.first{$0.id==store.selectedCourse}?.name ?? "课程库")
        .toolbar(removing: .sidebarToggle).toolbar {
            if !navigation.weekHome {
                ToolbarItem {TextField("搜索课件",text:$search).textFieldStyle(.roundedBorder).frame(width:210)}
                ToolbarItem {
                    Menu {
                        Button("全选本页") {selectedLessons.formUnion(items.map(\.id))}.disabled(items.isEmpty)
                        Button("清除选择") {selectedLessons.removeAll()}.disabled(selectedLessons.isEmpty)
                        Divider()
                        Button("为选中的 \(selectedLessons.count) 堂生成章节…") {chapterBatch=true}.disabled(selectedLessons.isEmpty)
                        Button("展开全部系列") {expandedSeries=Set(LessonCatalog.groups(items).filter(\.isSeries).map(\.id))}
                        Button("收起全部系列") {expandedSeries=[]}
                    } label: {Image(systemName:"ellipsis.circle")}.help("批量操作").accessibilityLabel("批量操作")
                }
            }
            ToolbarItem {Button {store.refreshDirectory()} label:{Group {if store.scanning {ProgressView().controlSize(.small)} else {Image(systemName:"arrow.clockwise")}}.frame(width:18,height:18)}.help("刷新课程目录").accessibilityLabel("刷新课程目录").disabled(store.scanning || store.library.directoryRoot==nil)}
            ToolbarItem(placement: .navigation) {
                Button { visibility = visibility == .detailOnly ? .all : .detailOnly } label: { Image(systemName: "sidebar.left") }.help("显示或隐藏课程目录").accessibilityLabel("显示或隐藏课程目录")
            }
        }.sheet(item: $details) { LessonDetails(store: store, ids: $0.ids) }
        .sheet(isPresented:$chapterBatch) {ChapterBatchConfirmation(store:store,ids:selectedLessons)}
        .sheet(item:$fileLesson) {selection in DataLocations(store:store,lessonID:selection.ids.first)}
        .sheet(item:$analysisLesson) {selection in if let id=selection.ids.first {AnalysisConfirmation(store:store,job:store.analysis,translation:store.translation,lessonID:id)}}
    }
    private var coursePage: some View {
            VStack(alignment: .leading, spacing: 14) {
                if !store.scanIssues.isEmpty { DisclosureGroup("扫描遇到问题") { ScrollView { Text(store.scanIssues.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100) } }
                if !store.pendingFiles.isEmpty { Button("导入课件…") { importing = true } }
                if store.selectedCourse == nil && store.unlinkedCount > 0 { Text("在课件详情中重新关联已移动的视频。").font(.caption).foregroundStyle(.secondary) }
                if !selectedLessons.isEmpty {
                    HStack {
                        Text("已选 \(selectedLessons.count) 堂").font(.caption)
                        Button("清除选择") {selectedLessons.removeAll()}
                        Button("生成章节…") {chapterBatch=true}
                        Spacer()
                    }.buttonStyle(.borderless)
                }
                if importing {Text(store.importStatus).font(.caption).foregroundStyle(.secondary)}
            TransferStatus(transfer: store.transfer)
                if items.isEmpty && candidates.isEmpty {
                    VStack(spacing:12) {
                        ContentUnavailableView(store.library.directoryRoot == nil ? "选择课程总目录" : search.isEmpty ? "此目录暂无课件" : "没有匹配的课件",systemImage:search.isEmpty ? "folder" : "magnifyingglass",description:Text(store.library.directoryRoot == nil ? "在设置的资料库页面选择视频与字幕总目录。" : search.isEmpty ? "将视频与英文字幕放入此文件夹，确认导入后开始学习。" : "换一个关键词试试。"))
                        if store.library.directoryRoot == nil {Button("打开设置"){openSettings()}}
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                List {
                ForEach(candidates, id: \.self) { group in
                    HStack { VStack(alignment: .leading) { Text(group[0].deletingPathExtension().lastPathComponent); Text(group[0].deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("预览") { importing = true } }
                }
                ForEach(LessonCatalog.sections(items)) { section in
                    Section {
                        ForEach(section.groups) { group in
                            if group.isSeries {
                                seriesRow(group)
                                if expandedSeries.contains(group.id) {
                                    ForEach(group.lessons) { lessonRow($0).padding(.leading, 30) }
                                }
                            } else { lessonRow(group.lessons[0]) }
                        }
                    } header: {
                        Text(section.week.map { "Week \($0)" } ?? "未分周").font(.title3.weight(.semibold)).foregroundStyle(.primary).padding(.top, 6)
                    }
                }
                }.listStyle(.plain)
                }
            }.padding(20)
    }
    private func lessonRow(_ item: Lecture) -> some View {
        HStack {
                Toggle("选择 " + item.title,isOn:Binding(get:{selectedLessons.contains(item.id)},set:{if $0 {selectedLessons.insert(item.id)} else {selectedLessons.remove(item.id)}})).labelsHidden().toggleStyle(.checkbox)
                Button {store.open(item.id)} label:{LessonThumbnail(lesson:item)}.buttonStyle(.plain).accessibilityLabel("播放 " + item.title)
                VStack(alignment:.leading,spacing:6) {
                Button { store.open(item.id) } label: { VStack(alignment: .leading, spacing: 4) {
                    Text(LessonCatalog.displayTitle(item)).font(.headline)
                    HStack(spacing: 6) {
                        if item.duration > 0 { Text(timeLabel(item.duration)).monospacedDigit() }
                        if item.mediaSources.count > 1 { Image(systemName: "rectangle.on.rectangle").help("两路视频") }
                    }.foregroundStyle(.secondary)
                } }.buttonStyle(.plain).help(item.title + (item.directoryPath.map { "\n" + $0 } ?? ""))
                LessonWorkStatus(store:store,lesson:item)
                }
                if navigation.missing.contains(item.id) { Button("缺失视角 · 重新关联") { details = LessonSelection(ids: [item.id]) }.font(.caption).foregroundStyle(.orange) }
                if store.scanConflicts[item.id] != nil { Button("归属冲突") { store.chooseDirectory(item.id) } }
                Spacer()
                ProgressRing(value: LessonCatalog.isWatched(item) ? 1 : item.duration > 0 ? min(1, item.state.position / item.duration) : 0)
                Button { store.open(item.id) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain)
            }.padding(.vertical, 8).contextMenu {
                Button("课件详情…") { details = LessonSelection(ids: [item.id]) }
                Button("添加第二路视频…") { store.addSecondVideo(item.id) }.disabled(item.mediaSources.count == 2)
                Button("作为主条目合并双视频…") { store.chooseMerge(primaryID: item.id) }.disabled(item.mediaSources.count != 1)
                Button("本课文件…") {fileLesson=LessonSelection(ids:[item.id])}
                LessonAnalysisMenuAction(store:store,lesson:item) {analysisLesson=LessonSelection(ids:[item.id])}
            }
    }
    /// Durations are known only after a part has been opened once; show the total only when all are known.
    private func seriesLength(_ group: LessonGroup) -> String {
        group.lessons.allSatisfy { $0.duration > 0 } ? "\(group.lessons.count) 段 · " + timeLabel(group.lessons.reduce(0) { $0 + $1.duration }) : "\(group.lessons.count) 段"
    }
    /// One row for a stacked series; expands to show each part.
    private func seriesRow(_ group: LessonGroup) -> some View {
        let open = expandedSeries.contains(group.id)
        let color = store.courseColor(group.courseID).color
        return HStack(spacing: 14) {
            Button { if open { expandedSeries.remove(group.id) } else { expandedSeries.insert(group.id) } } label: {
                HStack(spacing: 14) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.3)).frame(width: 100, height: 14).offset(y: -7)
                        RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.55)).frame(width: 114, height: 14).offset(y: -3.5)
                        ZStack {
                            color.opacity(0.6)
                            if let lead = group.next { LessonThumbnail(lesson: lead) }
                        }.frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            Text("\(group.lessons.count) 段").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.35), in: Capsule()).padding(5)
                        }
                    }.padding(.top, 7)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.headline)
                            if let range = group.partRange { Text(range).foregroundStyle(.secondary) }
                        }
                        Text(seriesLength(group)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SeriesSegments(lessons: group.lessons, width: 22)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.title + "，\(group.lessons.count) 段，已看 \(group.watchedCount)，" + (open ? "收起" : "展开"))
            if let next = group.next {
                Button { store.open(next.id) } label: { Label(group.partLabel(next), systemImage: "play.fill") }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityLabel("继续 " + group.partLabel(next))
            }
        }.padding(.vertical, 8)
    }
    func courseButton(_ course:Course)->some View {
        Button { store.selectedCourse=course.id;store.selectedFolder=nil } label: { Label(course.name,systemImage:"folder").lineLimit(1).help(course.name).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain).contextMenu {Button("在 Finder 打开"){if let path=course.directoryPath {NSWorkspace.shared.open(URL(fileURLWithPath:path))}}}
    }

}
struct DirectoryBranch: View {
    @ObservedObject var store: AppStore; let course: UUID; let parent: UUID?
    var body: some View {
        ForEach(store.library.folders.filter { $0.courseID == course && $0.parentID == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
            Group {
                if store.library.folders.contains(where: { $0.parentID == folder.id }) {
                    DisclosureGroup { DirectoryBranch(store:store,course:course,parent:folder.id) } label: { folderButton(folder) }
                } else { folderButton(folder) }
            }.listRowBackground(store.selectedFolder == folder.id ? Color.accentColor.opacity(0.16) : Color.clear)
        }
    }
    func folderButton(_ folder:Folder)->some View {
        Button { store.selectedCourse=course;store.selectedFolder=folder.id } label: { Label(folder.name,systemImage:"folder").lineLimit(1).help(folder.name).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain).contextMenu {Button("在 Finder 打开"){if let path=folder.directoryPath {NSWorkspace.shared.open(URL(fileURLWithPath:path))}}}
    }

}
struct ImportRow: Identifiable {
    var relinkSourceID: UUID?; var existingID: UUID?; var id = UUID(); var video: URL; var subtitle: URL?; var title: String
    var secondary: URL?; var role: MediaRole = .screen; var week: Int?; var sessionType = "Lecture"; var topic = ""; var customTitle = true
}
struct ImportView: View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    @ObservedObject var store: AppStore; @Environment(\.dismiss) var dismiss
    @LPState var rows: [ImportRow] = []; @LPState var message = ""; var initialURLs: [URL] = []; @LPState var files: [URL] = []
    @AppStorage("importAutoProcess") private var autoProcess=false
    @LPState private var costExpanded=true
    @AppStorage(ImportStepPlan.translateKey) private var translateStep=true
    @AppStorage(ImportStepPlan.chaptersKey) private var chaptersStep=true
    @LPState private var analysisPreviews:[ImportAnalysisPreview]=[]
    @LPState private var previews:[ImportTranslationPreview]=[]
    @LPState private var previewError=""
    @AppStorage("translationService") private var selectedService = "openAI"
    @Environment(\.openSettings) private var openSettings
    private var provider:TranslationService {TranslationService(rawValue:selectedService) ?? .openAI}
    private var hasKey:Bool {keyAvailability.state(provider).isAvailable}
    @LPState private var managed = false; @LPState private var importing = false
    private var translationAvailability:ImportStepPlan.Availability {
        if !translateStep {return .disabled}
        if store.translation.busy {return .unavailable("已有翻译任务在运行")}
        return credential(provider)
    }
    private var chaptersAvailability:ImportStepPlan.Availability {
        if !chaptersStep {return .disabled}
        if store.translation.busy {return .unavailable("已有翻译任务在运行")}
        return credential(.openAI)
    }
    private func credential(_ service:TranslationService)->ImportStepPlan.Availability {
        let state=keyAvailability.state(service)
        if state.isAvailable {return .ready}
        return .unavailable(state == .checking ? "正在检查 \(service.title) 凭据" : service.title + " 未就绪")
    }
    private func stepPlan(_ row:ImportRow)->ImportStepPlan {
        let hasPreview=previews.contains {$0.rowID==row.id}
        return ImportStepPlan.make(existing:row.existingID != nil,hasSubtitle:row.subtitle != nil && hasPreview,
            translation:translationAvailability,chapters:chaptersAvailability)
    }
    private var autoTranslate:Bool {autoProcess && translationAvailability == .ready && !previews.isEmpty}
    private var autoAnalyze:Bool {autoProcess && chaptersAvailability == .ready && !analysisPreviews.isEmpty}
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入预览").font(.title2)
            Text("引用实际文件夹中的文件，不复制或移动源文件。").font(.caption)
            Text("每行是一堂课。第二视角需要明确指定；原视频与字幕保持不变。").font(.caption)
            HStack {
                Button("选择视频与字幕…") { addFiles(chooseFiles(types: [.mpeg4Movie,.quickTimeMovie,.init(filenameExtension:"vtt")!,.init(filenameExtension:"srt")!,.plainText], multiple: true)) }
                Button("选择课程文件夹…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK { addFiles(panel.urls) } }
            }
            ScrollView {
                VStack(spacing: 20) {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text((row.existingID == nil ? "" : row.relinkSourceID != nil ? "重新关联原课件 · " : "添加至已有课件 · ") + row.video.lastPathComponent).font(.headline); Spacer(); Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") } }
                            if row.existingID == nil {
                            Toggle("自定义显示标题", isOn: $row.customTitle)
                            if row.customTitle { TextField("标题", text: $row.title) }
                            HStack {
                                Picker("第一视角", selection: $row.role) { ForEach(MediaRole.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 180)
                                Button(row.secondary?.lastPathComponent ?? "添加第二视角…") { if let chosen = chooseFiles(types: [.mpeg4Movie,.quickTimeMovie]).first {
                                    guard chosen != row.video else { message = "请选择不同的视频作为第二视角"; return }
                                    let rowID = row.id; row.secondary = chosen; rows.removeAll { $0.id != rowID && $0.video == chosen }
                                } }
                                if row.secondary != nil { Button("移除第二视角") { row.secondary = nil } }
                            }
                            Button(row.subtitle?.lastPathComponent ?? "选择字幕…") { row.subtitle = chooseFiles(types: [.init(filenameExtension:"vtt")!,.init(filenameExtension:"srt")!,.plainText]).first }
                            } else if let sourceID = row.relinkSourceID, let lesson = store.library.lectures.first(where: { $0.id == row.existingID }), let source = lesson.mediaSources.first(where: { $0.id == sourceID }) {
                                Text("原课件：" + lesson.title)
                                Text("原位置：" + source.path + "\n新位置：" + row.video.path).font(.caption).textSelection(.enabled)
                                Text(source.contentHash == nil ? "候选依据：相同原文件名。缺少旧内容校验值，请确认这是原视频；确认后保留原进度与译文。" : "候选依据：文件名或内容校验。提交前核验内容一致，保留原进度与译文。").font(.caption).foregroundStyle(.orange)
                            } else { Text("识别为" + row.role.rawValue + "，添加至原课件；保留标题、进度、字幕和译文。角色可在课件详情调整。").font(.caption) }
                            Label(autoProcess ? stepPlan(row).label : "只导入",systemImage:autoProcess && !stepPlan(row).steps.isEmpty ? "arrow.triangle.branch" : "tray.and.arrow.down")
                                .font(.caption).foregroundStyle(.secondary).accessibilityLabel("导入后：" + (autoProcess ? stepPlan(row).label : "只导入"))
                        }.padding(12).background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight:240)
            HStack(alignment:.firstTextBaseline) {
                VStack(alignment:.leading,spacing:2) {
                    Toggle("导入后自动处理",isOn:$autoProcess).toggleStyle(.switch)
                    Text("按每行显示的步骤排队执行；已有的内容不会重做。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("处理步骤设置…") {PreferencesNavigation.shared.requested = .library;openSettings()}.buttonStyle(.link)
            }
            if autoTranslate || autoAnalyze {
                DisclosureGroup("预计费用与请求明细",isExpanded:$costExpanded) {
                    ScrollView {
                        VStack(alignment:.leading,spacing:8) {
                            if autoAnalyze {Text(analysisPreviews.map(\.summary).joined(separator:"\n"))}
                            if autoTranslate {Text(previews.map(\.summary).joined(separator:"\n"));Text("确认后按导入顺序翻译；异常暂停整个队列，不自动补译。")}
                        }.font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:110)
                }.font(.caption)
            }
            if !keyAvailability.state(.openAI).isAvailable { credentialStatus(.openAI, purpose:provider == .openAI ? "翻译与总结":"总结") }
            if store.translation.busy {Text("已有翻译任务正在运行；本次仍可正常导入，之后再开始翻译。").font(.caption)}
            if !hasKey && provider != .openAI { credentialStatus(provider,purpose:"翻译") }
            if previews.isEmpty {Text("没有可自动翻译的新课件字幕；关联原课件不会触发翻译。").font(.caption)}
            if !previewError.isEmpty {Text(previewError).font(.caption).foregroundStyle(.orange)}
            Text(message).foregroundStyle(.red)
            TransferStatus(transfer: store.transfer)
            HStack { Button("关闭") { dismiss() }.disabled(importing); Spacer(); Button(autoTranslate || autoAnalyze ? "确认导入并开始所选处理" : "确认 \(rows.count) 项关联与导入") { importAll() }.disabled(rows.isEmpty || importing) }
        }.padding(24).frame(width: 800, height: 620).onAppear {refreshCredentials();addFiles(initialURLs.isEmpty ? store.directoryFiles : initialURLs)}
        .task(id:selectedService + rows.map { $0.id.uuidString + ($0.subtitle?.path ?? "") }.joined()) {refreshTranslationPreview()}
        .onChange(of:selectedService) {_,_ in refreshCredentials()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in refreshCredentials()}
        .interactiveDismissDisabled(importing)
    }
    private func refreshCredentials() {
        keyAvailability.refresh(provider)
        if provider != .openAI {keyAvailability.refresh(.openAI)}
    }
    @ViewBuilder private func credentialStatus(_ service:TranslationService,purpose:String)->some View {
        let status=keyAvailability.state(service)
        HStack {
            if status == .checking {ProgressView().controlSize(.small)}
            Text(service.title + " · " + purpose + "：" + status.message).font(.caption)
            if status == .authorizationRequired {Button("授权读取"){keyAvailability.authorize(service)}}
            else if status == .missing {Button("打开设置"){openSettings()}}
            else if status != .checking {Button("重新检查"){keyAvailability.invalidate(service)}}
        }
    }
    func addFiles(_ urls: [URL]) {
        do { files = Array(Set(files + (try ImportPlanner.scan(urls))))
            for url in files.sorted(by: { (ImportPlanner.role(for: $0) == .screen ? 0 : 1) < (ImportPlanner.role(for: $1) == .screen ? 0 : 1) }) where ImportPlanner.media.contains(url.pathExtension.lowercased()) && !rows.contains(where: { $0.video == url || $0.secondary == url }) {
                let identity = try AppStore.fileIdentity(url)
                guard !store.library.lectures.contains(where: { $0.mediaSources.contains { $0.identity == identity } }) else { continue }
                let hash = store.scanResult?.media.first { $0.url == url }?.hash
                let previous = store.library.lectures.flatMap { lesson in lesson.mediaSources.filter { source in
                    (hash != nil && source.contentHash == hash) || (!FileManager.default.fileExists(atPath: source.path) && source.originalFilename == url.lastPathComponent)
                }.map { (lesson.id, $0.id) } }
                if previous.count > 1 { message = "多个原课件可能匹配 \(url.lastPathComponent)，请在课件详情中选择要重新关联的原课件。"; continue }
                if let match = previous.first {
                    var row = ImportRow(video: url, title: url.deletingPathExtension().lastPathComponent); row.existingID = match.0; row.relinkSourceID = match.1; rows.append(row); continue
                }
                let companion = ImportPlanner.companion(for: url, in: files)
                let existing = companion.flatMap { other in store.library.lectures.first { $0.mediaSources.count == 1 && $0.path == other.path } }
                let candidates = ImportPlanner.candidates(for: url, in: files)
                var row = ImportRow(video: url, subtitle: candidates.count == 1 ? candidates[0] : nil, title: url.deletingPathExtension().lastPathComponent)
                row.role = ImportPlanner.role(for: url) ?? .screen; row.existingID = existing?.id
                if existing == nil { row.secondary = companion.flatMap { other in
                    let used = store.library.lectures.contains { $0.mediaSources.contains { $0.identity == (try? AppStore.fileIdentity(other)) || ($0.originalFilename == other.lastPathComponent && !FileManager.default.fileExists(atPath: $0.path)) } }
                    return used ? nil : other
                } }
                rows.append(row)
            }
        } catch { message = error.localizedDescription }
    }
    func refreshTranslationPreview() {
        previews=[];analysisPreviews=[];previewError=""
        for row in rows where row.existingID == nil {
            guard let url=row.subtitle else{continue}
            do {
                let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let t=try SubtitleParser.parse(Data(contentsOf:url),format:url.pathExtension)
                guard !t.cues.isEmpty else{continue}
                let analysisConfig=AnalysisPreferences.load()
                let analysisTask=AnalysisTaskState(config:analysisConfig,plan:try AnalysisPlan.make(t))
                analysisPreviews.append(ImportAnalysisPreview(rowID:row.id,task:analysisTask,summary:row.title+" · 总结\n"+analysisConfig.selectionDescription+"\n"+analysisTask.plan.estimate(config:analysisConfig)))
                let config=TranslationPreferences.load(.standard,glossary:(store.library.courses.first { course in course.directoryPath.map {DirectoryIndex.contains(row.video.path,in:$0)} ?? false } ?? store.library.courses.first{$0.id==store.selectedCourse})?.glossary ?? "")
                let batches=config.batches(t)
                let cost=try config.estimate(batches)
                previews.append(ImportTranslationPreview(rowID:row.id,transcript:t,config:config,summary:"\(row.title)：\(t.cues.count) 条 · \(batches.count) 次 · \(config.providerID.title) · \(config.displayModel) · \(cost)"))
            }catch{previewError="部分字幕无法预览翻译："+error.localizedDescription}
        }
    }
    func importAll() {
        importing=true;message=""
        let confirmed=autoTranslate && !store.translation.busy ? previews : []
        let confirmedAnalysis=autoAnalyze && !store.translation.busy ? analysisPreviews : []
        Task { @MainActor in
            defer{importing=false}
            do {
                if !confirmed.isEmpty {
                    guard confirmed.allSatisfy({$0.config.providerID == provider}) else {throw Failure("服务已改变，请重新确认。")}
                    let status=await keyAvailability.validate(provider)
                    guard status.isAvailable else {throw Failure(provider.title + "：" + status.message)}
                }
                if !confirmedAnalysis.isEmpty {
                    let status=await keyAvailability.validate(.openAI)
                    guard status.isAvailable else {throw Failure("OpenAI：" + status.message)}
                }
                guard confirmed.allSatisfy({$0.config.providerID == provider}) else {throw Failure("服务已改变，请重新确认。")}
                for row in rows {
                    if let id=row.existingID,let sourceID=row.relinkSourceID {try await store.relinkMedia(id,sourceID:sourceID,url:row.video)}
                    else if let id=row.existingID {try await store.attachSecond(id,url:row.video)}
                    else {
                        let id=try await store.importLesson(row:row,managed:false)
                        let preview=confirmed.first(where:{$0.rowID==row.id})
                        let analysis=confirmedAnalysis.first(where:{$0.rowID==row.id})
                        if preview != nil || analysis != nil {
                            let task=preview.map {TranslationTaskState(transcript:$0.transcript,ids:$0.transcript.cues.map(\.id),config:$0.config)}
                            try store.processing.launch([ImportProcessingEntry(id:id,translation:task,analysis:analysis?.task)],store:store,deferIfPaused:true)
                        }
                    }
                    rows.removeAll{$0.id==row.id}
                }
            }catch{message=error is CancellationError ? "已取消；仅成功导入的课件进入队列。" : error.localizedDescription}
            store.refreshDirectory();if rows.isEmpty && message.isEmpty {dismiss()}
        }
    }
}
struct TransferStatus: View {
    @ObservedObject var transfer: MediaTransfer
    var body: some View { if transfer.running { HStack { ProgressView(value: transfer.progress); Text(transfer.message).font(.caption); Button("取消复制") { transfer.cancel() } } } }
}
struct TypeField: View {
    @Binding var value: String
    var body: some View { HStack { TextField("课程类型", text: $value).frame(width: 110); Menu { ForEach(["Lecture","Seminar","Workshop"], id: \.self) { kind in Button(kind) { value = kind } } } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18) } }
}
struct LessonSelection: Identifiable { let id = UUID(); let ids: Set<UUID> }
struct LessonDetails: View {
    @ObservedObject var store: AppStore; let ids: Set<UUID>; @Environment(\.dismiss) var dismiss
    @LPState private var title = ""
    var item: Lecture? { store.library.lectures.first { ids.contains($0.id) } }
    var body: some View {
        Form {
            Text("课件详情").font(.title2)
            TextField("显示标题", text: $title)
            if let item {
                Text(item.directoryPath ?? "未关联目录").font(.caption).textSelection(.enabled)
                ForEach(item.mediaSources) { source in
                    HStack { Text(source.role.rawValue + " · " + source.originalFilename).lineLimit(2); Button("重新定位…") { store.linkMedia(item.id, sourceID: source.id) } }
                }
                if item.mediaSources.count == 1 { Button("添加第二路视频…") { store.addSecondVideo(item.id) } }
                Button("交换屏幕／摄像头角色") { store.swapRoles(item.id) }
                Button("定位原字幕并保存已有译文…") { store.linkSubtitle(item.id) }
                Text(item.sidecarStatus ?? "译文持续保存在资料库中").font(.caption)
                Button("资料位置…") { dismiss(); store.showingLocations = true }
                HStack { Button("关闭") { dismiss() }; Spacer(); Button("保存标题") { store.updateLecture(item.id) { $0.title = title; $0.customTitle = true }; dismiss() } }
            }
        }.padding(24).frame(width: 600).onAppear { title = item?.title ?? "" }
    }
}
struct NativeVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context:Context)->AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect; return view }
    func updateNSView(_ view:AVPlayerView,context:Context) { view.player = player }
}
struct ScrollIntent: NSViewRepresentable {
    var enabled = true
    var onManual: ()->Void
    func makeNSView(context:Context)->IntentView {let v=IntentView();v.onManual=onManual;v.enabled=enabled;return v}
    func updateNSView(_ view:IntentView,context:Context){view.onManual=onManual;view.enabled=enabled}
    class IntentView:NSView {
        var onManual:(()->Void)?;var monitor:Any?
        var enabled = true {didSet {if enabled != oldValue {updateMonitor()}}}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateMonitor()}
        private func updateMonitor() {
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard enabled, window != nil else{return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDown]){[weak self] event in
                if event.type == .scrollWheel || Self.hitsScroller(event) {self?.handleScroll(at:event.locationInWindow,in:event.window)}
                return event
            }
        }
        private static func hitsScroller(_ event:NSEvent)->Bool {
            guard let content=event.window?.contentView else{return false}
            var hit=content.hitTest(content.convert(event.locationInWindow,from:nil))
            while let view=hit {if view is NSScroller {return true};hit=view.superview}
            return false
        }
        // Used by the event monitor; inactive tabs have no monitor and cannot change reading state.
        @discardableResult func handleScroll(at location:NSPoint,in eventWindow:NSWindow?)->Bool {
            guard enabled,let window,eventWindow === window,!isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(location,from:nil)) else{return false}
            onManual?();return true
        }
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
}

struct TranslationControls:View {
    @ObservedObject var store:AppStore
    @ObservedObject var job:TranslationJob
    var query:String
    @LPState private var confirming=false
    @LPState private var showingDetails=false
    private var total:Int {store.transcript?.cues.count ?? 0}
    private var count:Int {store.transcript?.translatedCount ?? 0}
    private var record:TranslationTaskState? {store.transcript?.task}
    private var running:Bool {
        guard job.isRunning(store.current),let id=store.current,let task=job.states[id] else{return false}
        return (task.variantID ?? task.config.providerID.rawValue)==store.transcript?.variantID
    }
    private var label:String {
        if total==0 {return "添加字幕…"}
        if let record,record.state != "完成",record.state != "已取消" {return record.failedIDs.isEmpty ? "继续翻译…" : "重试翻译…"}
        return count==0 ? "生成译文…" : "继续翻译…"
    }
    private var details:String {
        var values=["当前译文：\(count)/\(total)"]
        if let record {values.append("本次任务：\(record.completed)/\(record.ids.count)")}
        if job.lessonID==store.current {
            if !job.status.isEmpty {values.append(job.status)}
            if !job.eta.isEmpty {values.append(job.eta)}
            if !job.details.isEmpty {values.append(job.details)}
        }
        return values.joined(separator:"\n")
    }
    var body:some View {
        Group {
            if running || total==0 || (count<total && store.transcript?.variantID != "legacy") {
                HStack(spacing:10) {
                    if running {
                        Text(job.pauseRequested ? "翻译收尾中" : "翻译中").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value:Double(record?.completed ?? count),total:Double(max(1,record?.ids.count ?? total)))
                        Button("暂停") {job.pause()}.disabled(job.pauseRequested)
                    } else {
                        Button(label) {if total==0 {store.replaceSubtitle()}else{confirming=true}}.disabled(!job.acceptsQueuedWork)
                        Spacer(minLength:0)
                    }
                    if running || record != nil {Button("详情") {showingDetails=true}.font(.caption)}
                }.buttonStyle(.borderless).padding(.vertical,4)
            }
        }
        .sheet(isPresented:$confirming) {if let id=store.current {TranslationConfirmation(store:store,job:job,lessonID:id,query:query)}}
        .popover(isPresented:$showingDetails) {ScrollView {Text(details).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(14)}.frame(width:320,height:180)}
    }
}

struct ReaderColumnsMenu:View {
    @ObservedObject var columns:ReadingColumns
    var body:some View {
        Button(columns.value.enabled ? "隐藏转写与章节":"显示转写与章节"){columns.toggleAll()}
        Button("显示章节"){columns.show(.chapters)}
        Button("显示转写"){columns.show(.transcript)}
    }
}
