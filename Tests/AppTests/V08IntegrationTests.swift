import Foundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V08IntegrationTests {
    @Test func analysisBlocksTranslationAndServiceEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LP08-gate-" + UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: root)}
        let store = AppStore(root: root)
        store.translation.analyzing = true
        #expect(store.translation.busy)
        store.translation.launch(store: store, ids: [UUID()], provider: V08NeverTranslation())
        #expect(!store.translation.running)
        #expect(throws: (any Error).self) {try store.translation.enqueueImports([], store: store, provider: V08NeverTranslation())}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP08_DATA"] != nil))
    func currentIsolatedLibraryPreservesAllStudyData() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LP08_DATA"])
        guard path.hasPrefix("/private/tmp/LP08-") || ["/private/tmp/LP081/data","/private/tmp/LP082/data","/private/tmp/LP083/data","/private/tmp/LP084/data"].contains(path) else {throw Failure("Only isolated test data allowed")}
        let root = URL(fileURLWithPath: path)
        let repo = try Repository(root: root), library = try repo.load()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("transcripts"), includingPropertiesForKeys: nil).filter {$0.pathExtension == "json"}
        let before = try files.map {try Data(contentsOf: $0)}
        var count = 0, plans = 0
        for bytes in before {
            let transcript = try Codec.decode(Transcript.self, bytes)
            count += transcript.allTranslatedCount
            let plan = try AnalysisPlan.make(transcript)
            try plan.validate()
            #expect(plan.chunks.flatMap(\.targets) == AnalysisPlan.ordered(transcript.cues))
            plans += plan.chunks.count
        }
        try repo.writeRecoverySnapshot(library)
        try repo.save(library)
        #expect(try Repository(root: root).load() == library)
        for (index, file) in files.enumerated() {#expect(try Data(contentsOf: file) == before[index])}
        print("LP08 preservation lessons=\(library.lectures.count) translations=\(count) plannedBlocks=\(plans) transcriptBytesUnchanged=true studyMetadataEqual=true")
    }

    /// Explicit, isolated UI fixture. Its labels never pretend to be a generated lecture summary.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP08_GUI_FIXTURE"] != nil))
    func prepareIsolatedGUIChapterFixture() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LP08_GUI_FIXTURE"])
        guard path.hasPrefix("/private/tmp/LP08-GUI/") else {throw Failure("Only isolated GUI data allowed")}
        let root = URL(fileURLWithPath: path), repo = try Repository(root: root)
        var library = try repo.load()
        let index = try #require(library.lectures.indices.first {library.lectures[$0].title.contains("SAMPLE1001")})
        let lesson = library.lectures[index], transcript = try #require(try repo.read(lesson))
        let cues = AnalysisPlan.ordered(transcript.cues)
        var chapters: [AnalysisChapter] = []
        for n in 0..<3 {
            let begin = n * cues.count / 3, end = (n + 1) * cues.count / 3 - 1
            chapters.append(AnalysisChapter(id: "mock-\(n)", startCueID: cues[begin].id, endCueID: cues[end].id,
                                            title: "离线界面验收章节 \(n + 1)", points: ["此内容仅用于测试点击跳转，不是课程总结。", "核验双语字幕、暂停状态与时间校准。 "]))
        }
        var record = LessonAnalysis(lessonID: lesson.id, sourceVersion: transcript.version)
        record.completed = AnalysisDocument(chapters: chapters, overview: chapters.map {AnalysisOverviewPoint(text: "离线 mock 验收：" + $0.title, chapterID: $0.id)})
        record.completedConfig = AnalysisConfig(model: "gpt-4o-mini");record.completedAt = Date()
        try record.validate(transcript: transcript)
        try await AnalysisRepository(root: root).save(record)
        library.lastLecture = lesson.id
        library.lectures[index].state.offset = 14
        library.lectures[index].state.position = SubtitleTimingMapper(offset: 14).seekTarget(cues[0]) + 0.2
        library.lectures[index].studyPanel = "transcript"
        library.lectures[index].videoCaptions = VideoCaptionPreferences()
        library.lectures[index].directoryChoice = nil
        try repo.save(library)
        print("LP08 isolated GUI fixture ready; no API requests; lesson=\(lesson.id)")
    }
}
private struct V08NeverTranslation: TranslationProvider {
    func translate(_ batch: TranslationBatch, config: TranslationConfig) async throws -> TranslationResult {
        Issue.record("Unexpected cloud request"); return TranslationResult(items: [])
    }
}
