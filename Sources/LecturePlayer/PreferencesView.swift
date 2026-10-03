import SwiftUI
import AppKit
import Core

struct PreferencesView: View {
    @ObservedObject var store:AppStore
    @LPState private var page="general"
    @LPState private var locations=false
    @AppStorage("appearance") var appearance="系统"
    var body:some View {
        TabView(selection:$page) {
            ScrollView { VStack {SettingsView(); Form {ShortcutSettings()}.formStyle(.grouped)}.padding(24) }.tabItem { Label("通用",systemImage:"gearshape") }.tag("general")
            Form {
                Section("课程目录") {
                    Text(store.library.directoryRoot ?? "尚未选择总目录").textSelection(.enabled)
                    Button("更换总目录…") { store.selectDirectoryRoot() }
                    Text("按真实学科与 Week 文件夹分类，不移动源文件。").font(.caption).foregroundStyle(.secondary)
                }
                Section("刷新") {
                    Picker("频率",selection:Binding(get:{store.refreshPolicy},set:{store.setRefreshPolicy($0)})) { ForEach(RefreshPolicy.allCases) { Text($0.title).tag($0) } }
                    Text(store.scanSummary).font(.caption)
                    Text(store.nextRefreshText).font(.caption).foregroundStyle(.secondary)
                    Button("立即刷新") { store.refreshDirectory() }.disabled(store.scanning || store.library.directoryRoot == nil)
                    Text("定时刷新仅在应用运行时执行；唤醒后最多补查一次。").font(.caption)
                }
                Section("文件位置") {
                    Button("资料位置…") { locations=true }
                    if let root=store.repository?.root { Text(root.path).font(.caption).textSelection(.enabled) }
                }
            }.formStyle(.grouped).tabItem { Label("资料库",systemImage:"folder") }.tag("library")
            Form { APISettings(store:store,job:store.translation); AnalysisModelSettings(); TranslationHistory(store:store,job:store.translation,active:page=="translation") }.formStyle(.grouped).tabItem { Label("翻译与用量",systemImage:"character.bubble") }.tag("translation")
            Form {
                Section("备份与恢复") {
                    Text("备份包含学习记录和译文，不含 API Key。恢复前会先保存当前资料库快照。").font(.callout)
                    Button("导出备份…") { store.backup() }
                    Button("恢复备份…") { store.restore() }.disabled(store.translation.busy)
                    Button("查看恢复快照") { if let root=store.repository?.root { NSWorkspace.shared.open(root) } }
                }
            }.formStyle(.grouped).tabItem { Label("备份与恢复",systemImage:"externaldrive") }.tag("backup")
        }.frame(minWidth:700,idealWidth:760,minHeight:620,idealHeight:700)
        .preferredColorScheme(appearance == "深色" ? .dark : appearance == "浅色" ? .light : nil)
        .onAppear{KeychainAvailability.shared.refreshAll()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in KeychainAvailability.shared.refreshAll()}
        .sheet(isPresented:$locations) { DataLocations(store:store) }
    }
}
struct ReadingGlass:ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @ViewBuilder func body(content:Content)->some View {
        if reduceTransparency || contrast == .increased { content.background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)) }
        else if #available(macOS 26,*) { content.glassEffect(.regular,in:RoundedRectangle(cornerRadius:12)) }
        else { content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }
    }
}
