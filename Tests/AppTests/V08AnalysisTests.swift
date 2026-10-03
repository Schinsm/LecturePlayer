import Foundation
import AVFoundation
import Testing
@testable import Core
@testable import LecturePlayer

private actor AnalysisMock: AnalysisProvider {
    enum Mode: Sendable { case success, malformed, incomplete, synthesisFailure, notSent }
    let mode: Mode
    let delay: UInt64
    var chunks: [String] = []
    var merges = 0
    init(_ mode: Mode = .success, delay: UInt64 = 0) { self.mode = mode; self.delay = delay }
    func analyze(_ chunk: AnalysisChunk, config: AnalysisConfig) async throws -> AnalysisResponse<[AnalysisChapter]> {
        if mode == .notSent { throw AnalysisNotSent("本地检查未通过，请重新确认范围") }
        chunks.append(chunk.id)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let chapter = AnalysisChapter(id: chunk.id + "-topic", startCueID: mode == .malformed ? "unknown" : chunk.targets.first!.id,
                                      endCueID: chunk.targets.last!.id, title: "现金流 Cash flow", points: ["说明概念", "比较例子"])
        if mode == .incomplete {
            return AnalysisResponse(value: nil, result: TranslationResult(items: [], inputTokens: 100, outputTokens: 6000,
                problem: "达到输出上限", requestID: "mock-incomplete", diagnostics: TranslationDiagnostics(status: "incomplete", incompleteReason: "max_output_tokens")))
        }
        return AnalysisResponse(value: [chapter], result: TranslationResult(items: [], inputTokens: 100, outputTokens: 50, requestID: "mock-block"))
    }
    func synthesize(_ chapters: [AnalysisChapter], config: AnalysisConfig) async throws -> AnalysisResponse<AnalysisDocument> {
        merges += 1
        if mode == .synthesisFailure { return AnalysisResponse(value: nil, result: TranslationResult(items: [], inputTokens: 70, outputTokens: 20, problem: "mock synthesis stopped")) }
        return AnalysisResponse(value: AnalysisDocument(chapters: chapters, overview: chapters.prefix(6).map { AnalysisOverviewPoint(text: "回顾 " + $0.title, chapterID: $0.id) }),
                                result: TranslationResult(items: [], inputTokens: 70, outputTokens: 30, requestID: "mock-summary"))
    }
}

@Suite(.serialized) @MainActor struct V08AnalysisAppTests {
    private func fixture() throws -> (AppStore, Lecture, Transcript) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LP08-analysis-" + UUID().uuidString)
        let store = AppStore(root: root)
        let course = Course(name: "Analysis QA", order: 0)
        store.library.courses = [course]
        let original = Data("Isolated summary fixture, no user transcript".utf8)
        var transcript = Transcript(version: digest(original), original: original, format: "vtt",
            cues: (0..<30).map { Cue(id: "cue-\($0)", start: $0 * 50000, end: ($0 + 1) * 50000, en: "Operating cash flow sample \($0).") })
        transcript.translations["cue-0"] = Translation(ai: "原译文必须保留", cacheKey: "existing")
        var lesson = Lecture(title: "Mock lecture", courseID: course.id, folderID: nil, url: root.appendingPathComponent("video.mp4"), bookmark: nil, identity: "mock")
        lesson.transcriptVersion = transcript.version; lesson.state.offset = 14; lesson.state.speed = 1.5
        lesson.state.record(87, ready: true); lesson.marks = [Mark(seconds: 54, note: "保留书签")]
        try store.repository!.write(transcript, for: lesson.id)
        store.library.lectures = [lesson]; store.persist()
        return (store, lesson, transcript)
    }
    private func proposal(_ transcript: Transcript) throws -> AnalysisTaskState {
        AnalysisTaskState(config: AnalysisConfig(model: "gpt-4o-mini"), plan: try AnalysisPlan.make(transcript))
    }
    private func waitForFirst(_ mock: AnalysisMock) async throws {
        for _ in 0..<100 {
            if await !mock.chunks.isEmpty { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Mock request was never dispatched")
    }
    @Test func successfulAnalysisPreservesLearningDataAndTranslation() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let sourceURL = try store.repository!.transcriptURL(lesson.id, transcript.version)
        let before = try Data(contentsOf: sourceURL), frozen = try proposal(transcript)
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: mock)
        #expect(store.translation.analyzing)
        await store.analysis.worker?.value
        let saved = try #require(try await AnalysisRepository(root: store.repository!.root).load(lessonID: lesson.id, sourceVersion: transcript.version))
        try saved.validate(transcript: transcript)
        #expect(saved.completed != nil && saved.task == nil)
        #expect(saved.attempts.count == frozen.plan.estimatedRequests)
        #expect(saved.attempts.allSatisfy { $0.outcome == "completed" && $0.usage.inputTokens != nil })
        #expect(try Data(contentsOf: sourceURL) == before)
        #expect(store.library.lectures[0].state == lesson.state && store.library.lectures[0].marks == lesson.marks)
        #expect(!store.translation.analyzing && !store.analysis.running)
    }
    @Test func manualPauseSavesInflightThenResumeSkipsSavedChunksAfterRestart() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock(delay: 100_000_000)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let frozen = try proposal(transcript)
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: mock)
        try await waitForFirst(mock); store.analysis.pause(); await store.analysis.worker?.value
        let repo = AnalysisRepository(root: store.repository!.root)
        let paused = try #require(try await repo.load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(paused.task?.completedChunks.count == 1 && paused.task?.status == .paused)
        #expect(await mock.chunks.count == 1)
        #expect(await mock.merges == 0)
        let reopened = AppStore(root: store.repository!.root), resume = AnalysisMock()
        await reopened.analysis.load(store: reopened, lessonID: lesson.id)
        #expect(!reopened.analysis.running && !reopened.translation.analyzing)
        #expect(await resume.chunks.isEmpty)
        try reopened.analysis.launch(store: reopened, lessonID: lesson.id, proposed: try #require(paused.task), provider: resume)
        await reopened.analysis.worker?.value
        #expect(await resume.chunks.count == frozen.plan.chunks.count - 1)
        #expect(await !resume.chunks.contains(frozen.plan.chunks[0].id))
        #expect(try await repo.load(lessonID: lesson.id, sourceVersion: transcript.version)?.completed != nil)
    }
    @Test(arguments: [false, true]) func malformedAndIncompleteResponsesSaveUsageAndStopWithoutRetry(incomplete: Bool) async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock(incomplete ? .incomplete : .malformed)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: proposal(transcript), provider: mock)
        await store.analysis.worker?.value
        let saved = try #require(try await AnalysisRepository(root: store.repository!.root).load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(saved.completed == nil && saved.task?.status == .failed)
        #expect(saved.task?.completedChunks.isEmpty == true)
        #expect(saved.attempts.count == 1 && saved.attempts[0].usage.inputTokens == 100)
        #expect(saved.attempts[0].outcome == "failed")
        #expect(await mock.chunks.count == 1)
        #expect(await mock.merges == 0)
    }
    @Test func regenerationRetainsCompletedDocumentWhenSynthesisFails() async throws {
        let (store, lesson, transcript) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let frozen = try proposal(transcript), repo = AnalysisRepository(root: store.repository!.root)
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: AnalysisMock())
        await store.analysis.worker?.value
        let first = try #require(try await repo.load(lessonID: lesson.id, sourceVersion: transcript.version))
        let failing = AnalysisMock(.synthesisFailure)
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: failing)
        await store.analysis.worker?.value
        let failed = try #require(try await repo.load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(failed.completed == first.completed && failed.completedAt == first.completedAt)
        #expect(failed.task?.status == .failed && failed.task?.pendingChunks.isEmpty == true)
        let finishing = AnalysisMock()
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: try #require(failed.task), provider: finishing)
        await store.analysis.worker?.value
        #expect(await finishing.chunks.isEmpty)
        #expect(await finishing.merges == 1)
    }
    @Test func cancellationPersistsUnknownUsageAndDoesNotDispatchAgain() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock(delay: 1_000_000_000)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: proposal(transcript), provider: mock)
        try await waitForFirst(mock); store.analysis.cancel(); await store.analysis.worker?.value
        let saved = try #require(try await AnalysisRepository(root: store.repository!.root).load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(saved.attempts.count == 1 && saved.attempts[0].usage.inputTokens == nil)
        #expect(saved.attempts[0].outcome == "cancelled")
        #expect(await mock.chunks.count == 1)
        #expect(await mock.merges == 0)
    }
    @Test func subtitleChangeStopsSavingNewChaptersAndRetainsAttemptUsage() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock(delay: 100_000_000)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: proposal(transcript), provider: mock)
        try await waitForFirst(mock)
        store.updateLecture(lesson.id) { $0.transcriptVersion = String(repeating: "a", count: 64) }
        await store.analysis.worker?.value
        let saved = try #require(try await AnalysisRepository(root: store.repository!.root).load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(saved.completed == nil && saved.task?.completedChunks.isEmpty == true)
        #expect(saved.attempts.count == 1 && saved.attempts[0].usage.inputTokens == 100)
        #expect(await mock.chunks.count == 1)
    }
    @Test func conflictsPreventDispatchAndLoadNeverRunsSavedTasks() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let frozen = try proposal(transcript)
        store.translation.testing = true
        #expect(throws: (any Error).self) { try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: mock) }
        store.translation.testing = false; store.translation.running = true
        #expect(throws: (any Error).self) { try store.analysis.launch(store: store, lessonID: lesson.id, proposed: frozen, provider: mock) }
        store.translation.running = false
        var record = LessonAnalysis(lessonID: lesson.id, sourceVersion: transcript.version); record.task = frozen
        let repo = AnalysisRepository(root: store.repository!.root)
        try await repo.save(record); await store.analysis.load(store: store, lessonID: lesson.id)
        #expect(store.analysis.exact(lesson.id, version: transcript.version)?.task != nil)
        #expect(await mock.chunks.isEmpty)
        try FileManager.default.removeItem(at: AnalysisRepository.fileURL(root: store.repository!.root, lessonID: lesson.id, sourceVersion: transcript.version))
        await store.analysis.load(store: store, lessonID: lesson.id)
        #expect(store.analysis.exact(lesson.id, version: transcript.version) == nil)
    }
    @Test func changedFrozenTextAndInvalidConfigurationAreRejectedBeforeRequest() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        var altered = try proposal(transcript)
        altered.plan.chunks[0].targets[0].en = "Tampered text with unchanged cue identity"
        #expect(throws: (any Error).self) { try store.analysis.launch(store: store, lessonID: lesson.id, proposed: altered, provider: mock) }
        var invalid = try proposal(transcript); invalid.config.outputLimit = 999999
        #expect(throws: (any Error).self) { try store.analysis.launch(store: store, lessonID: lesson.id, proposed: invalid, provider: mock) }
        var context = try proposal(transcript)
        context.plan.chunks[0].contextAfter = [Cue(id: "unknown-context", start: 1, end: 2, en: "Not in the source")]
        #expect(throws: (any Error).self) { try store.analysis.launch(store: store, lessonID: lesson.id, proposed: context, provider: mock) }
        #expect(await mock.chunks.isEmpty)
        #expect(!store.translation.analyzing)
    }

    @Test func localPreflightFailureRecordsNoRequestAndCorruptReadIsVisible() async throws {
        let (store, lesson, transcript) = try fixture(), mock = AnalysisMock(.notSent)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        try store.analysis.launch(store: store, lessonID: lesson.id, proposed: proposal(transcript), provider: mock)
        await store.analysis.worker?.value
        let repo = AnalysisRepository(root: store.repository!.root)
        let saved = try #require(try await repo.load(lessonID: lesson.id, sourceVersion: transcript.version))
        #expect(saved.attempts.isEmpty && saved.task?.status == .failed)
        #expect(await mock.chunks.isEmpty)
        let file = AnalysisRepository.fileURL(root: store.repository!.root, lessonID: lesson.id, sourceVersion: transcript.version)
        try Data("invalid json".utf8).write(to: file, options: .atomic)
        await store.analysis.load(store: store, lessonID: lesson.id)
        #expect(store.analysis.loadErrors[lesson.id] != nil)
        #expect(!store.translation.analyzing)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP08_DATA"] != nil))
    func actualCourseADualChapterTargetsRemainPausedAndRestore() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LP08_DATA"])
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try #require((root == URL(fileURLWithPath: "/private/tmp/LP08-latest-data").resolvingSymlinksInPath() || root == URL(fileURLWithPath: "/private/tmp/LP081/data").resolvingSymlinksInPath() || root == URL(fileURLWithPath: "/private/tmp/LP082/data").resolvingSymlinksInPath() || root == URL(fileURLWithPath: "/private/tmp/LP083/data").resolvingSymlinksInPath() || root == URL(fileURLWithPath: "/private/tmp/LP084/data").resolvingSymlinksInPath()), "Only the isolated LP08 copy is permitted")
        let repository = try Repository(root: root), library = try repository.load()
        var lesson = try #require(library.lectures.first { $0.title.contains("SAMPLE1001") }, "CourseA fixture must be present")
        let transcript = try #require(try repository.read(lesson))
        let cues = AnalysisPlan.ordered(transcript.cues)
        try #require(cues.count >= 3, "Real timed source subtitles are required")
        try #require(lesson.mediaSources.count == 2, "Both real CourseA video perspectives are required")
        // Use verified existing file paths, never stale security bookmarks or relocation.
        var sources = lesson.mediaSources
        for index in sources.indices {
            try ImportPlanner.requireLocal(URL(fileURLWithPath: sources[index].path))
            sources[index].bookmark = nil
        }
        lesson.mediaSources = sources
        let originalState = lesson.state, originalMarks = lesson.marks
        let mapper = SubtitleTimingMapper(offset: 14)
        lesson.state.offset = 14
        let suite = "LP08-real-paused-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.set(0, forKey: "playbackVolume")
        let playback = Playback(preferences: preferences)
        playback.player.isMuted = true; playback.secondaryPlayer.isMuted = true
        defer { playback.close(); preferences.removePersistentDomain(forName: suite) }
        var savedPosition: Double?
        playback.save = { id, seconds, _ in if id == lesson.id { savedPosition = seconds } }
        func awaitReady() async throws {
            for _ in 0..<500 {
                if playback.ready { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            try #require(playback.ready, "Real media preparation failed: \(playback.error ?? "timeout")")
            try #require(playback.missing.isEmpty, "A required real perspective is unavailable")
        }
        func assertPausedPosition(_ target: Double) async throws {
            for source in sources {
                let item = try #require(playback.player(for: source).currentItem)
                let expected = target + source.relativeOffset
                try #require(expected >= 0 && expected < item.duration.seconds, "Requested cue target lies outside an actual perspective")
            }
            for _ in 0..<250 {
                let arrived = sources.allSatisfy { abs(playback.player(for: $0).currentTime().seconds - $0.relativeOffset - target) <= 0.15 }
                if arrived { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            for source in sources {
                let player = playback.player(for: source)
                let error = abs(player.currentTime().seconds - source.relativeOffset - target)
                #expect(error <= 0.15)
                #expect(player.rate == 0 && player.isMuted)
                print("LP08_REAL_PAUSED_TARGET role=\(source.role.rawValue) target=\(target) error=\(error) rate=\(player.rate)")
            }
            #expect(!playback.playing)
            #expect(playback.player.volume == 0 && playback.secondaryPlayer.volume == 0)
        }
        playback.load(lesson); try await awaitReady()
        for cue in [cues[0], cues[cues.count / 2], cues[cues.count - 1]] {
            let target = mapper.seekTarget(cue)
            playback.seek(target); try await assertPausedPosition(target)
        }
        let finalTarget = mapper.seekTarget(cues[cues.count - 1])
        playback.persist(); playback.close()
        let restored = try #require(savedPosition)
        #expect(abs(restored - finalTarget) <= 0.15)
        lesson.state.record(restored, ready: true)
        playback.load(lesson); try await awaitReady(); try await assertPausedPosition(finalTarget)
        #expect(playback.targetSpeed == originalState.speed)
        #expect(lesson.state.subtitleOffsetSeconds == 14)
        // Playback saved only to this in-memory closure; the isolated records also remain identical.
        let unchanged = try repository.load()
        let original = try #require(unchanged.lectures.first { $0.id == lesson.id })
        #expect(original.state == originalState && original.marks == originalMarks)
        #expect(try repository.read(original) == transcript)
        print("LP08_REAL_CourseA_CHAPTER_SEEKS passed first/middle/last +14s, two muted paused perspectives, close/reload; no API and no media playback")
    }

}
