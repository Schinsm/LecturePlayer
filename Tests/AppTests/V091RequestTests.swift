import Foundation
import Testing
import Core
@testable import LecturePlayer

/// Mock OpenAI translator with a fixed latency; can answer the first call with a 429.
private actor LatencyMock: TranslationProvider {
    var calls = 0, active = 0, peak = 0
    let delay: UInt64
    var rateLimitFirst: Bool
    let quotaExhausted: Bool
    init(delay: UInt64, rateLimitFirst: Bool = false, quotaExhausted: Bool = false) {
        self.delay = delay; self.rateLimitFirst = rateLimitFirst; self.quotaExhausted = quotaExhausted
    }
    func translate(_ batch: TranslationBatch, config: TranslationConfig) async throws -> TranslationResult {
        calls += 1; active += 1; peak = max(peak, active); defer { active -= 1 }
        try await Task.sleep(nanoseconds: delay)
        if rateLimitFirst || quotaExhausted {
            rateLimitFirst = false
            throw APIError(status: 429, result: TranslationResult(items: [], problem: "mock 429"), retryAfter: 0.5, retryable: !quotaExhausted)
        }
        return TranslationResult(items: batch.targets.map { TranslatedItem(id: $0.id, zh: "中文 " + $0.id) }, inputTokens: 30, outputTokens: 20)
    }
}

/// 0.9.1: requests no longer wait for the previous save, run up to the configured concurrency after a
/// one-request slow start, and resend only rate limits, 5xx and failed connections.
@Suite(.serialized) @MainActor struct V091RequestTests {
    private func lesson(cues: Int) throws -> (AppStore, Lecture, Transcript) {
        let (root, fixture, _) = try PersistenceTests().fixture()
        var vtt = "WEBVTT\n\n"
        for i in 0..<cues { vtt += "c\(i)\n00:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60)).000 --> 00:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60)).900\nSentence number \(i).\n\n" }
        let transcript = try SubtitleParser.parse(Data(vtt.utf8), format: "vtt")
        var library = fixture; library.lectures[0].transcriptVersion = transcript.version
        do { let repository = try Repository(root: root); try repository.write(transcript, for: library.lectures[0].id); try repository.save(library) }
        let store = AppStore(root: root), lesson = store.library.lectures[0]
        try store.translation.saveTask(TranslationTaskState(transcript: transcript, ids: transcript.cues.map(\.id), config: TranslationConfig(model: "gpt-4o-mini")), lesson: lesson, store: store)
        return (store, lesson, transcript)
    }
    private func translate(concurrency: Int, mock: LatencyMock, cues: Int = 200) async throws -> (Double, AppStore, Lecture, Transcript) {
        let (store, lesson, transcript) = try lesson(cues: cues)
        store.translation.concurrencyOverride = concurrency
        let started = Date()
        await store.translation.executeQueue(store: store, ids: [lesson.id], provider: mock)
        return (Date().timeIntervalSince(started), store, lesson, transcript)
    }

    @Test func fourRequestsAtOnceTranslateTheSameTextAtLeastTwiceAsFast() async throws {
        let serialMock = LatencyMock(delay: 150_000_000), parallelMock = LatencyMock(delay: 150_000_000)
        let (serial, serialStore, serialLesson, transcript) = try await translate(concurrency: 1, mock: serialMock)
        let (parallel, store, lesson, _) = try await translate(concurrency: 4, mock: parallelMock)
        defer { try? FileManager.default.removeItem(at: serialStore.repository!.root); try? FileManager.default.removeItem(at: store.repository!.root) }
        print("V091 BENCH 200 cues, 20 requests × 150 ms: serial \(String(format: "%.2f", serial)) s, 4 at once \(String(format: "%.2f", parallel)) s, peak \(await parallelMock.peak)")
        #expect(await serialMock.peak == 1)
        #expect(await parallelMock.peak == 4)
        #expect(parallel * 2 < serial, "parallel \(parallel) s vs serial \(serial) s")
        // Same translations, cue for cue, whatever order the answers arrived in.
        let a = try #require(try serialStore.repository?.read(serialLesson)), b = try #require(try store.repository?.read(lesson))
        #expect(a.translatedCount == transcript.cues.count && b.translatedCount == transcript.cues.count)
        #expect(transcript.cues.allSatisfy { a.translations[$0.id]?.ai == b.translations[$0.id]?.ai })
        #expect(b.task?.state == "完成")
    }

    @Test func rateLimitIsWaitedOutAndResentWithoutPausing() async throws {
        let mock = LatencyMock(delay: 20_000_000, rateLimitFirst: true)
        let (_, store, lesson, transcript) = try await translate(concurrency: 4, mock: mock, cues: 40)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let saved = try #require(try store.repository?.read(lesson))
        #expect(saved.translatedCount == transcript.cues.count)
        #expect(saved.task?.state == "完成")
        #expect(await mock.calls == 5, "4 batches plus one resend")
    }

    @Test func exhaustedQuotaIsNotResentAndPauses() async throws {
        let mock = LatencyMock(delay: 20_000_000, quotaExhausted: true)
        let (_, store, lesson, _) = try await translate(concurrency: 4, mock: mock, cues: 40)
        defer { try? FileManager.default.removeItem(at: store.repository!.root) }
        let saved = try #require(try store.repository?.read(lesson))
        #expect(await mock.calls == 1, "slow start: the first refusal stops the lesson")
        #expect(saved.translatedCount == 0 && saved.task?.state == "已暂停")
    }
}
