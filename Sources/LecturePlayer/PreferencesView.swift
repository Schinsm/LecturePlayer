import SwiftUI
import AppKit
import Core

enum PreferencesPage: String, CaseIterable, Identifiable {
    case general, playback, library, translation, usage, backup
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "通用"
        case .playback: return "播放与字幕"
        case .library: return "资料库"
        case .translation: return "翻译与总结"
        case .usage: return "用量"
        case .backup: return "备份与恢复"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .library: return "folder"
        case .translation: return "character.bubble"
        case .usage: return "chart.bar"
        case .backup: return "externaldrive"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @LPState private var page: PreferencesPage? = .general
    @LPState private var locations = false
    @AppStorage("appearance") private var appearance = "系统"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private let refreshCredentials: Bool
    init(store: AppStore, initialPage: PreferencesPage = .general, refreshCredentials: Bool = true) {
        self.store = store
        _page = LPState(initialValue: initialPage)
        self.refreshCredentials = refreshCredentials
    }
    var body: some View {
        HStack(spacing: 0) {
            List(PreferencesPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.icon).tag(item)
                    .padding(.vertical, 5)
            }.listStyle(.sidebar).frame(width: 164)
            Divider()
            content.frame(maxWidth: 800).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 640)
        .preferredColorScheme(appearance == "深色" ? .dark : appearance == "浅色" ? .light : nil)
        .onAppear { if refreshCredentials { KeychainAvailability.shared.refreshAll() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if refreshCredentials { KeychainAvailability.shared.refreshAll() }
        }
        .sheet(isPresented: $locations) { DataLocations(store: store) }
    }
    @ViewBuilder private var content: some View {
        switch page ?? .general {
        case .general:
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        ForEach(["系统", "浅色", "深色"], id: \.self) { Text($0) }
                    }
                }
                Section("开始使用") {
                    Button("新手教程…") {
                        dismiss()
                        openWindow(id: "main")
                        OnboardingPresentation.shared.open()
                    }
                }
            }.formStyle(.grouped)
        case .playback:
            Form { PlaybackPreferenceSections(store: store); ShortcutSettings() }.formStyle(.grouped)
        case .library:
            Form {
                Section("课程目录") {
                    Text(store.library.directoryRoot ?? "尚未选择").textSelection(.enabled)
                    Button(store.library.directoryRoot == nil ? "选择目录…" : "更换目录…") { store.selectDirectoryRoot() }
                }
                Section("刷新") {
                    Picker("频率", selection: Binding(get: { store.refreshPolicy }, set: { store.setRefreshPolicy($0) })) {
                        ForEach(RefreshPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    Button(store.scanning ? "正在刷新…" : "立即刷新") { store.refreshDirectory() }
                        .disabled(store.scanning || store.library.directoryRoot == nil)
                    DisclosureGroup("刷新详情") {
                        Text(store.scanSummary)
                        Text(store.nextRefreshText)
                        Text("应用运行时定时刷新，唤醒后补查一次。")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Section("文件位置") {
                    Button("资料位置…") { locations = true }
                    if let root = store.repository?.root { Text(root.path).font(.caption).textSelection(.enabled) }
                }
            }.formStyle(.grouped)
        case .translation:
            Form { APISettings(store: store, job: store.translation); AnalysisModelSettings() }.formStyle(.grouped)
        case .usage:
            Form { TranslationHistory(store: store, job: store.translation) }.formStyle(.grouped)
        case .backup:
            Form {
                Section("备份与恢复") {
                    Button("导出备份…") { store.backup() }
                    Button("恢复备份…") { store.restore() }.disabled(store.translation.busy)
                    Button("查看恢复快照") { if let root = store.repository?.root { NSWorkspace.shared.open(root) } }
                    DisclosureGroup("备份内容") {
                        Text("包含学习记录、译文和章节，不包含 API Key。恢复前保存当前资料库快照。")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}

private struct PlaybackPreferenceSections: View {
    @ObservedObject var store: AppStore
    @AppStorage("rewind") private var rewind = false
    @AppStorage("defaultSpeed") private var speed = 1.0
    @AppStorage("lineSpacing") private var spacing = 5.0
    @AppStorage("fontSize") private var font = 17.0
    @AppStorage("hideSpeakerLabels") private var hideSpeakers = true
    var body: some View {
        Section("播放") {
            Toggle("继续播放前回退 3 秒", isOn: $rewind)
            Picker("默认倍速", selection: $speed) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2, 2.5], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }.help("用于新课件；已有课件保留各自倍速。")
        }
        Section("转写") {
            preferenceSlider("字号", value: $font, range: 12...32, display: "\(Int(font))")
            preferenceSlider("行距", value: $spacing, range: 0...16, display: "\(Int(spacing))")
            Toggle("隐藏说话人编号", isOn: $hideSpeakers)
        }
        GlobalCaptionSettings(store: store)
    }
    private func preferenceSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack { Text(title); Spacer(minLength: 20); Slider(value: value, in: range).frame(maxWidth: 260); Text(display).monospacedDigit().frame(width: 30, alignment: .trailing) }
    }
}

/// Settings can edit global captions even when no lesson is open. Active playback
/// uses the existing live preview, while idle edits are coalesced in preferences.
private struct GlobalCaptionSettings: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var presentation: CaptionPresentation
    @LPState private var idleValue = VideoCaptionPreferences()
    @LPState private var pending = false
    @LPState private var editing = false
    @LPState private var saveTask: Task<Void, Never>?
    init(store: AppStore) { self.store = store; presentation = store.captions }
    private var value: VideoCaptionPreferences { store.current == nil ? idleValue : presentation.value }
    var body: some View {
        Section("视频字幕") {
            Toggle("显示字幕", isOn: binding(\.enabled))
            Picker("语言", selection: binding(\.mode)) { ForEach(["双语", "英文", "中文"], id: \.self) { Text($0) } }
            HStack { Text("字号"); Spacer(); Slider(value: binding(\.fontSize), in: 16...36, onEditingChanged: setEditing).frame(maxWidth: 260); Text("\(Int(value.fontSize))").monospacedDigit().frame(width: 36, alignment: .trailing) }
            Picker("位置", selection: Binding(get: { value.position ?? "bottom" }, set: { next in update { $0.position = next } })) {
                Text("顶部").tag("top"); Text("居中").tag("center"); Text("底部").tag("bottom")
            }
            if value.position != "center" {
                HStack { Text("边距"); Spacer(); Slider(value: Binding(get: { value.margin ?? 0.02 }, set: { next in update { $0.margin = next } }), in: 0...0.15, onEditingChanged: setEditing).frame(maxWidth: 260); Text("\(Int((value.margin ?? 0.02) * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing) }
            }
            HStack { Text("背景透明度"); Spacer(); Slider(value: Binding(get: { value.transparency ?? 0.22 }, set: { next in update { $0.transparency = next } }), in: 0...1, onEditingChanged: setEditing).frame(maxWidth: 260); Text("\(Int((value.transparency ?? 0.22) * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing) }
            Toggle("按句显示", isOn: Binding(get: { value.grouped ?? true }, set: { next in update { $0.grouped = next } }))
            Button("恢复默认外观") { update { $0.position = nil; $0.margin = nil; $0.transparency = nil; $0.fontSize = 22 } }
        }
        .onAppear { idleValue = store.captionPreferences.value }
        .onChange(of: store.current) { _, next in
            let finalIdle = pending ? idleValue : nil
            flush()
            if next != nil, let finalIdle { presentation.update { $0 = finalIdle }; presentation.flush() }
            idleValue = store.captionPreferences.value
        }
        .onDisappear { setEditing(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
    }
    private func binding<T>(_ path: WritableKeyPath<VideoCaptionPreferences, T>) -> Binding<T> {
        Binding(get: { value[keyPath: path] }, set: { next in update { $0[keyPath: path] = next } })
    }
    private func update(_ change: (inout VideoCaptionPreferences) -> Void) {
        if store.current != nil { presentation.update(change); return }
        change(&idleValue); pending = true; saveTask?.cancel()
        if !editing { saveTask = Task { do { try await Task.sleep(for: .milliseconds(350)) } catch { return }; flush() } }
    }
    private func setEditing(_ active: Bool) {
        editing = active; presentation.setEditing(active)
        if active { saveTask?.cancel() } else { flush() }
    }
    private func flush() {
        saveTask?.cancel(); saveTask = nil
        if pending { store.captionPreferences.save(idleValue); pending = false }
        presentation.flush()
    }
}

struct ReadingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased { content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) }
        else if #available(macOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
    }
}
