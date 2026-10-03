import SwiftUI
import AppKit
import Core

struct LessonFileItem:Identifiable,Sendable {
    var id:String {path};let path:String;let label:String;var exists:Bool?
}
struct LessonFileGroup:Identifiable,Sendable {
    let id:String;let title:String;let status:String;let files:[LessonFileItem];let history:[LessonFileItem]
}
struct LessonFileSnapshot:Sendable {
    var video:[LessonFileItem]=[];var subtitle:[LessonFileItem]=[];var translations:[LessonFileGroup]=[]
    var unknownHistory:[LessonFileItem]=[]
}
actor LessonFileCache {
    static let shared=LessonFileCache()
    private var cache:[String:Transcript]=[:];private var order:[String]=[]
    func load(root:URL,lesson:Lecture) throws -> LessonFileSnapshot {
        let start=Date();defer {PerformanceTrace.record("files.lessonLoad",Date().timeIntervalSince(start))}
        func item(_ path:String,_ label:String)->LessonFileItem {LessonFileItem(path:path,label:label,exists:FileManager.default.fileExists(atPath:path))}
        var result=LessonFileSnapshot()
        result.video=lesson.mediaSources.map{item($0.path,$0.role.rawValue)}
        result.subtitle=lesson.subtitlePath.map{[item($0,"原字幕")]} ?? []
        guard let version=lesson.transcriptVersion else{return result}
        let url=root.appendingPathComponent("transcripts/\(lesson.id)-\(version).json")
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        let modified=(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key="\(url.path)|\(modified)|\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")"
        let transcript:Transcript
        if let saved=cache[key] {transcript=saved;PerformanceTrace.record("files.cacheHit",0)}
        else {
            transcript=try Codec.decode(Transcript.self,Data(contentsOf:url));try transcript.validate()
            cache[key]=transcript;order.append(key)
            while order.count>3 {cache.removeValue(forKey:order.removeFirst())}
            PerformanceTrace.record("files.cacheMiss",0)
        }
        var known=Set<String>()
        for variant in (transcript.variants ?? [:]).values.sorted(by:{$0.id<$1.id}) {
            try Task.checkCancellation()
            let history:[String:String]
            if variant.generatedFiles != nil {history=variant.historicalFiles ?? [:]}
            else {history=(variant.historicalFiles ?? [:]).merging(GeneratedFiles.legacyFiles((lesson.sidecars ?? [:]).merging(variant.sidecars ?? [:]){old,_ in old},lessonID:lesson.id,version:version,serviceID:variant.id)){old,_ in old}}
            let current=(variant.generatedFiles ?? []).map{item($0.path,$0.format == .chineseVTT ? "中文 VTT":"双语 Markdown")}
            known.formUnion(history.keys);known.formUnion(current.map(\.path))
            guard !variant.translations.isEmpty || variant.task != nil || !history.isEmpty || variant.fileStatus?.hasPrefix("文件待保存")==true else{continue}
            result.translations.append(LessonFileGroup(id:variant.id,title:variant.title,status:variant.fileStatus ?? "尚未生成文件",files:current,history:history.keys.sorted().map{LessonFileItem(path:$0,label:"历史导出",exists:nil)}))
        }
        result.unknownHistory=(lesson.sidecars ?? [:]).keys.filter{!known.contains($0)}.sorted().map{LessonFileItem(path:$0,label:"归属待核验",exists:nil)}
        return result
    }
}

struct DataLocations:View {
    @ObservedObject var store:AppStore;var lessonID:UUID?=nil
    @Environment(\.dismiss) private var dismiss
    @LPState private var snapshot:LessonFileSnapshot?
    @LPState private var error=""
    @LPState private var saving=false
    @LPState private var revision=0
    @LPState private var details=false
    private var lesson:Lecture? {store.library.lectures.first{$0.id==lessonID}}
    private var loadKey:String {"\(lessonID?.uuidString ?? "")|\(lesson?.transcriptVersion ?? "")|\(lesson?.sidecarStatus ?? "")|\(lesson?.sidecars?.hashValue ?? 0)|\(revision)"}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(lessonID == nil ? "资料位置":"本课文件").font(.title2.bold())
            if lessonID==nil {
                if let root=store.repository?.root {
                    LessonFileRow(item:LessonFileItem(path:root.path,label:"资料库与恢复快照",exists:true))
                }
                if let path=store.library.directoryRoot {LessonFileRow(item:LessonFileItem(path:path,label:"课程总目录",exists:nil))}
            } else if let lesson {
                Text(lesson.displayTitle).font(.headline).lineLimit(2)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:18) {
                        if let snapshot {
                            fileSection("视频",snapshot.video)
                            fileSection("原字幕",snapshot.subtitle)
                            if snapshot.subtitle.isEmpty {Button("定位原字幕…"){store.linkSubtitle(lesson.id)}}
                            Text("译文").font(.headline)
                            if snapshot.translations.isEmpty {Text("暂无译文").foregroundStyle(.secondary)}
                            ForEach(snapshot.translations) {group in
                                VStack(alignment:.leading,spacing:8) {
                                    Text(group.title).font(.subheadline.bold())
                                    Text(group.status).font(.caption).foregroundStyle(.secondary)
                                    ForEach(group.files) {LessonFileRow(item:$0)}
                                    HistoryFileGroup(title:"历史导出",items:group.history)
                                }
                            }
                            HistoryFileGroup(title:"归属待核验的历史导出",items:snapshot.unknownHistory)
                        } else if error.isEmpty {ProgressView("正在读取本课文件…")}
                        if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.orange)}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,8)
                }
                HStack {
                    Button("课件详情…"){details=true}
                    Button(saving ? "正在保存…":"重试保存译文文件") {
                        saving=true
                        Task {let task=store.saveVisibleTranslations(lesson.id);await task?.value;saving=false;revision += 1}
                    }.disabled(saving || snapshot?.translations.isEmpty != false)
                    Spacer()
                    Button("刷新"){revision += 1}
                }.controlSize(.small)
            } else {Text("课件不存在")}
            HStack {Spacer();Button("完成"){dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width:650,height:lessonID==nil ? 230:570)
            .task(id:loadKey) {
                guard let lesson,let root=store.repository?.root else{return}
                do {
                    let value=try await LessonFileCache.shared.load(root:root,lesson:lesson)
                    try Task.checkCancellation();snapshot=value;error=""
                } catch is CancellationError {} catch {self.error=error.localizedDescription}
            }
            .sheet(isPresented:$details){if let lessonID {LessonDetails(store:store,ids:[lessonID])}}
    }
    private func fileSection(_ title:String,_ files:[LessonFileItem])->some View {
        VStack(alignment:.leading,spacing:8) {Text(title).font(.headline);ForEach(files){LessonFileRow(item:$0)}}
    }
}
private struct HistoryFileGroup:View {
    let title:String;let items:[LessonFileItem]
    @LPState private var expanded=false
    var body:some View {
        if !items.isEmpty {
            DisclosureGroup(title,isExpanded:$expanded) {
                if expanded {LazyVStack(alignment:.leading,spacing:8){ForEach(items){LessonFileRow(item:$0)}}.padding(.top,8)}
            }.font(.caption)
        }
    }
}
private struct LessonFileRow:View {
    let item:LessonFileItem
    @LPState private var expanded=false
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(alignment:.top,spacing:10) {
                Button {expanded.toggle()} label: {Image(systemName:expanded ? "chevron.down":"chevron.right").frame(width:12)}.buttonStyle(.plain).help("完整路径")
                VStack(alignment:.leading,spacing:3) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath:item.path).lastPathComponent).lineLimit(2).truncationMode(.middle)
                    if item.exists==false {Text("文件缺失").font(.caption).foregroundStyle(.orange)}
                }.frame(maxWidth:.infinity,alignment:.leading)
                Button {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)])} label:{Image(systemName:"folder")}.help("在 Finder 显示").disabled(item.exists==false)
            }
            if expanded {Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
        }
    }
}
