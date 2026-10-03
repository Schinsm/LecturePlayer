import SwiftUI
import Core

struct ImportTranslationPreview {
    var rowID:UUID
    var transcript:Transcript
    var config:TranslationConfig
    var summary:String
}
extension TranslationJob {
    func enqueueImports(_ entries:[(UUID,ImportTranslationPreview)],store:AppStore,provider:any TranslationProvider) throws {
        guard !busy else {throw Failure("已有翻译任务，请先暂停并等待保存完成；课件已正常导入")}
        var accepted:[UUID]=[]
        var prepared:[(Lecture,TranslationTaskState)]=[]
        for (id,preview) in entries {
            guard let lesson=store.library.lectures.first(where:{$0.id==id}),let actual=try store.repository?.read(lesson,variantID:preview.config.providerID.rawValue),actual.version==preview.transcript.version else {throw Failure("导入后字幕发生变化，请重新确认翻译")}
            guard actual.task == nil else{continue}
            let ids=preview.transcript.cues.filter{actual.translations[$0.id] == nil}.map(\.id)
            guard !ids.isEmpty else{continue}
            let record=TranslationTaskState(transcript:actual,ids:ids,config:preview.config)
            if !prepared.contains(where:{$0.0.id==id}) {prepared.append((lesson,record))}
        }
        do {
            for (lesson,record) in prepared {store.updateLecture(lesson.id){$0.selectedTranslationVariantID=record.variantID};try saveTask(record,lesson:lesson,store:store);accepted.append(lesson.id)}
        } catch {
            for (lesson,var record) in prepared where accepted.contains(lesson.id) {record.state="已暂停";try? saveTask(record,lesson:lesson,store:store)}
            throw error
        }
        if !accepted.isEmpty {launch(store:store,ids:accepted,provider:provider)}
    }
}
struct LessonTranslationStatus:View {
    @ObservedObject var job:TranslationJob
    let id:UUID;let store:AppStore
    @LPState private var confirming=false
    var body:some View {
        if let record=job.states[id] {
            HStack {
                Text("本次翻译 · \(record.state) · \(record.completed)/\(record.ids.count)").font(.caption).foregroundStyle(.secondary)
                if record.state != "完成" && record.state != "已取消" {
                    if !job.busy {Button("继续翻译…") {store.updateLecture(id){$0.selectedTranslationVariantID=record.variantID};confirming=true}.font(.caption)}
                    Button(job.running ? "暂停队列" : "取消任务") {job.cancelQueued(id,store:store)}.font(.caption)
                }
            }.sheet(isPresented:$confirming){TranslationConfirmation(store:store,job:job,lessonID:id)}
        }
    }
}
