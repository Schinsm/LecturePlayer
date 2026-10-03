import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor Queue086Probe:AnalysisProvider {
    var active=0,peak=0,calls=0,merges=0
    let fail:Bool
    var holdingFirst:Bool
    init(fail:Bool=false,holdFirst:Bool=false){self.fail=fail;holdingFirst=holdFirst}
    func releaseFirst(){holdingFirst=false}
    func analyze(_ chunk:AnalysisChunk,config:AnalysisConfig) async throws -> AnalysisResponse<[AnalysisChapter]> {
        calls += 1;active += 1;peak=max(peak,active);defer{active -= 1}
        if calls==1 {while holdingFirst {try await Task.sleep(for:.milliseconds(5))}}
        try await Task.sleep(for:.milliseconds(100))
        let chapter=AnalysisChapter(id:chunk.id,startCueID:chunk.targets.first!.id,endCueID:chunk.targets.last!.id,title:"Topic",points:["First point","Second point"])
        return AnalysisResponse(value:fail ? nil:[chapter],result:TranslationResult(items:[],inputTokens:20,outputTokens:10,problem:fail ? "mock failure":nil))
    }
    func synthesize(_ chapters:[AnalysisChapter],config:AnalysisConfig) async throws -> AnalysisResponse<AnalysisDocument> {
        merges += 1
        return AnalysisResponse(value:AnalysisDocument(chapters:chapters,overview:[.init(text:"Summary",chapterID:chapters[0].id)]),result:TranslationResult(items:[],inputTokens:20,outputTokens:10))
    }
}
@Suite(.serialized) @MainActor struct V086QueueTests {
    func entries(_ s:AppStore,_ t:Transcript)throws->[ImportProcessingEntry] {
        let plan=try AnalysisPlan.make(t)
        return s.library.lectures.map{ImportProcessingEntry(id:$0.id,translation:nil,analysis:AnalysisTaskState(config:AnalysisConfig(model:"gpt-4o-mini"),plan:plan))}
    }
    @Test func appendWhileFirstLessonRunsAndCompletedRegenerationDoesNotRepeat() async throws {
        let (s,t)=try V052AppTests().fixture(),mock=Queue086Probe(holdFirst:true),tasks=try entries(s,t)
        try s.processing.launch([tasks[0]],store:s,analysisProvider:mock)
        while await mock.calls==0 {try await Task.sleep(for:.milliseconds(2))}
        try s.processing.launch([tasks[1]],store:s,analysisProvider:mock)
        let deadline=Date().addingTimeInterval(10)
        while await mock.calls<2,Date()<deadline {try await Task.sleep(for:.milliseconds(5))}
        await mock.releaseFirst()
        await s.processing.worker?.value
        #expect(await mock.calls==2);#expect(await mock.peak==2)
        #expect(s.processing.entries.allSatisfy{$0.status=="完成"})
        var regenerate=tasks[0];regenerate.created=Date();regenerate.regenerateAnalysis=true
        try s.processing.launch([regenerate],store:s,analysisProvider:mock);await s.processing.worker?.value
        #expect(await mock.calls==3)
        try s.processing.launch([regenerate],store:s,analysisProvider:mock);await s.processing.worker?.value
        #expect(await mock.calls==3)
    }
    @Test func importArrivalAfterFailureStaysPendingUntilManualResume() async throws {
        let (s,t)=try V052AppTests().fixture(),bad=Queue086Probe(fail:true),tasks=try entries(s,t)
        try s.processing.launch([tasks[0]],store:s,analysisProvider:bad,deferIfPaused:true)
        await s.processing.worker?.value
        #expect(s.processing.paused)
        try s.processing.launch([tasks[1]],store:s,analysisProvider:bad,deferIfPaused:true)
        #expect(!s.processing.running && s.processing.entries.count==2)
        #expect(await bad.calls==1)
        let reopened=AppStore(root:s.repository!.root),good=Queue086Probe()
        #expect(!reopened.translation.busy)
        try reopened.processing.launch(reopened.processing.entries,store:reopened,analysisProvider:good)
        await reopened.processing.worker?.value
        #expect(await good.calls==2)
        #expect(reopened.processing.entries.allSatisfy{$0.status=="完成"})
    }
}
