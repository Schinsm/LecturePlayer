import Foundation
import Combine
import Core

struct UsageFilter:Equatable,Sendable {
    var period:UsagePeriod = .month
    var service="all",model="all",lesson="all",purpose="all"
    func accepts(_ row:UsageEntry)->Bool {
        (service=="all" || (row.value.service ?? .openAI).rawValue==service) && (model=="all" || row.value.model==model) && (lesson=="all" || row.lessonID==lesson) && (purpose=="all" || row.purpose==purpose)
    }
}
struct UsageDay:Identifiable,Sendable {
    var id:Date{date};let date:Date;let count:Int;let caption:String
}
struct UsageTrend:Identifiable,Sendable {
    var id:Date{date};let date:Date;let values:[String:Double]
}
struct UsagePresentationSnapshot: Sendable {
    var summary=UsageSummary([])
    var succeeded=0,failed=0,unknown=0
    var days:[UsageDay]=[]
    var daily:[Date:[UsageEntry]]=[:]
    var trends:[UsageTrend]=[]
    var totals:[String:Double]=[:]
    var models:[String]=[]
    var lessons:[String:String]=[:]
    static func build(_ entries:[UsageEntry],filter:UsageFilter,now:Date=Date(),calendar:Calendar = .current)->Self {
        PerformanceTrace.measure("usage.aggregate") {
            var result=Self();result.models=Array(Set(entries.map{$0.value.model})).sorted()
            for row in entries where row.purpose != "test" {result.lessons[row.lessonID]=row.lesson}
            guard !Task.isCancelled else{return result}
            let selected=entries.filter(filter.accepts)
            result.daily=Dictionary(grouping:selected){calendar.startOfDay(for:$0.value.date)}
            let formatter=DateFormatter();formatter.calendar=calendar;formatter.timeZone=calendar.timeZone;formatter.dateStyle = .medium
            result.days=UsageAggregation.days(now:now,calendar:calendar).map {day in
                let rows=result.daily[day] ?? [];let success=rows.filter{$0.success==true}.count,fail=rows.filter{$0.success==false}.count
                return UsageDay(date:day,count:rows.count,caption:"\(formatter.string(from:day))：\(rows.count) 次请求，成功 \(success)，失败 \(fail)，状态未记录 \(rows.count-success-fail)，测试 \(rows.filter{$0.purpose=="test"}.count) 次")
            }
            guard !Task.isCancelled else{return result}
            let included=selected.filter{filter.period.includes($0.value.date,now:now,calendar:calendar)}
            result.summary=UsageSummary(included.map(\.value));result.succeeded=included.filter{$0.success==true}.count;result.failed=included.filter{$0.success==false}.count;result.unknown=included.count-result.succeeded-result.failed
            let component:Calendar.Component=filter.period == .today ? .hour : filter.period == .month ? .day : .month
            result.trends=UsageAggregation.buckets(included.map(\.value),component:component,calendar:calendar).map {bucket in
                var values:[String:Double]=["requests":Double(bucket.values.count)]
                for u in bucket.values {
                    let service=u.service ?? .openAI
                    if service == .openAI {values["tokens",default:0] += Double((u.inputTokens ?? 0)+(u.outputTokens ?? 0))}
                    else if service == .apple {values["apple",default:0] += Double(u.submittedCharacters ?? 0)}
                    else if let actual=u.meteredCharacters {values[service.rawValue,default:0] += Double(actual)}
                    else {values[service.rawValue+":estimate",default:0] += Double(u.submittedCharacters ?? 0)}
                }
                for (key,value) in values {result.totals[key,default:0] += value}
                return UsageTrend(date:bucket.date,values:values)
            }
            return result
        }
    }
}
@MainActor final class UsagePresentation:ObservableObject {
    @Published private(set) var snapshot=UsagePresentationSnapshot()
    private(set) var entries:[UsageEntry]=[]
    private var lastKey=""
    private var generation=0
    private var task:Task<Void,Never>?
    private var worker:Task<UsagePresentationSnapshot,Never>?
    private(set) var revision=0
    func replace(_ entries:[UsageEntry]) {guard entries != self.entries else{return};self.entries=entries;revision += 1}
    func refresh(_ filter:UsageFilter,now:Date=Date(),calendar:Calendar = .current) async {
        let key="\(revision)-\(filter)-\(calendar.identifier)-\(calendar.timeZone.identifier)-\(calendar.startOfDay(for:now))"
        generation += 1;task?.cancel();worker?.cancel()
        guard key != lastKey else{return}
        let ticket=generation;let values=entries
        let worker=Task.detached(priority:.userInitiated) {UsagePresentationSnapshot.build(values,filter:filter,now:now,calendar:calendar)}
        self.worker=worker
        task=Task {let result=await worker.value;guard !Task.isCancelled,ticket==self.generation else{return};self.snapshot=result;self.lastKey=key}
        await withTaskCancellationHandler {await task?.value} onCancel:{worker.cancel()}
    }
}
