import SwiftUI
import AppKit
import Core

enum OnboardingStep: String, Codable, CaseIterable, Identifiable {
    case directory, service, importing, watching
    var id: Self { self }
    var title: String {
        switch self {
        case .directory: return "课程目录"
        case .service: return "翻译服务"
        case .importing: return "导入课件"
        case .watching: return "开始观看"
        }
    }
    var index: Int { Self.allCases.firstIndex(of: self)! }
}

struct OnboardingProgress: Codable, Equatable {
    var step: OnboardingStep = .directory
    var automaticOfferHandled = false
    var completed: Set<OnboardingStep> = []
    var skipped: Set<OnboardingStep> = []
    var finished = false
}

/// Only tutorial progress is persisted here; credentials and course data retain
/// their existing owners. Injected defaults keep QA independent of user setup.
@MainActor final class OnboardingPresentation: ObservableObject {
    static let shared = OnboardingPresentation()
    static let key = "onboarding.v088"
    @Published var showing = false
    @Published private(set) var progress: OnboardingProgress
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) } ?? OnboardingProgress()
    }
    func presentIfNeeded(library: Library) {
        guard !progress.automaticOfferHandled else { return }
        let hasLibrary = library.directoryRoot != nil || !library.lectures.isEmpty || !library.courses.isEmpty || library.lastLecture != nil
        let existingKeys = ["appearance", "defaultSpeed", "model", "effort", "translationService", "azureRegion", "fontSize", "playbackShortcuts.v1"]
        let hasPreferences = existingKeys.contains { defaults.object(forKey: $0) != nil }
        progress.automaticOfferHandled = true
        persist()
        if !hasLibrary && !hasPreferences { showing = true }
    }
    func open() { progress.automaticOfferHandled = true; persist(); showing = true }
    func close() { progress.automaticOfferHandled = true; persist(); showing = false }
    func advance(completed: Bool) {
        let current = progress.step
        if completed { progress.completed.insert(current); progress.skipped.remove(current) }
        else { progress.skipped.insert(current); progress.completed.remove(current) }
        if current == .watching { progress.finished = true; showing = false }
        else { progress.step = OnboardingStep.allCases[current.index + 1] }
        persist()
    }
    func back() {
        guard progress.step.index > 0 else { return }
        progress.step = OnboardingStep.allCases[progress.step.index - 1]; persist()
    }
    func finish() { progress.completed.insert(.watching); progress.skipped.remove(.watching); progress.finished = true; close() }
    private func persist() { if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.key) } }
}

struct OnboardingView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var presentation = OnboardingPresentation.shared
    @ObservedObject private var keys = KeychainAvailability.shared
    @LPState private var importing = false
    @LPState private var selectedLesson: UUID?
    @AppStorage("translationService") private var service = "openAI"
    private var step: OnboardingStep { presentation.progress.step }
    private var lessons: [Lecture] {
        store.library.lectures.filter { $0.archived != true }.sorted {
            let a = ($0.directoryPath ?? "") + "/" + $0.title, b = ($1.directoryPath ?? "") + "/" + $1.title
            if a == b { return $0.id.uuidString < $1.id.uuidString }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("开始使用 Lecture Player").font(.title2.weight(.semibold))
                    Spacer()
                    Button("稍后再说") { presentation.close() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 16) {
                    ForEach(OnboardingStep.allCases) { item in
                        HStack(spacing: 6) {
                            Text("\(item.index + 1)").font(.caption.weight(.semibold))
                                .frame(width: 22, height: 22)
                                .background(step == item ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                                .foregroundStyle(step == item ? Color.white : Color.secondary)
                            Text(item.title).font(.callout).foregroundStyle(step == item ? .primary : .secondary)
                        }
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("第 \(step.index + 1) 步，共 4 步：\(step.title)")
            }.padding(24)
            Divider()
            stepContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("上一步") { presentation.back() }.disabled(step.index == 0)
                Spacer()
                if step != .watching {
                    Button("跳过") { presentation.advance(completed: false) }
                    Button("下一步") { presentation.advance(completed: currentStepComplete) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") { presentation.finish() }
                    if let id = selectedLesson ?? lessons.first?.id {
                        Button("打开课件") { presentation.finish(); store.open(id) }.keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(20)
        }.frame(width: 720, height: 620)
            .sheet(isPresented: $importing) { ImportView(store: store, initialURLs: store.directoryFiles) }
            .onAppear { keys.refreshAll() }
            .onDisappear { presentation.close() }
    }
    @ViewBuilder private var stepContent: some View {
        switch step {
        case .directory:
            Form {
                Section("选择视频与字幕所在的总目录") {
                    Text("课程和子文件夹会保留原来的分类。").foregroundStyle(.secondary)
                    if let root = store.library.directoryRoot { Label(root, systemImage: "folder").textSelection(.enabled) }
                    Button(store.library.directoryRoot == nil ? "选择课程目录…" : "更换课程目录…") { store.selectDirectoryRoot() }
                    if store.scanning { HStack { ProgressView().controlSize(.small); Text("正在查找课件…") } }
                    if !store.scanIssues.isEmpty { Text("部分文件未能读取，可在资料库查看详情。").font(.caption).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped)
        case .service:
            Form {
                Section { Text("翻译服务可稍后设置。课程总结使用 OpenAI。").foregroundStyle(.secondary) }
                APISettings(store: store, job: store.translation, includesSpeed: false)
            }.formStyle(.grouped)
        case .importing:
            Form {
                Section("确认要加入资料库的课件") {
                    Text("预览视频与字幕的对应关系，再确认导入。").foregroundStyle(.secondary)
                    if store.library.directoryRoot == nil {
                        Button("选择课程目录…") { store.selectDirectoryRoot() }
                    } else {
                        Button("预览并导入…") { importing = true }.disabled(store.scanning)
                        if store.scanning { ProgressView("正在查找课件…") }
                        else if store.directoryFiles.isEmpty { Text("目录中暂未发现视频，可添加文件后刷新。").font(.caption).foregroundStyle(.secondary) }
                        Button("刷新目录") { store.refreshDirectory() }.disabled(store.scanning)
                    }
                    if !lessons.isEmpty { Text("已导入课件可直接开始观看。").foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
        case .watching:
            Form {
                Section("常用操作") {
                    guide("captions.bubble", "视频字幕", "在播放栏打开双语字幕，外观会沿用到下一堂课。")
                    guide("text.alignleft", "转写与跟随", "点击原文跳转。手动浏览后，点击“跟随”回到播放位置。")
                    guide("list.bullet.indent", "课程章节", "在“章节”查看总结和知识点，点击标题定位。")
                    guide("rectangle.split.2x1", "画面布局", "视频右上角调整布局；画中画可拖动和缩放。")
                    guide("list.bullet.rectangle", "课程播放列表", "从播放栏选集，播完后可点击下一集。")
                }
                if !lessons.isEmpty {
                    Section("选择课件") {
                        Picker("课件", selection: Binding(get: { selectedLesson ?? lessons[0].id }, set: { selectedLesson = $0 })) {
                            ForEach(lessons) { lesson in Text(lesson.title).tag(lesson.id) }
                        }
                    }
                }
            }.formStyle(.grouped)
        }
    }
    private var currentStepComplete: Bool {
        switch step {
        case .directory: return store.library.directoryRoot != nil
        case .service:
            let provider = TranslationService(rawValue: service) ?? .openAI
            return !provider.needsKey || keys.configured(provider)
        case .importing: return !lessons.isEmpty
        case .watching: return true
        }
    }
    private func guide(_ icon: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(description).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}
