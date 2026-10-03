import Testing
import Foundation
import SwiftData
import Combine
import AppKit
import Core
@testable import LecturePlayer

@MainActor @Suite("0.8.3 presentation and incremental persistence",.serialized)
struct V083Tests {
    @Test func metadataPatchesPreserveUnrelatedFieldsAndOrderedLastValue() throws {
        let (store,_)=try V052AppTests().fixture();let id=store.library.lectures[0].id
        var changes=0;let subscription=store.objectWillChange.sink{changes += 1}
        for n in 1...100 {store.updateLecture(id,quiet:true){$0.state.position=Double(n)}}
        #expect(changes==0)
        store.updateLecture(id){$0.state.subtitleOffsetSeconds=14;$0.marks=[Mark(seconds:30,note:"keep")];$0.studyPanel="chapters"}
        store.updateLecture(id){$0.studyPanel=nil}
        store.flushMetadata()
        let loaded=try #require(store.repository?.load().lectures.first{$0.id==id})
        #expect(loaded.state.position==100 && loaded.state.offset==14)
        #expect(loaded.marks.count==1 && loaded.studyPanel==nil)
        #expect(loaded.transcriptVersion==store.library.lectures[0].transcriptVersion)
        withExtendedLifetime(subscription){}
    }
    @Test func failedPatchRemainsRetryable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo=try Repository(root:root);var course=Course(name:"Test");course.directoryPath="/test"
        let old=Lecture(title:"lesson",courseID:course.id,folderID:nil,url:URL(fileURLWithPath:"/test/a.mp4"),bookmark:nil,identity:"1")
        var new=old;new.state.position=52
        repo.commits.submit(old:old,new:new){_ in}
        #expect(throws:(any Error).self){try repo.commits.flush()}
        repo.context.insert(MetadataRecord(key:"l-\(old.id)",payload:try Codec.encode(old)));try repo.context.save()
        try repo.commits.flush()
        let context=ModelContext(repo.container)
        let rows=try context.fetch(FetchDescriptor<MetadataRecord>())
        #expect(try Codec.decode(Lecture.self,rows[0].payload).state.position==52)
    }
    @Test func panelSwitchCoalescesAndSessionsKeepReadingState() async throws {
        let state=ReaderPresentationState(),a=UUID(),b=UUID();var saved:[String]=[]
        state.save={_,panel in saved.append(panel)};state.configure(a,panel:"transcript")
        state.session(a).reader.search("cash flow");state.session(a).scrollID="cue-20";state.session(a).expandedTopics=["topic1"]
        for _ in 0..<50 {state.select("chapters",lesson:a);state.select("transcript",lesson:a)}
        #expect(saved.isEmpty);state.select("chapters",lesson:a);state.configure(b,panel:"transcript")
        #expect(saved==["chapters"]);#expect(state.session(a).reader.query=="cash flow")
        #expect(state.session(a).scrollID=="cue-20" && state.session(a).expandedTopics==["topic1"])
        #expect(state.session(b).reader.query.isEmpty)
        try await Task.sleep(for:.milliseconds(400));#expect(saved.count==1)
    }
    @Test func readingContentInvalidatesOnlyAffectedUnitAndSettings() throws {
        let cache=ReadingContentCache();let a=Cue(id:"a",start:0,end:1000,en:"Speaker 0: Cash flow."),b=Cue(id:"b",start:2000,end:3000,en:"Speaker 0: Growth.")
        let units=ReadingIndex([a,b]).units
        for _ in 0..<100 {for unit in units {_=cache.content(unit,translations:[:],mode:"英文",hidden:true)}}
        #expect(cache.builds==2)
        #expect(cache.content(units[0],translations:[:],mode:"英文",hidden:true).text=="Cash flow.")
        _=cache.content(units[0],translations:[:],mode:"英文",hidden:false);#expect(cache.builds==3)
    }
    @Test func directoryIndexLoadsWithoutScanOrLastLesson() throws {
        let (root,varLibrary,_)=try PersistenceTests().fixture();var library=varLibrary;library.lastLecture=nil;library.directoryRoot="/root"
        library.courses[0].directoryPath="/root/CourseA"
        let repo=try Repository(root:root);try repo.save(library)
        let store=AppStore(root:root)
        #expect(store.navigation.index.courses.count==1)
        #expect(store.navigation.index.courses.first?.id==library.courses[0].id)
    }
    @Test func directoriesAreNaturallySortedAndEmptyNodesRemain() {
        var c=Course(name:"CourseA");c.directoryPath="/root/CourseA"
        let folders=["Week10","Week2","Week1"].map{Folder(name:$0,courseID:c.id)}
        let index=DirectoryPresentationIndex(courses:[c],folders:folders,root:"/root")
        #expect(index.roots[c.id]?.map(\.name)==["Week1","Week2","Week10"])
        #expect(index.children.isEmpty && index.courses.count==1)
    }
    @Test func textLayoutCachePreservesSelectionAndInvalidatesAppearance() throws {
        let storage=NSTextStorage(),layout=NSLayoutManager(),container=NSTextContainer(size:NSSize(width:300,height:10000))
        storage.addLayoutManager(layout);layout.addTextContainer(container)
        let view=SelectableCueView(frame:.zero,textContainer:container)
        let text=String(repeating:"Cash flow 现金流。",count:12)
        view.apply(text:text,fontSize:17,lineSpacing:5)
        let first=try #require(view.measuredSize(width:300,fontSize:17));view.setSelectedRange(NSRange(location:2,length:6))
        for _ in 0..<100 {view.apply(text:text,fontSize:17,lineSpacing:5);#expect(view.measuredSize(width:300,fontSize:17)==first)}
        #expect(view.attributeBuilds==1 && view.layoutBuilds==1);#expect(view.selectedRange()==NSRange(location:2,length:6))
        _=view.measuredSize(width:180,fontSize:17);#expect(view.layoutBuilds==2)
        view.apply(text:text,fontSize:25,lineSpacing:9);let larger=try #require(view.measuredSize(width:300,fontSize:25))
        #expect(larger.height>first.height && view.attributeBuilds==2 && view.layoutBuilds==3)
        for width in 100...140 {_=view.measuredSize(width:Double(width),fontSize:25)}
        #expect(view.heights.count<=16)
    }
    @Test func chapterIndexHonorsGapsAndBoundaries() {
        let items=[ChapterPositionIndex.Entry(id:"a",start:10,end:20),ChapterPositionIndex.Entry(id:"b",start:25,end:35)]
        #expect(ChapterPositionIndex.current(items,seconds:9)==nil)
        #expect(ChapterPositionIndex.current(items,seconds:10)=="a")
        #expect(ChapterPositionIndex.current(items,seconds:20)==nil)
        #expect(ChapterPositionIndex.current(items,seconds:25)=="b")
        #expect(ChapterPositionIndex.current(items,seconds:35)==nil)
    }
    @Test func keyAvailabilityIsCachedAndInvalidatedWithoutRenderQueries() async throws {
        let counter=ProbeCounter();let availability=KeychainAvailability{_ in counter.increment();return true}
        for _ in 0..<100 {_=availability.configured(.openAI)}
        try await Task.sleep(for:.milliseconds(100));#expect(availability.configured(.openAI));#expect(counter.value==1)
        for _ in 0..<100 {_=availability.configured(.openAI)}
        #expect(counter.value==1);availability.invalidate(.openAI)
        try await Task.sleep(for:.milliseconds(100));#expect(counter.value==2 && availability.configured(.openAI))
    }
    private func usageRows(_ count:Int,now:Date)->[UsageEntry] {
        (0..<count).map{index in
            let date=now.addingTimeInterval(Double(-index%60)*86400)
            let payload:[String:Any]=["date":date.timeIntervalSinceReferenceDate,"model":"fixture","inputTokens":20,"outputTokens":10,"estimatedUSD":0.001,"batchKey":String(index)]
            let u=try! JSONDecoder().decode(TranslationUsage.self,from:JSONSerialization.data(withJSONObject:payload))
            return UsageEntry(id:String(index),lesson:"same name",lessonID:String(index%2),purpose:index%3==0 ? "test":"course",success:index%4 != 0,value:u)
        }
    }
    @Test func usageFilteringCalendarAndStaleRefresh() async {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Australia/Melbourne")!
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:4,hour:12))!
        let values=usageRows(1200,now:now)
        let s=UsagePresentationSnapshot.build(values,filter:UsageFilter(period:.all,lesson:"1"),now:now,calendar:calendar)
        #expect(s.summary.requests==600 && s.days.count==364)
        #expect(s.trends.reduce(0){$0+($1.values["requests"] ?? 0)}==600)
        #expect(s.totals["tokens"]==18000)
        let p=UsagePresentation();p.replace(values)
        let first=Task{await p.refresh(UsageFilter(period:.all,lesson:"0"),now:now,calendar:calendar)}
        await Task.yield()
        await p.refresh(UsageFilter(period:.all,lesson:"missing"),now:now,calendar:calendar)
        await first.value
        #expect(p.snapshot.summary.requests==0)
        await p.refresh(UsageFilter(period:.all,lesson:"1"),now:now,calendar:calendar)
        let other=Task{await p.refresh(UsageFilter(period:.all,lesson:"0"),now:now,calendar:calendar)}
        await Task.yield()
        await p.refresh(UsageFilter(period:.all,lesson:"1"),now:now,calendar:calendar);await other.value
        #expect(p.snapshot.daily.values.flatMap{$0}.allSatisfy{$0.lessonID=="1"})
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP083_BENCHMARK"] == "1")) func heatmapBaselineVersusSnapshotThreeRounds() async throws {
        let now=Date(),rows=usageRows(6000,now:Date());let days=UsageAggregation.days(now:now)
        let result=await Task.detached { () -> [[String:Double]] in
        var result:[[String:Double]]=[]
        for _ in 0..<3 {
            let start=ProcessInfo.processInfo.systemUptime;var oldCount=0
            for day in days {let daily=Dictionary(grouping:rows){Calendar.current.startOfDay(for:$0.value.date)};oldCount += daily[day]?.count ?? 0}
            let old=ProcessInfo.processInfo.systemUptime-start
            let nextStart=ProcessInfo.processInfo.systemUptime;let snapshot=UsagePresentationSnapshot.build(rows,filter:UsageFilter(period:.all),now:now)
            let newCount=snapshot.days.reduce(0){$0+$1.count};let new=ProcessInfo.processInfo.systemUptime-nextStart
            #expect(oldCount==newCount);result.append(["baselineSeconds":old,"snapshotSeconds":new,"requests":Double(rows.count)])
        }
        return result
        }.value
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP083/usage-benchmark.json"),options:.atomic)
        print("LP083_USAGE_BENCHMARK",String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    }
}

private final class ProbeCounter:@unchecked Sendable {private let lock=NSLock();private var count=0;func increment(){lock.lock();count += 1;lock.unlock()};var value:Int{lock.lock();defer{lock.unlock()};return count}}

@MainActor @Suite("0.8.3 isolated native workload measurements",.serialized)
struct V083WorkloadTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP083_WORKLOAD"] == "1"))
    func pausedPlayingAndBackgroundSaveThreeRounds() async throws {
        let fm=FileManager.default,source=URL(fileURLWithPath:"/private/tmp/LP083/baseline-data")
        let root=fm.temporaryDirectory.appendingPathComponent("LP083-workload-"+UUID().uuidString)
        try fm.copyItem(at:source,to:root)
        let store=AppStore(root:root);store.playback.close()
        defer{store.playback.close();store.flushMetadata()}
        let lesson=try #require(store.library.lectures.first{$0.mediaSources.count==2 && $0.title.contains("SAMPLE1001")})
        // Security bookmarks belong to the installed app; the isolated test uses verified local paths.
        store.updateLecture(lesson.id){value in var sources=value.mediaSources;for i in sources.indices{sources[i].bookmark=nil};value.mediaSources=sources;value.bookmark=nil}
        store.flushMetadata();store.open(lesson.id);store.playback.player.isMuted=true;store.playback.secondaryPlayer.isMuted=true
        for _ in 0..<500 {if store.playback.ready{break};try await Task.sleep(for:.milliseconds(40))}
        try #require(store.playback.ready)
        let repo=try #require(store.repository)
        let transcriptURL=try repo.transcriptURL(lesson.id,try #require(lesson.transcriptVersion))
        let mockURL=root.appendingPathComponent("mock-saved-result.json")
        var results:[[String:Any]]=[]
        for scenario in ["paused","dualVideo","mockSaving"] {
            store.playback.pause()
            if scenario != "paused" {store.playback.toggle();try await Task.sleep(for:.milliseconds(300))}
            let saves=ProbeCounter()
            let background:Task<Void,Error>?=scenario=="mockSaving" ? Task.detached(priority:.utility) {
                while !Task.isCancelled {
                    try Task.checkCancellation()
                    let t=try Codec.decode(Transcript.self,Data(contentsOf:transcriptURL))
                    try Codec.encode(t).write(to:mockURL,options:.atomic);saves.increment()
                    try await Task.sleep(for:.milliseconds(20))
                }
            }:nil
            defer{background?.cancel()}
            for round in 1...3 {
                for incremental in [false,true] {
                    var times:[Double]=[]
                    for n in 0..<50 {
                        let start=ProcessInfo.processInfo.systemUptime
                        if incremental {store.updateLecture(lesson.id,quiet:true){$0.studyPanel=n%2==0 ? "chapters":"transcript"}}
                        else {var next=store.library;let i=try #require(next.lectures.firstIndex{$0.id==lesson.id});next.lectures[i].studyPanel=n%2==0 ? "chapters":"transcript";try repo.save(next);store.library=next}
                        times.append(ProcessInfo.processInfo.systemUptime-start)
                        try await Task.sleep(for:.milliseconds(12))
                    }
                    let writer=repo.commits;try await Task.detached{try writer.flush()}.value
                    times.sort();results.append(["scenario":scenario,"round":round,"path":incremental ? "incremental":"baselineFullSave","mainCallP95Ms":times[Int(Double(times.count-1)*0.95)]*1000,"maxMs":times.last!*1000,"over50ms":times.filter{$0>0.05}.count,"playerReady":store.playback.ready,"playing":store.playback.playing,"backgroundSaves":saves.value])
                }
            }
            background?.cancel();_ = try? await background?.value
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP083/workload-results.json"),options:.atomic)
        print("LP083_WORKLOAD",String(data:try JSONSerialization.data(withJSONObject:results,options:.sortedKeys),encoding:.utf8)!)
        try #require(store.library.lectures.first{$0.id==lesson.id}?.state.offset==lesson.state.offset)
    }
}
