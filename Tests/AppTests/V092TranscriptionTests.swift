import Foundation
import Testing
import Core
@testable import LecturePlayer

private struct MockEngine: TranscriptionEngine {
    var segments: [TimedText] = [TimedText(start: 0.5, end: 2.0, text: "Hello everybody."), TimedText(start: 2.2, end: 4.0, text: "Today we talk about valuation.")]
    var fail = false
    func transcribe(_ media: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        progress(0.5); try await Task.sleep(nanoseconds: 20_000_000); progress(1)
        if fail { throw Failure("mock failure") }
        return segments
    }
}

/// 0.9.2: lessons without subtitles can be transcribed on this Mac; the result is saved beside the course's
/// exports, never over the source files, and becomes the lesson's English subtitles.
@Suite(.serialized) @MainActor struct V092TranscriptionTests {
    /// A lesson without subtitles whose video sits in its own temporary course folder.
    private func bareLesson() throws -> (AppStore, Lecture, URL) {
        let (root, fixture, _) = try PersistenceTests().fixture()
        let course = root.appendingPathComponent("Course/Week3", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let video = course.appendingPathComponent("Tutorial 3.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture.lectures[0].path), to: video)
        var library = fixture
        library.lectures[0].path = video.path; library.lectures[0].transcriptVersion = nil; library.lectures[0].title = "Tutorial 3"
        try Repository(root: root).save(library)
        let store = AppStore(root: root)
        return (store, store.library.lectures[0], course)
    }
    private func finish(_ job: TranscriptionJob) async throws {
        for _ in 0..<200 { if job.current == nil && !job.isQueuedAny { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func transcriptionBecomesTheLessonsSubtitlesWithoutTouchingSourceFiles() async throws {
        let (store, lesson, course) = try bareLesson()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let before = try FileManager.default.contentsOfDirectory(atPath: course.path).sorted()
        store.transcription.engine = MockEngine()
        store.transcription.enqueue([lesson.id], store: store)
        try await finish(store.transcription)
        let updated = try #require(store.library.lectures.first { $0.id == lesson.id })
        #expect(updated.transcriptVersion != nil && updated.transcriptSource == .appleSpeech)
        let saved = try #require(try store.repository?.read(updated))
        #expect(saved.cues.map(\.en) == ["Hello everybody.", "Today we talk about valuation."])
        // Only the LecturePlayer export folder was added; the video is untouched and the scan ignores the new file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: course.path).sorted() == (before + ["LecturePlayer"]).sorted())
        let file = URL(fileURLWithPath: try #require(updated.subtitlePath))
        #expect(file.lastPathComponent == "transcript.en.vtt" && ImportPlanner.isGenerated(file))
    }

    @Test func existingSubtitlesAreNeverReplacedAndFailuresAreReported() async throws {
        let (store, lesson, _) = try bareLesson()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        store.transcription.engine = MockEngine(fail: true)
        store.transcription.enqueue([lesson.id], store: store)
        try await finish(store.transcription)
        #expect(store.transcription.failures[lesson.id] == "mock failure")
        #expect(store.library.lectures[0].transcriptVersion == nil)
        try store.attachTranscription(lesson.id, vtt: TranscriptionOutput.vtt([TimedText(start: 0, end: 1, text: "First.")]), source: .appleSpeech)
        #expect(throws: (any Error).self) { try store.attachTranscription(lesson.id, vtt: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nSecond.\n", source: .appleSpeech) }
    }

    @Test func aSubtitleExportedNextToTheVideoIsAdopted() async throws {
        let (store, lesson, course) = try bareLesson()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        try Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nFrom MacWhisper.\n".utf8).write(to: course.appendingPathComponent("Tutorial 3.vtt"))
        store.adoptNewSubtitles()
        let updated = try #require(store.library.lectures.first { $0.id == lesson.id })
        #expect(updated.transcriptVersion != nil)
        #expect(try store.repository?.read(updated)?.cues.first?.en == "From MacWhisper.")
    }

    @Test func transcribedLessonsJoinTheProcessingQueueWhenAsked() async throws {
        let (store, lesson, _) = try bareLesson()
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        store.processing.pause(store)  // keep the queue from sending anything
        store.transcription.engine = MockEngine()
        store.transcription.enqueue([lesson.id], store: store, thenProcess: true)
        try await finish(store.transcription)
        #expect(store.processing.entries.contains { $0.id == lesson.id && ($0.translation != nil || $0.analysis != nil) })
    }

    @Test func importRowsWithoutSubtitlesPlanATranscriptionFirst() {
        let plan = ImportStepPlan.make(existing: false, hasSubtitle: false, translation: .ready, chapters: .ready, transcription: .ready)
        #expect(plan.steps == [.transcribe, .translate, .chapters])
        #expect(plan.label == "本机转写 → 翻译 → 生成章节（费用按转写后的字数计）")
        let older = ImportStepPlan.make(existing: false, hasSubtitle: false, translation: .ready, chapters: .ready, transcription: .unavailable("需要 macOS 26"))
        #expect(older.steps.isEmpty && older.label.hasPrefix("没有字幕"))
    }

    @Test func vttOutputSkipsEmptyAndBackwardSegments() {
        let vtt = TranscriptionOutput.vtt([TimedText(start: 1, end: 2.5, text: " Hi. "), TimedText(start: 3, end: 3, text: "x"), TimedText(start: 4, end: 5, text: "  ")])
        #expect(vtt == "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHi.\n\n")
    }
}

extension TranscriptionJob {
    var isQueuedAny: Bool { !queue.isEmpty }
}

/// Real on-device engine on a real clip; opt in with LP_STT_MEDIA=<path to a short lecture video>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LP_STT_MEDIA"] != nil))
func appleSpeechEngineTranscribesARealClip() async throws {
    guard let engine = TranscriptionSupport.engine else { Issue.record("needs macOS 26"); return }
    let media = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LP_STT_MEDIA"]!)
    let started = Date()
    let progress = ProgressBox()
    let segments = try await engine.transcribe(media, locale: Locale(identifier: "en-AU")) { value in Task { await progress.set(value) } }
    let words = segments.map(\.text).joined(separator: " ").split(separator: " ").count
    print("V092 STT segments \(segments.count), words \(words), \(String(format: "%.1f", Date().timeIntervalSince(started))) s, last progress \(await progress.value)")
    #expect(segments.count > 20 && words > 300)
    #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
}
private actor ProgressBox { var value = 0.0; func set(_ v: Double) { value = v } }

/// 0.9.2: the 1 s debounced sidecar flush used to cancel its own task, so the write failed with CancellationError.
@MainActor @Test func debouncedSidecarFlushWritesFiles() async throws {
    let (store, lesson, url, _) = try V0872Tests().fixture()
    await store.translation.writer.enqueueFiles(lesson, url: url)
    try await Task.sleep(for: .milliseconds(1600))
    let saved = try Codec.decode(Transcript.self, Data(contentsOf: url))
    let status = saved.variants?["openAI"]?.fileStatus ?? ""
    #expect(status.hasPrefix("文件已保存"), "got \(status)")
}
