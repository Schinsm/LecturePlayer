import SwiftUI
import AppKit
import Core

struct DataLocations: View {
    @ObservedObject var store: AppStore; var lessonID:UUID?=nil
    @LPState private var details=false
    @LPState private var summaries:[UUID:[String]]=[:]
    private var summaryKey:String {store.library.lectures.filter{lessonID == nil || $0.id==lessonID}.map{"\($0.id)-\($0.transcriptVersion ?? "")-\($0.sidecarStatus ?? "")"}.joined(separator:"|")}
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lessonID == nil ? "资料库位置" : "本课文件").font(.title2)
            Text("译文先保存至资料库，再生成屏幕视频目录中的分服务中文 VTT 和双语 Markdown。重新保存文件不会请求 API。").font(.caption)
            if let root = store.repository?.root { location("资料库与恢复快照", root.path); location("字幕和译文缓存", root.appendingPathComponent("transcripts").path) }
            if let root = store.library.directoryRoot { location("课程总目录", root) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.library.lectures.filter{lessonID == nil || $0.id==lessonID}) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline)
                            ForEach(summaries[item.id] ?? ["正在读取译文状态…"],id:\.self){Text($0).font(.caption)}
                            ForEach(item.mediaSources) { source in
                                location(source.role.rawValue, source.path)
                                Button("重新选择"+source.role.rawValue+"视频文件…"){store.linkMedia(item.id,sourceID:source.id)}
                            }
                            if item.mediaSources.count==1 {Button("添加第二路视频…"){store.addSecondVideo(item.id)}}
                            if lessonID != nil {Button("课件详情…"){details=true}}
                            if let path = item.subtitlePath { location("原字幕", path) }
                            ForEach((item.sidecars ?? [:]).keys.sorted(), id: \.self) { location("译文文件", $0) }
                            Text(item.sidecarStatus ?? "尚未生成旁置译文文件").font(.caption).foregroundStyle(.secondary)
                            HStack { Button("定位原字幕…") { store.linkSubtitle(item.id) }; Button("重新保存译文文件") { store.saveVisibleTranslations(item.id) }.disabled(store.translation.running) }
                        }.padding(8)
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() } }
        }.padding(24).frame(width: 750, height: 600).task(id:summaryKey){await loadSummaries()}.sheet(isPresented:$details){if let lessonID {LessonDetails(store:store,ids:[lessonID])}}
    }
    private func loadSummaries() async {
        guard let root=store.repository?.root else{return}
        let items=store.library.lectures.filter{lessonID == nil || $0.id==lessonID}
        let result=await Task.detached(priority:.utility) { () -> [UUID:[String]] in
            var values:[UUID:[String]]=[:]
            for item in items {
                guard !Task.isCancelled else{return values}
                guard let version=item.transcriptVersion else{values[item.id]=["尚无英文字幕"];continue}
                do {
                    let url=root.appendingPathComponent("transcripts/\(item.id)-\(version).json")
                    let transcript=try Codec.decode(Transcript.self,Data(contentsOf:url))
                    values[item.id]=(transcript.variants ?? [:]).values.sorted{$0.id<$1.id}.map{"\($0.title)：\($0.translations.count)/\(transcript.cues.count) · \($0.fileStatus ?? "尚未生成文件")"}
                }catch {values[item.id]=["暂时无法读取译文状态："+error.localizedDescription]}
            };return values
        }.value
        guard !Task.isCancelled else{return};summaries=result
    }
    func location(_ name: String, _ path: String) -> some View {
        HStack(alignment: .top) {
            Text(name).frame(width: 130, alignment: .leading)
            Text(path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }.help("在 Finder 显示")
        }
    }
}
