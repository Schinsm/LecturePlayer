import SwiftUI
import Core
import Charts

struct UsageEntry:Identifiable,Sendable,Equatable {var id:String;var lesson:String;var lessonID:String;var purpose:String="course";var success:Bool?;var value:TranslationUsage}
struct AnalysisUsageRow:Identifiable,Sendable {var id:UUID{attempt.id};var lesson:String;var lessonID:String;var attempt:AnalysisAttempt}
struct AttemptEntry:Identifiable,Sendable {var id:UUID{value.id};var lesson:String;var lessonID:String;var value:TranslationAttempt}
struct UsageDataset {var entries:[UsageEntry];var attempts:[AttemptEntry];var translated:Int;var analyses:[AnalysisUsageRow]}
struct TranslationHistory:View {
    @ObservedObject var store:AppStore
    @ObservedObject var job:TranslationJob
    var active=true
    @LPState private var loadedToken=""
    private var loadToken:String {"\(job.running)-\(job.analyzing)-\(job.testRevision)-\(job.usageRevision)"}
    @ObservedObject private var presentation:UsagePresentation
    init(store:AppStore,job:TranslationJob,active:Bool=true){self.store=store;self.job=job;self.active=active;presentation=store.usagePresentation}
    @LPState private var clockRevision=0
    @LPState private var period=UsagePeriod.month
    @LPState private var service="all"
    @LPState private var model="all"
    @LPState private var lesson="all"
    @LPState private var entries:[UsageEntry]=[]
    @LPState private var attempts:[AttemptEntry]=[]
    @LPState private var analysisAttempts:[AnalysisUsageRow]=[]
    @LPState private var diagnosticAttempts:[AttemptEntry]=[]
    @LPState private var diagnosticAnalyses:[AnalysisUsageRow]=[]
    @LPState private var diagnosticGeneration=0
    @LPState private var translated=0
    @LPState private var error=""
    @LPState private var purpose="all"
    private var filter:UsageFilter {UsageFilter(period:period,service:service,model:model,lesson:lesson,purpose:purpose)}
    var body:some View {
        Section("应用用量") {
            Picker("时间",selection:$period){ForEach(UsagePeriod.allCases,id: \.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
            Picker("服务",selection:$service){Text("全部服务").tag("all");ForEach(TranslationService.allCases,id: \.self){Text($0.title).tag($0.rawValue)}}
            Picker("模型",selection:$model){Text("全部模型").tag("all");ForEach(presentation.snapshot.models,id: \.self){Text($0).tag($0)}}
            Picker("课件",selection:$lesson){Text("全部课件").tag("all");ForEach(presentation.snapshot.lessons.keys.sorted(),id: \.self){id in Text(presentation.snapshot.lessons[id] ?? id).tag(id)}}
            Picker("用途",selection:$purpose){Text("全部").tag("all");Text("课程翻译").tag("course");Text("连接测试").tag("test");Text("课程总结").tag("analysis")}
            let summary=presentation.snapshot.summary
            HStack {metric("请求",String(summary.requests));Divider();metric("成功 / 失败 / 未记录", "\(presentation.snapshot.succeeded) / \(presentation.snapshot.failed) / \(presentation.snapshot.unknown)");Divider();metric("已知用量估算",String(format:"$%.4f",summary.usd))}.frame(height:55)
            UsageCharts(snapshot:presentation.snapshot,period:period)
            Text("OpenAI：输入 \(summary.input) · 输出 \(summary.output) tokens").font(.callout)
            Text("缓存输入 \(summary.cached) · 推理输出 \(summary.reasoning)").font(.caption).foregroundStyle(.secondary)
            Text("云翻译字符：服务确认 \(summary.characters) 字符；另有本地估算 \(summary.estimatedCharacters) 字符。").font(.callout)
            Text("Apple 本机：处理 \(summary.localCharacters) 字符，无云 API 费用。").font(.caption)
            if summary.unknown > 0 {Text("\(summary.unknown) 次请求用量不完整或未知").font(.caption).foregroundStyle(.secondary)}
            DisclosureGroup("统计说明") {
                Text("费用按请求时单价估算，未知用量可能另有费用。缓存输入和推理输出是细分，不重复累加；历史缺失字段不补算。这里只统计本应用，日期按本机时区。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {Link("OpenAI 账户用量",destination:URL(string:"https://platform.openai.com/usage")!);Link("Azure 账户用量",destination:URL(string:"https://portal.azure.com/")!)}
            if !error.isEmpty {Text(error).foregroundStyle(.red).font(.caption)}
        }
        Section("诊断") {
            DisclosureGroup("课程总结请求与耗时") {
                ForEach(diagnosticAnalyses) {row in
                    VStack(alignment:.leading,spacing:4) {
                        Text(row.lesson + " · " + row.attempt.stage)
                        Text(row.attempt.date.formatted() + " · " + row.attempt.usage.model)
                        Text(row.attempt.outcome == "completed" ? "完成" : row.attempt.message ?? "请求结果尚未保存完整")
                        Text("请求 " + seconds(row.attempt.requestSeconds) + " · 校验 " + seconds(row.attempt.validationSeconds))
                        Text("请求标识：" + (row.attempt.requestID ?? "未记录"))
                    }.font(.caption).textSelection(.enabled).padding(.vertical,4)
                }
            }
            DisclosureGroup("最近请求与耗时") {
                ForEach(diagnosticAttempts) {entry in
                    VStack(alignment:.leading,spacing:4){
                        Text(entry.lesson).font(.subheadline)
                        Text("\(entry.value.date.formatted()) · \(entry.value.model) · 已存 \(entry.value.saved)/\(entry.value.expected)")
                        Text(entry.value.outcome)
                        Text("请求 \(seconds(entry.value.requestSeconds)) · 校验 \(seconds(entry.value.validationSeconds)) · 资料库 \(seconds(entry.value.databaseSeconds)) · 译文文件 \(seconds(entry.value.sidecarSeconds))")
                        Text("请求标识："+(entry.value.requestID ?? "未记录"))
                    }.font(.caption).textSelection(.enabled).padding(.vertical,4)
                }
            }
        }
        .task(id:"\(active)-\(loadToken)-\(clockRevision)"){if active,loadedToken != loadToken {let token=loadToken;await reload();if !Task.isCancelled {loadedToken=token}}}
        .task(id:"\(active)-\(filter)-\(clockRevision)"){if active {await presentation.refresh(filter);await refreshDiagnostics()}}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in store.usageCache=nil;loadedToken="";clockRevision += 1}
        .onReceive(NotificationCenter.default.publisher(for:.NSCalendarDayChanged)){_ in clockRevision += 1}
        .onReceive(NotificationCenter.default.publisher(for:NSNotification.Name.NSSystemTimeZoneDidChange)){_ in clockRevision += 1}
    }
    private func metric(_ title:String,_ value:String)->some View {VStack(alignment:.leading){Text(title).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3).monospacedDigit()}.frame(maxWidth:.infinity,alignment:.leading)}
    private func seconds(_ value:Double?)->String {value.map{String(format:"%.3fs",$0)} ?? "未记录"}
    private func refreshDiagnostics() async {
        diagnosticGeneration += 1;let ticket=diagnosticGeneration,selection=filter,logs=attempts,analyses=analysisAttempts
        let result=await Task.detached { () -> ([AttemptEntry],[AnalysisUsageRow]) in
            let a=logs.filter{(selection.purpose=="all" || selection.purpose=="course") && selection.period.includes($0.value.date) && (selection.service=="all" || ($0.value.service ?? .openAI).rawValue==selection.service) && (selection.model=="all" || $0.value.model==selection.model) && (selection.lesson=="all" || $0.lessonID==selection.lesson)}.sorted{$0.value.date>$1.value.date}
            let b=analyses.filter{(selection.purpose=="all" || selection.purpose=="analysis") && selection.period.includes($0.attempt.date) && (selection.service=="all" || selection.service=="openAI") && (selection.model=="all" || $0.attempt.usage.model==selection.model) && (selection.lesson=="all" || $0.lessonID==selection.lesson)}.sorted{$0.attempt.date>$1.attempt.date}
            return (Array(a.prefix(30)),Array(b.prefix(30)))
        }.value
        guard !Task.isCancelled,ticket==diagnosticGeneration else{return};diagnosticAttempts=result.0;diagnosticAnalyses=result.1
    }
    private func reload() async {
        guard let root=store.repository?.root else{return}
        let lessons=store.library.lectures
        if store.usageCacheToken==loadToken,let cached=store.usageCache {
            entries=cached.entries;attempts=cached.attempts;analysisAttempts=cached.analyses;translated=cached.translated
            await refreshDiagnostics();presentation.replace(entries);await presentation.refresh(filter);return
        }
        let token=loadToken
        do {
            let result=try await Task.detached { () throws -> ([UsageEntry],[AttemptEntry],Int,[AnalysisUsageRow]) in
                var uses:[UsageEntry]=[],logs:[AttemptEntry]=[];var translated=0
                for url in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("transcripts"),includingPropertiesForKeys:nil) where url.pathExtension=="json" {
                    let t=try Codec.decode(Transcript.self,Data(contentsOf:url))
                    let l=lessons.first{url.lastPathComponent.hasPrefix($0.id.uuidString+"-")};let name=l?.title ?? "历史课件"
                    if l?.transcriptVersion==t.version {translated += t.allTranslatedCount}
                    for (index,u) in (t.usage ?? []).enumerated(){uses.append(UsageEntry(id:url.lastPathComponent+"-\(index)",lesson:name,lessonID:l?.id.uuidString ?? String(url.lastPathComponent.prefix(36)),success:t.attempts?.first{$0.id==u.attemptID}.map{$0.outcome=="完成"},value:u))}
                    logs += (t.attempts ?? []).map{AttemptEntry(lesson:name,lessonID:l?.id.uuidString ?? String(url.lastPathComponent.prefix(36)),value:$0)}
                }
                for test in try ServiceTestLedger.read(root:root) {uses.append(UsageEntry(id:test.id.uuidString,lesson:"连接测试",lessonID:"test",purpose:"test",success:test.success,value:test.usage))}
                var analysisRows:[AnalysisUsageRow]=[]
                for record in try AnalysisRepository.readAll(root:root) {
                    let name=lessons.first{$0.id==record.lessonID}?.title ?? "历史课件"
                    for a in record.attempts {
                        uses.append(UsageEntry(id:a.id.uuidString,lesson:name,lessonID:record.lessonID.uuidString,purpose:"analysis",success:a.outcome=="received" ? nil : a.outcome=="completed",value:a.usage))
                        analysisRows.append(AnalysisUsageRow(lesson:name,lessonID:record.lessonID.uuidString,attempt:a))
                    }
                }
                return (uses,logs,translated,analysisRows)
            }.value
            guard !Task.isCancelled else{return};store.usageCacheToken=token;store.usageCache=UsageDataset(entries:result.0,attempts:result.1,translated:result.2,analyses:result.3);entries=result.0;presentation.replace(result.0);await presentation.refresh(filter);attempts=result.1;translated=result.2;analysisAttempts=result.3;await refreshDiagnostics();error=""
        }catch{self.error="部分用量无法读取："+error.localizedDescription}
    }
}
