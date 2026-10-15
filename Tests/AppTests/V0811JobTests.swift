import Foundation
import Testing
import Core
@testable import LecturePlayer

private actor ChapterJobMock:AnalysisProvider {
    var blocks=0,merges=0
    let failFinal:Bool
    init(failFinal:Bool=false){self.failFinal=failFinal}
    func analyze(_ chunk:AnalysisChunk,config:AnalysisConfig)async throws->AnalysisResponse<[AnalysisChapter]> {
        blocks += 1
        var point=AnalysisChapter(id:chunk.id,startCueID:chunk.targets.first!.id,endCueID:chunk.targets.last!.id,title:"Synthetic concept",points:["Synthetic explanation"])
        point.memberCueIDs=chunk.targets.map(\.id)
        return AnalysisResponse(value:[point],result:TranslationResult(items:[],inputTokens:10,outputTokens:10))
    }
    func synthesize(_ chapters:[AnalysisChapter],config:AnalysisConfig)async throws->AnalysisResponse<AnalysisDocument> {
        merges += 1
        if failFinal {return AnalysisResponse(value:nil,result:TranslationResult(items:[],problem:"Mock final stage interrupted"))}
        var document=AnalysisDocument(chapters:chapters,overview:[])
        document.topics=[AnalysisTopic(id:"topic",title:"Synthetic chapter",overview:"Short chapter description",subtopics:chapters)]
        return AnalysisResponse(value:document,result:TranslationResult(items:[],inputTokens:10,outputTokens:10))
    }
}
@MainActor @Suite(.serialized) struct V0811JobTests {
    func fixture()throws->(AppStore,Lecture,Transcript,AnalysisTaskState) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP0811-job-"+UUID().uuidString)
        let store=AppStore(root:root),course=Course(name:"Synthetic")
        let t=try SubtitleParser.parse(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nSynthetic cue\n".utf8),format:"vtt")
        var lesson=Lecture(title:"Synthetic",courseID:course.id,folderID:nil,url:root.appendingPathComponent("video.mp4"),bookmark:nil,identity:"synthetic")
        lesson.transcriptVersion=t.version;store.library.courses=[course];store.library.lectures=[lesson]
        try store.repository!.write(t,for:lesson.id);store.persist()
        var config=AnalysisConfig(model:"gpt-4o-mini");config.protocolVersion=4
        return(store,lesson,t,AnalysisTaskState(config:config,plan:try AnalysisPlan.make(t)))
    }
    @Test func chapterOnlyFinalFailureResumesWithoutRepeatingBlocks()async throws {
        let (store,lesson,t,task)=try fixture(),mock=ChapterJobMock(failFinal:true)
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        try store.analysis.launch(store:store,lessonID:lesson.id,proposed:task,provider:mock)
        await store.analysis.worker?.value
        let repository=AnalysisRepository(root:store.repository!.root)
        let failed=try #require(try await repository.load(lessonID:lesson.id,sourceVersion:t.version))
        #expect(failed.schema==3 && failed.task?.status == .failed && failed.task?.pendingChunks.isEmpty==true)
        let resumed=AppStore(root:store.repository!.root),finishing=ChapterJobMock()
        await resumed.analysis.load(store:resumed,lessonID:lesson.id)
        #expect(!resumed.analysis.running)
        try resumed.analysis.launch(store:resumed,lessonID:lesson.id,proposed:try #require(failed.task),provider:finishing)
        await resumed.analysis.worker?.value
        let complete=try #require(try await repository.load(lessonID:lesson.id,sourceVersion:t.version))
        try complete.validate(transcript:t)
        #expect(complete.schema==3 && complete.task==nil && complete.completed?.overview.isEmpty==true)
        #expect(await finishing.blocks==0);#expect(await finishing.merges==1)
    }
    @Test func failedInitialCheckpointDispatchesNothingAndCanBeRetriedAfterRepair()async throws {
        let (store,lesson,t,task)=try fixture(),mock=ChapterJobMock()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        let folder=AnalysisRepository.fileURL(root:store.repository!.root,lessonID:lesson.id,sourceVersion:t.version).deletingLastPathComponent()
        try Data("Simulated unavailable directory".utf8).write(to:folder)
        try store.analysis.launch(store:store,lessonID:lesson.id,proposed:task,provider:mock)
        await store.analysis.worker?.value
        #expect(await mock.blocks==0);#expect(await mock.merges==0)
        #expect(!store.analysis.running && store.error != nil)
        try FileManager.default.removeItem(at:folder)
        try store.analysis.launch(store:store,lessonID:lesson.id,proposed:task,provider:mock)
        await store.analysis.worker?.value
        let saved=try await AnalysisRepository(root:store.repository!.root).load(lessonID:lesson.id,sourceVersion:t.version)
        #expect(saved?.completed != nil && saved?.schema==3)
    }
}
