import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor SpeedAnalysisMock:AnalysisProvider {
    func analyze(_ chunk:AnalysisChunk,config:AnalysisConfig) async throws -> AnalysisResponse<[AnalysisChapter]> {
        try await Task.sleep(for:.milliseconds(120))
        return AnalysisResponse(value:[AnalysisChapter(id:chunk.id,startCueID:chunk.targets.first!.id,endCueID:chunk.targets.last!.id,title:"Mock topic",points:["Mock point","Second mock point"])],result:TranslationResult(items:[],inputTokens:12,outputTokens:8))
    }
    func synthesize(_ chapters:[AnalysisChapter],config:AnalysisConfig) async throws -> AnalysisResponse<AnalysisDocument> {
        try await Task.sleep(for:.milliseconds(120))
        return AnalysisResponse(value:AnalysisDocument(chapters:chapters,overview:[.init(text:"Mock overview",chapterID:chapters[0].id)]),result:TranslationResult(items:[],inputTokens:12,outputTokens:8))
    }
}
@Suite(.serialized) @MainActor struct V086PerformanceTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP086_PERFORMANCE"] != nil))
    func releaseScanImportAndMockQueue() async throws {
        let label=ProcessInfo.processInfo.environment["LP086_PERFORMANCE"]!
        var results:[[String:Any]]=[]
        for round in 1...3 {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP086-performance-"+UUID().uuidString)
            let media=root.appendingPathComponent("Recordings/QA/Week1")
            try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            for i in 0..<4 {try Data(repeating:UInt8(i+1),count:64*1024*1024).write(to:media.appendingPathComponent("part-\(i).mp4"))}
            let store=AppStore(root:root.appendingPathComponent("Data"));store.library.directoryRoot=root.appendingPathComponent("Recordings").path
            let start=Date();let result=try await store.scanner.scan(root.appendingPathComponent("Recordings"),settle:.milliseconds(1))
            let cold=Date().timeIntervalSince(start)
            let warmStart=Date();_ = try await store.scanner.scan(root.appendingPathComponent("Recordings"),settle:.milliseconds(1));let warm=Date().timeIntervalSince(warmStart)
            store.scanResult=result
            var library=store.library;DirectoryIndex.buildTree(result.directories,root:result.root,library:&library);store.library=library;store.selectedCourse=library.courses.first?.id
            let importStart=Date();var first=0.0
            for (i,url) in result.files.filter({$0.pathExtension=="mp4"}).enumerated() {
                _ = try await store.importLesson(row:ImportRow(video:url,subtitle:nil,title:url.deletingPathExtension().lastPathComponent),managed:false)
                if i==0 {first=Date().timeIntervalSince(importStart)}
            }
            let all=Date().timeIntervalSince(importStart)
            let (queue,t)=try V052AppTests().fixture();let provider=SpeedAnalysisMock()
            let plan=try AnalysisPlan.make(t),config=AnalysisConfig(model:"gpt-4o-mini")
            let entries=queue.library.lectures.map{ImportProcessingEntry(id:$0.id,translation:nil,analysis:AnalysisTaskState(config:config,plan:plan))}
            let queueStart=Date();try queue.processing.launch(entries,store:queue,analysisProvider:provider);await queue.processing.worker?.value
            #expect(queue.processing.entries.allSatisfy{$0.status=="完成"})
            results.append(["round":round,"coldScanSeconds":cold,"warmScanSeconds":warm,"firstLessonSeconds":first,"batchImportSeconds":all,"mockTwoLessonSeconds":Date().timeIntervalSince(queueStart)])
        }
        let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:"/private/tmp/LP086/evidence/performance-"+label+".json"))
        print("LP086_PERFORMANCE",label,String(data:data,encoding:.utf8)!)
    }
}
