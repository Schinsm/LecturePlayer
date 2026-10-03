import SwiftUI
import Core

struct ChapterBatchRow: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let entry: ImportProcessingEntry?
}
@MainActor enum ChapterBatchPlanner {
    /// Read-only preview; frozen configurations are reused for unfinished work.
    static func rows(ids:Set<UUID>,store:AppStore,config:AnalysisConfig) throws -> [ChapterBatchRow] {
        guard let repository=store.repository else {throw Failure("资料库不可用")}
        let records=try AnalysisRepository.readAll(root:repository.root)
        return store.library.lectures.filter{ids.contains($0.id)}.sorted{
            let order=$0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }.map {lesson in
            do {
                guard let source=try repository.read(lesson),!source.cues.isEmpty else {throw Failure("先添加带时间戳的英文字幕")}
                let existing=records.first{$0.lessonID==lesson.id && $0.sourceVersion==source.version}
                if existing?.completed != nil && existing?.task == nil {
                    return ChapterBatchRow(id:lesson.id,title:lesson.title,detail:"已完成，本次跳过；重新生成请在本课章节页单独确认。",entry:nil)
                }
                if store.processing.entries.contains(where:{$0.id==lesson.id && $0.status != "完成" && $0.translation != nil}) {
                    throw Failure("已有翻译与总结队列，请先从课件的“继续”入口恢复")
                }
                let queued=store.processing.entries.first{$0.id==lesson.id && $0.status != "完成"}?.analysis
                let task=try existing?.task ?? queued ?? AnalysisTaskState(config:config,plan:AnalysisPlan.make(source))
                guard task.plan == (try AnalysisPlan.make(source)) else {throw Failure("排队任务对应旧字幕，请在本课章节页重新确认")}
                try task.validate()
                var entry=ImportProcessingEntry(id:lesson.id,translation:nil,analysis:task);entry.purpose="chapters"
                let detail=(existing?.task == nil ? "待生成" : "继续未完成部分，沿用已确认配置")+"\n"+task.config.selectionDescription+"\n"+task.plan.estimate(config:task.config,remainingChunkIDs:Set(task.pendingChunks.map(\.id)))
                return ChapterBatchRow(id:lesson.id,title:lesson.title,detail:detail,entry:entry)
            } catch {return ChapterBatchRow(id:lesson.id,title:lesson.title,detail:"未加入："+error.localizedDescription,entry:nil)}
        }
    }
}
struct ChapterBatchConfirmation: View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    let store:AppStore
    let ids:Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @LPState private var rows:[ChapterBatchRow]=[]
    @LPState private var error=""
    @ObservedObject private var processing:ImportProcessingCoordinator
    @ObservedObject private var translation:TranslationJob
    init(store:AppStore,ids:Set<UUID>) {self.store=store;self.ids=ids;processing=store.processing;translation=store.translation}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("生成总结与章节").font(.title2)
            Text("按以下顺序逐堂处理。播放不受影响；失败或暂停后停止后续请求。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    ForEach(rows) {row in
                        VStack(alignment:.leading,spacing:6) {Text(row.title).font(.headline);Text(row.detail).font(.caption).textSelection(.enabled)}
                        Divider()
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("本次处理 \(rows.compactMap(\.entry).count) 堂。费用是估算，已发送的请求仍可能计费；不自动重试。").font(.caption)
            if !error.isEmpty {Text(error).foregroundStyle(.red)}
            if translation.busy {Text("等待当前翻译、总结或连接测试收尾后即可开始。").font(.caption)}
            if !keyAvailability.configured(.openAI) {Text("请先在设置中保存 OpenAI Key。").font(.caption)}
            HStack {
                Button("取消") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认并依次生成") {
                    do {try processing.launch(rows.compactMap(\.entry),store:store);dismiss()} catch {self.error=error.localizedDescription}
                }.buttonStyle(.borderedProminent)
                    .disabled(rows.compactMap(\.entry).isEmpty || translation.busy || !keyAvailability.configured(.openAI))
            }
        }.padding(24).frame(width:600,height:520)
            .task {do {rows=try ChapterBatchPlanner.rows(ids:ids,store:store,config:AnalysisPreferences.load())} catch {self.error=error.localizedDescription}}
    }
}
