import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V088StatusTests {
    @Test func completedPartialTaskDoesNotClaimWholeLessonComplete() throws {
        let (store,varSource)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        var source=varSource
        let target=source.cues[0].id
        source.translations[target]=Translation(ai:"已译",cacheKey:"mock")
        var task=TranslationTaskState(transcript:source,ids:[target],config:TranslationConfig(model:"gpt-4o-mini"))
        task.state="完成";task.completed=1;source.task=task
        let summary=SavedTranslationSummary(source)
        #expect(summary.label(variant:nil)=="翻译未完成")
        #expect(summary.completed(variant:nil)==1)
        for cue in source.cues {source.translations[cue.id]=Translation(ai:"已译",cacheKey:"mock")}
        #expect(SavedTranslationSummary(source).label(variant:nil)=="翻译完成")
    }
    @Test func servicesRemainSeparateAndBlankTextIsNotComplete() throws {
        let (store,varSource)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        var source=varSource
        for cue in source.cues {source.translations[cue.id]=Translation(ai:"完成",cacheKey:"mock")}
        source.ensureVariant("azure")
        source.variants!["azure"]!.translations[source.cues[0].id]=Translation(ai:"部分",cacheKey:"mock")
        source.variants!["azure"]!.translations[source.cues[1].id]=Translation(ai:" \n ",cacheKey:"mock")
        let summary=SavedTranslationSummary(source)
        #expect(summary.label(variant:"openAI")=="翻译完成")
        #expect(summary.label(variant:"azure")=="翻译未完成")
        #expect(summary.completed(variant:"azure")==1)
        #expect(summary.label(variant:"deepL")=="翻译待处理")
    }
    @Test func snapshotsLoadOnceAndAcceptSavedResultsForUnopenedLessons() async throws {
        let (store,varSource)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        let lesson=store.library.lectures[1]
        #expect(store.current != lesson.id)
        var source=varSource
        source.translations[source.cues[0].id]=Translation(ai:"已保存",cacheKey:"mock")
        try store.repository!.write(source,for:lesson.id)
        store.lessonStatuses.reset()
        await store.lessonStatuses.prepare(lesson,repository:store.repository)
        #expect(store.lessonStatuses.translations[lesson.id]?.completed(variant:nil)==1)
        let file=try store.repository!.transcriptURL(lesson.id,source.version)
        try FileManager.default.removeItem(at:file)
        await store.lessonStatuses.prepare(lesson,repository:store.repository)
        #expect(store.lessonStatuses.translationErrors[lesson.id]==nil)
        source.translations[source.cues[1].id]=Translation(ai:"新保存",cacheKey:"mock")
        store.displayTranscript(source,for:lesson.id)
        #expect(store.lessonStatuses.translations[lesson.id]?.completed(variant:nil)==2)
        var stale=source;stale.version="obsolete"
        store.displayTranscript(stale,for:lesson.id)
        #expect(store.lessonStatuses.translations[lesson.id]?.version==source.version)
    }
    @Test func pendingSynthesisAndFailedRegenerationRemainIncomplete() throws {
        let (store,source)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        var analysis=LessonAnalysis(lessonID:store.library.lectures[0].id,sourceVersion:source.version)
        var task=AnalysisTaskState(config:AnalysisConfig(model:"gpt-4o-mini"),plan:try AnalysisPlan.make(source))
        for chunk in task.plan.chunks {
            task.completedChunks[chunk.id]=[AnalysisChapter(id:chunk.id,startCueID:chunk.targets.first!.id,endCueID:chunk.targets.last!.id,title:"例子",points:["概念","结论"])]
        }
        task.status = .paused;analysis.task=task
        #expect(SavedAnalysisSummary(analysis).label=="总结已暂停")
        #expect(SavedAnalysisSummary(analysis).progress!<1)
        analysis.completed=AnalysisDocument(chapters:task.proposedChapters,overview:[AnalysisOverviewPoint(text:"保留旧结果",chapterID:task.proposedChapters[0].id)])
        analysis.task?.status = .failed
        #expect(SavedAnalysisSummary(analysis).complete)
        #expect(SavedAnalysisSummary(analysis).label=="总结未完成")
        analysis.task=nil
        #expect(SavedAnalysisSummary(analysis).label=="总结完成")
    }
    @Test func restoreClearsAnalysisPresentationButCannotDiscardRunningWork() throws {
        let (store,source)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        let lesson=store.library.lectures[0]
        let record=LessonAnalysis(lessonID:lesson.id,sourceVersion:source.version)
        store.analysis.accept(record)
        #expect(store.analysis.exact(lesson.id,version:source.version) != nil)
        store.analysis.coordinatedLessons.insert(lesson.id)
        store.analysis.resetPresentation()
        #expect(store.analysis.exact(lesson.id,version:source.version) != nil)
        store.analysis.coordinatedLessons.remove(lesson.id)
        store.translation.restore(store)
        #expect(store.analysis.exact(lesson.id,version:source.version)==nil)
        #expect(store.lessonStatuses.translations[lesson.id]?.version==source.version)
    }

    @Test func failedAnalysisRefreshIsVisibleWithoutDiscardingSavedResult() async throws {
        let (store,source)=try V052AppTests().fixture()
        defer {try? FileManager.default.removeItem(at:store.repository!.root)}
        let lesson=store.library.lectures[0]
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:source.version)
        let chapter=AnalysisChapter(id:"saved",startCueID:source.cues.first!.id,endCueID:source.cues.last!.id,title:"保存的章节",points:["概念","结论"])
        record.completed=AnalysisDocument(chapters:[chapter],overview:[AnalysisOverviewPoint(text:"原总结",chapterID:chapter.id)])
        record.completedConfig=AnalysisConfig(model:"gpt-4o-mini");record.completedAt=Date()
        try await AnalysisRepository(root:store.repository!.root).save(record)
        store.analysis.accept(record)
        #expect(store.lessonStatuses.savedAnalysisLabel(lesson,job:store.analysis)=="总结完成")
        let file=AnalysisRepository.fileURL(root:store.repository!.root,lessonID:lesson.id,sourceVersion:source.version)
        try Data("invalid refreshed file".utf8).write(to:file,options:.atomic)
        await store.analysis.load(store:store,lessonID:lesson.id)
        #expect(store.lessonStatuses.analysisIssue(lesson,job:store.analysis) != nil)
        #expect(store.lessonStatuses.savedAnalysisLabel(lesson,job:store.analysis)=="总结失败")
        #expect(store.analysis.exact(lesson.id,version:source.version)?.completed==record.completed)
        #expect(!store.analysis.running && !store.translation.busy)
    }

}
