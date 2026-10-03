import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor ProcessingProbe: TranslationProvider, AnalysisProvider {
    var active=0,peak=0,translations=0,analyses=0,syntheses=0
    var failTranslation:Bool
    init(fail:Bool=false) {failTranslation=fail}
    func begin() {active+=1;peak=max(peak,active)}
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        begin();translations+=1;defer{active-=1}
        try await Task.sleep(nanoseconds:60_000_000)
        return TranslationResult(items:failTranslation ? [] : batch.targets.map{TranslatedItem(id:$0.id,zh:"译文"+$0.id)},inputTokens:20,outputTokens:10,problem:failTranslation ? "mock failure" : nil)
    }
    func analyze(_ chunk:AnalysisChunk,config:AnalysisConfig) async throws -> AnalysisResponse<[AnalysisChapter]> {
        begin();analyses+=1;defer{active-=1}
        try await Task.sleep(nanoseconds:130_000_000)
        let points=try HierarchicalAnalysis.build([.init(start:"c0001",title:"概念",points:["说明"])],chunk:chunk)
        return AnalysisResponse(value:points,result:TranslationResult(items:[],inputTokens:20,outputTokens:10))
    }
    func synthesize(_ points:[AnalysisChapter],config:AnalysisConfig) async throws -> AnalysisResponse<AnalysisDocument> {
        begin();syntheses+=1;defer{active-=1}
        try await Task.sleep(nanoseconds:60_000_000)
        var doc=AnalysisDocument(chapters:points,overview:[.init(text:"总结",chapterID:points[0].id)])
        doc.topics=[AnalysisTopic(id:"t",title:"主题",overview:"概述",subtopics:points)]
        return AnalysisResponse(value:doc,result:TranslationResult(items:[],inputTokens:20,outputTokens:10))
    }
}
@Suite(.serialized) @MainActor struct V081ProcessingTests {
    func proposed(_ s:AppStore,_ t:Transcript) throws -> [ImportProcessingEntry] {
        var tc=TranslationConfig(model:"gpt-4o-mini");tc.accelerated=true
        var ac=AnalysisConfig(model:"gpt-5.6-luna");ac.protocolVersion=2;ac.resolvedModels=ResolvedModelPlan.analysis(ac,automatic:true)
        return try s.library.lectures.map {l in
            ImportProcessingEntry(id:l.id,translation:TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:tc),analysis:AnalysisTaskState(config:ac,plan:try AnalysisPlan.make(t)))
        }
    }
    @Test func parallelBoundedScopeSaveAndReopenNoRequest() async throws {
        let (s,t)=try V052AppTests().fixture(),mock=ProcessingProbe()
        let entries=try proposed(s,t)
        try s.processing.launch(entries,store:s,translationProvider:{_ in mock},analysisProvider:mock)
        s.current=s.library.lectures.last!.id
        await s.processing.worker?.value
        #expect(await mock.peak==2)
        #expect(s.processing.entries.allSatisfy{$0.status=="完成"})
        #expect(await mock.translations==6); #expect(await mock.analyses==2); #expect(await mock.syntheses==2)
        for lesson in s.library.lectures {
            #expect(try s.repository!.read(lesson)?.translatedCount==25)
            let record=try await AnalysisRepository(root:s.repository!.root).load(lessonID:lesson.id,sourceVersion:t.version)
            #expect(record?.completed?.topics?.count==1)
            #expect(record?.attempts.last?.usage.model=="gpt-5.6-terra")
            #expect(lesson.state.offset==14)
        }
        let reopened=AppStore(root:s.repository!.root)
        #expect(!reopened.processing.running && !reopened.translation.busy)
        let before=await mock.translations
        try reopened.processing.launch(entries,store:reopened,translationProvider:{_ in mock},analysisProvider:mock)
        await reopened.processing.worker?.value
        #expect(await mock.translations==before)
        let backup=try reopened.snapshot();#expect(backup.schema==6)
        try backup.validate()
    }
    @Test func failureDrainsBothRequestsThenResumesOnlyMissing() async throws {
        let (s,t)=try V052AppTests().fixture(),mock=ProcessingProbe(fail:true)
        try s.processing.launch(try proposed(s,t),store:s,translationProvider:{_ in mock},analysisProvider:mock)
        await s.processing.worker?.value
        #expect(await mock.translations + mock.analyses == 2); #expect(await mock.syntheses==0)
        let record=try await AnalysisRepository(root:s.repository!.root).load(lessonID:s.library.lectures[0].id,sourceVersion:t.version)
        #expect(record?.completed == nil)
        #expect(s.processing.entries.allSatisfy{$0.status != "完成"})
        let reopened=AppStore(root:s.repository!.root),success=ProcessingProbe()
        #expect(!reopened.processing.running)
        try reopened.processing.launch(reopened.processing.entries,store:reopened,translationProvider:{_ in success},analysisProvider:success)
        await reopened.processing.worker?.value
        #expect(await success.analyses + mock.analyses == 2)
        #expect(reopened.processing.entries.allSatisfy{$0.status=="完成"})
    }
    @Test func explicitPauseDrainsAndChangedVersionRejectedBeforeDispatch() async throws {
        let (s,t)=try V052AppTests().fixture(),mock=ProcessingProbe()
        let entries=try proposed(s,t)
        try s.processing.launch(entries,store:s,translationProvider:{_ in mock},analysisProvider:mock)
        for _ in 0..<100 {if await mock.active==2 {break};try await Task.sleep(nanoseconds:2_000_000)}
        s.processing.pause(s);await s.processing.worker?.value
        #expect(await mock.translations + mock.analyses == 2); #expect(await mock.syntheses==0)
        s.updateLecture(entries[0].id){$0.transcriptVersion="changed"}
        #expect(throws:(any Error).self) {try s.processing.launch(entries,store:s,translationProvider:{_ in mock},analysisProvider:mock)}
        #expect(await mock.translations + mock.analyses == 2)
    }
}
