import SwiftUI
import Core

struct ChapterBatchRow: Identifiable,Sendable {
    let id: UUID
    let title: String
    let detail: String
    let entry: ImportProcessingEntry?
}
@MainActor enum ChapterBatchPlanner {
    /// Read-only preview; frozen configurations are reused for unfinished work.
    static func rows(ids:Set<UUID>,store:AppStore,config:AnalysisConfig) throws -> [ChapterBatchRow] {
        guard let repository=store.repository else {throw Failure("资料库不可用")}
        return try rows(lessons:store.library.lectures.filter{ids.contains($0.id)},root:repository.root,entries:store.processing.entries,config:config)
    }
    nonisolated static func rows(lessons:[Lecture],root:URL,entries:[ImportProcessingEntry],config:AnalysisConfig) throws -> [ChapterBatchRow] {
        return lessons.sorted{
            let order=$0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }.map {lesson in
            do {
                try Task.checkCancellation()
                let prepared=try AnalysisPreparation.load(root:root,lesson:lesson,config:config)
                let source=prepared.source,existing=prepared.existing
                let availability=AnalysisAvailability(saved:existing.map(SavedAnalysisSummary.init))
                if availability.state == .completed {
                    return ChapterBatchRow(id:lesson.id,title:lesson.title,detail:"已完成，本次跳过；重新生成请在本课章节页单独确认。",entry:nil)
                }
                if entries.contains(where:{$0.id==lesson.id && $0.status != "完成" && $0.translation != nil}) {
                    throw Failure("已有翻译与总结队列，请先从课件的“继续”入口恢复")
                }
                let queued=entries.first{$0.id==lesson.id && $0.status != "完成"}?.analysis
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
            Text("按确认顺序调度，全局最多两个请求。播放不受影响；失败或暂停后停止后续请求。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if rows.isEmpty && error.isEmpty {ProgressView("正在准备所选课件…")}
                    ForEach(rows) {row in
                        VStack(alignment:.leading,spacing:6) {Text(row.title).font(.headline);Text(row.detail).font(.caption).textSelection(.enabled)}
                        Divider()
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("本次处理 \(rows.compactMap(\.entry).count) 堂。费用是估算，已发送的请求仍可能计费；不自动重试。").font(.caption)
            if !error.isEmpty {Text(error).foregroundStyle(.red)}
            if !translation.acceptsQueuedWork {Text("等待当前翻译、总结或连接测试收尾后即可开始。").font(.caption)}
            if !keyAvailability.configured(.openAI) {Text("请先在设置中保存 OpenAI Key。").font(.caption)}
            HStack {
                Button("取消") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认生成") {
                    do {try processing.launch(rows.compactMap(\.entry),store:store);dismiss()} catch {self.error=error.localizedDescription}
                }.buttonStyle(.borderedProminent)
                    .disabled(rows.compactMap(\.entry).isEmpty || !translation.acceptsQueuedWork || !keyAvailability.configured(.openAI))
            }
        }.padding(24).frame(width:600,height:520)
            .task(id:ids) {
                do {
                    guard let root=store.repository?.root else {throw Failure("资料库不可用")}
                    let lessons=store.library.lectures.filter{ids.contains($0.id)},entries=store.processing.entries,config=AnalysisPreferences.load()
                    let work=Task.detached(priority:.userInitiated) {try PerformanceTrace.measure("analysis.batch.prepare"){try ChapterBatchPlanner.rows(lessons:lessons,root:root,entries:entries,config:config)}}
                    let result=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                    try Task.checkCancellation();rows=result
                } catch is CancellationError {} catch {self.error=error.localizedDescription}
            }
    }
}
