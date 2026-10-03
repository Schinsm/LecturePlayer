import SwiftUI
import Core

struct TranslationConfirmation: View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    @ObservedObject var store:AppStore
    @ObservedObject var job:TranslationJob
    let lessonID:UUID
    var query=""
    @Environment(\.dismiss) var dismiss
    @LPState private var source:Transcript?
    @AppStorage("translationAutomaticModel") private var automaticModel=false
    @LPState private var scope="all"
    @LPState private var useCurrentSettings=false
    @LPState private var message=""
    private var lesson:Lecture? {store.library.lectures.first{$0.id==lessonID}}
    private var previous:TranslationTaskState? {
        guard let source,let t=source.task,t.version==source.version,t.state != "完成",t.state != "已取消",t.ids.contains(where:{source.translations[$0]==nil}) else{return nil};return t
    }
    private var config:TranslationConfig {
        if let previous,!useCurrentSettings {return previous.config}
        return TranslationPreferences.load(.standard,glossary:store.library.courses.first{$0.id==lesson?.courseID}?.glossary ?? "",service:TranslationService(rawValue:source?.variantID ?? ""))
    }
    private var record:TranslationTaskState? {
        guard let source else{return nil}
        if var previous {previous.config=config;return previous}
        let matched = ReadingSearch.matches(ReadingUnits.make(source.cues, grouped: store.library.lectures.first(where: {$0.id == lessonID})?.readingGrouped ?? true), translations: source.translations, query: query, hideSpeakers: UserDefaults.standard.object(forKey:"hideSpeakerLabels") as? Bool ?? true)
        let matches=source.cues.filter{source.translations[$0.id]==nil && (scope != "search" || matched.contains($0.id))}
        var task=TranslationTaskState(transcript:source,ids:(scope == "trial" ? Array(matches.prefix(5)) : matches).map(\.id),config:config)
        task.singleCue=UserDefaults.standard.bool(forKey:"translationSingleCue")
        return task
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(previous == nil ? "翻译中文" : "继续未完成的翻译").font(.title2.bold())
            Text(lesson?.title ?? "课件").foregroundStyle(.secondary)
            if previous == nil && config.providerID == .openAI {Toggle("自动·均衡",isOn:$automaticModel)}
            if let plan=config.resolvedModels {Text(plan.summary).font(.caption)}
            if previous == nil {
                Picker("翻译范围",selection:$scope) {Text("全部未译").tag("all");Text("先试译 5 条").tag("trial");if !query.isEmpty {Text("搜索匹配内容").tag("search")}}.pickerStyle(.segmented)
            } else {
                Text("继续上次确认的范围；先补齐未完成内容，再继续剩余字幕。已有译文不会重新发送。").font(.callout)
                Toggle("改用设置中的模型",isOn:$useCurrentSettings)
            }
            if let source,let record {
                let batches=record.batches(source)
                LabeledContent("服务",value:config.providerID.title)
                LabeledContent("模型",value:config.displayModel)
                LabeledContent("本次",value:"\(batches.flatMap(\.targets).count) 条 · \(batches.count) 次请求")
                Text((try? config.estimate(batches)) ?? "无法估算，请检查模型设置。").font(.caption).foregroundStyle(.secondary)
                Text(config.parallelism==2 ? "已开启加速：最多两个请求同时处理。暂停后等待已发送请求保存；它们仍可能计费。" : "逐组保存，异常即暂停；不会自动重发或更换服务。").font(.caption)
                if config.providerID == .azure {Text("Azure 标准翻译不使用 OpenAI 的提示词和课程术语表。专业术语建议先试译检查。").font(.caption)}
                Divider()
                Text(message).foregroundStyle(.red).font(.caption)
                HStack {Button("取消"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button(config.confirmationLabel) { confirm(record) }.buttonStyle(.borderedProminent).disabled(batches.isEmpty || !job.acceptsQueuedWork || !keyAvailability.configured(config.providerID)).keyboardShortcut(.defaultAction)}
                if !keyAvailability.configured(config.providerID) {Text(config.providerID == .apple ? "此系统不支持本机翻译。" : "请先在设置中保存所选服务的 Key。").font(.caption)}
            } else {Text(message.isEmpty ? "没有可翻译的英文字幕。" : message);Button("关闭"){dismiss()}}
        }.padding(24).frame(width:570)
        .onAppear {do {if let lesson {source=try store.repository?.read(lesson)}}catch{message=error.localizedDescription}}
    }
    private func confirm(_ proposed:TranslationTaskState) {
        do {
            guard job.acceptsQueuedWork,let lesson,let latest=try store.repository?.read(lesson),latest.version==proposed.version else {throw Failure("字幕版本或任务状态已变化，请重新打开确认页")}
            var task=proposed;task.state="排队"
            try job.saveTask(task,lesson:lesson,store:store)
            job.details="";try store.processing.launch([ImportProcessingEntry(id:lessonID,translation:task,analysis:nil)],store:store);dismiss()
        }catch{message=error.localizedDescription}
    }
}
