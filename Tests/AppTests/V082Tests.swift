import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor ChapterQueueMock:AnalysisProvider {
    var calls:[String]=[]
    var fail=false
    init(fail:Bool=false) {self.fail=fail}
    func analyze(_ chunk:AnalysisChunk,config:AnalysisConfig) async throws -> AnalysisResponse<[AnalysisChapter]> {
        calls.append("analyze")
        try await Task.sleep(for:.milliseconds(80))
        let result=TranslationResult(items:[],inputTokens:12,outputTokens:8,problem:fail ? "mock failure" : nil)
        return AnalysisResponse(value:try HierarchicalAnalysis.build([.init(start:"c0001",title:"知识点",points:["说明"])],chunk:chunk),result:result)
    }
    func synthesize(_ points:[AnalysisChapter],config:AnalysisConfig) async throws -> AnalysisResponse<AnalysisDocument> {
        calls.append("synthesis")
        var doc=AnalysisDocument(chapters:points,overview:[.init(text:"总结",chapterID:points[0].id)])
        doc.topics=[AnalysisTopic(id:"topic",title:"主题",overview:"概述",subtopics:points)]
        return AnalysisResponse(value:doc,result:TranslationResult(items:[],inputTokens:10,outputTokens:10))
    }
}
@Suite(.serialized) @MainActor struct V082Tests {
    func config()->AnalysisConfig {var c=AnalysisConfig(model:"gpt-4o-mini");c.protocolVersion=2;return c}
    func entries(_ store:AppStore)throws->[ImportProcessingEntry] {
        try ChapterBatchPlanner.rows(ids:Set(store.library.lectures.map(\.id)),store:store,config:config()).compactMap(\.entry)
    }
    @Test func dragPreviewNeverSavesUntilReleaseThenSavesLatest() async throws {
        let p=CaptionPresentation(),id=UUID();var saved:[VideoCaptionPreferences]=[]
        p.save={lesson,value in #expect(lesson==id);saved.append(value)}
        p.configure(id,value:VideoCaptionPreferences());p.setEditing(true)
        for n in 0..<200 {p.update{$0.transparency=Double(n)/200}}
        try await Task.sleep(for:.milliseconds(450))
        #expect(saved.isEmpty);#expect(p.value.transparency==0.995)
        p.setEditing(false);#expect(saved.count==1 && saved[0].transparency==0.995)
        p.flush();#expect(saved.count==1)
    }
    @Test func keyboardDebounceAndLessonChangeDoNotLoseOrLeakEdits() async throws {
        let p=CaptionPresentation(),a=UUID(),b=UUID();var saved:[UUID:VideoCaptionPreferences]=[:]
        p.save={saved[$0]=$1};p.configure(a,value:VideoCaptionPreferences())
        p.update{$0.fontSize=29};p.update{$0.fontSize=30}
        try await Task.sleep(for:.milliseconds(450));#expect(saved[a]?.fontSize==30)
        p.setEditing(true);p.update{$0.fontSize=32};p.configure(b,value:VideoCaptionPreferences())
        #expect(saved[a]?.fontSize==32);#expect(p.value.fontSize==22)
        p.update{$0.fontSize=25};p.flush();#expect(saved[b]?.fontSize==25)
    }
    @Test func chaptersSequentialSkipCompletedAndNoRestartRequest() async throws {
        let (store,_)=try V052AppTests().fixture(),mock=ChapterQueueMock()
        let pending=try entries(store);#expect(pending.count==2)
        try store.processing.launch(pending,store:store,analysisProvider:mock)
        store.current=store.library.lectures.last!.id
        await store.processing.worker?.value
        #expect(await mock.calls==["analyze","synthesis","analyze","synthesis"])
        #expect(store.processing.entries.allSatisfy{$0.status=="完成" && $0.purpose=="chapters"})
        #expect(try entries(store).isEmpty)
        let reopened=AppStore(root:store.repository!.root)
        #expect(!reopened.processing.running && !reopened.analysis.running)
        #expect(await mock.calls.count==4)
        #expect(try reopened.snapshot().processing?.count==2)
    }
    @Test func failureStopsNextLessonFrozenResumeAndDuplicateRejected() async throws {
        let (store,_)=try V052AppTests().fixture(),bad=ChapterQueueMock(fail:true)
        let pending=try entries(store)
        #expect(throws:(any Error).self) {try store.processing.launch([pending[0],pending[0]],store:store,analysisProvider:bad)}
        try store.processing.launch(pending,store:store,analysisProvider:bad)
        await store.processing.worker?.value;#expect(await bad.calls==["analyze"])
        let reopened=AppStore(root:store.repository!.root),good=ChapterQueueMock()
        #expect(!reopened.processing.running)
        let preview=try ChapterBatchPlanner.rows(ids:Set(pending.map(\.id)),store:reopened,config:AnalysisConfig(model:"changed"))
        #expect(preview.first{$0.id==pending[0].id}?.entry?.analysis?.config==pending[0].analysis?.config)
        try reopened.processing.launch(reopened.processing.entries,store:reopened,analysisProvider:good)
        await reopened.processing.worker?.value
        #expect(await good.calls==["analyze","synthesis","analyze","synthesis"])
    }
    @Test func pausedBlockResumesWithoutReanalyzingAndChangedVersionBlocks() async throws {
        let (store,_)=try V052AppTests().fixture(),mock=ChapterQueueMock()
        let pending=try entries(store)
        try store.processing.launch(pending,store:store,analysisProvider:mock)
        while await mock.calls.isEmpty {try await Task.sleep(for:.milliseconds(2))}
        store.processing.pause(store);await store.processing.worker?.value
        #expect(await mock.calls==["analyze"])
        let good=ChapterQueueMock()
        try store.processing.launch(store.processing.entries,store:store,analysisProvider:good)
        await store.processing.worker?.value
        #expect(await good.calls==["synthesis","analyze","synthesis"])
        store.updateLecture(pending[0].id){$0.transcriptVersion="changed"}
        #expect(throws:(any Error).self) {try store.processing.launch(pending,store:store,analysisProvider:good)}
    }
    @Test func serviceTestAndPendingTranslationCannotBeOverwritten() throws {
        let (store,t)=try V052AppTests().fixture(),mock=ChapterQueueMock()
        let pending=try entries(store)
        store.translation.testing=true
        #expect(throws:(any Error).self) {try store.processing.launch(pending,store:store,analysisProvider:mock)}
        store.translation.testing=false
        let entry=ImportProcessingEntry(id:pending[0].id,translation:TranslationTaskState(transcript:t,ids:t.cues.map(\.id),config:TranslationConfig(model:"gpt-4o-mini")),analysis:nil)
        try Codec.encode([entry]).write(to:store.repository!.root.appendingPathComponent("processing-queue.json"))
        store.processing.restore(store)
        #expect(try entries(store).count==1)
    }
}
