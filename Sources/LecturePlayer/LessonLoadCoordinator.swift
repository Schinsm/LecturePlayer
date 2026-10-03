import Foundation
import Core

struct PreparedReading: Sendable {
    let revision: UUID
    let timeline: TranscriptTimeline
    let sentences: ReadingIndex
    let fragments: ReadingIndex
    let videoSentences: ReadingIndex
    init(_ cues: [Cue]) {
        revision = UUID(); timeline = TranscriptTimeline(cues)
        sentences = ReadingIndex(cues); fragments = ReadingIndex(cues, grouped: false)
        videoSentences = ReadingIndex(cues, video: true)
    }
    func index(grouped: Bool, video: Bool = false) -> ReadingIndex {
        grouped ? (video ? videoSentences : sentences) : fragments
    }
}
struct LoadedLesson: Sendable { var transcript: Transcript?; var reading: PreparedReading }

/// Immutable values only. Reads need no writer lock: every writer atomically replaces
/// its JSON, so a reader sees one complete revision. File identity invalidates the LRU.
actor LessonLoadCoordinator {
    struct Entry { let key: String; let value: LoadedLesson }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private(set) var cacheHits = 0
    var readData: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    func clear() { entries.removeAll(); order.removeAll() }
    func setReader(_ reader: @escaping @Sendable (URL) throws -> Data) { readData = reader; clear() }
    private func signature(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(a[.systemFileNumber] ?? ""):\(a[.size] ?? ""):\((a[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0)"
    }
    func load(_ lesson: Lecture, root: URL) throws -> LoadedLesson {
        try Task.checkCancellation()
        guard let version = lesson.transcriptVersion else { return LoadedLesson(transcript: nil, reading: PreparedReading([])) }
        guard version.count == 64, version.allSatisfy({ $0.isHexDigit }) else { throw Failure("无效字幕版本") }
        let url = root.appendingPathComponent("transcripts/\(lesson.id)-\(version).json")
        let key = try signature(url)
        if let old = entries[lesson.id], old.key == key {
            cacheHits += 1; touch(lesson.id)
            var result = old.value; result.transcript = result.transcript?.viewing(lesson.selectedTranslationVariantID)
            PerformanceTrace.record("lesson.cacheHit", 1); return result
        }
        let value: LoadedLesson = try PerformanceTrace.measure("lesson.readValidateIndex") {
            let data = try readData(url); try Task.checkCancellation()
            let t = try Codec.decode(Transcript.self, data); try t.validate()
            guard t.version == version else { throw Failure("字幕版本不一致，未载入旧内容") }
            let reading = PerformanceTrace.measure("lesson.readingIndex") { PreparedReading(t.cues) }
            try Task.checkCancellation()
            return LoadedLesson(transcript: t, reading: reading)
        }
        // Do not cache a revision that changed while decoding. Its UI is still a
        // complete, valid snapshot; the next open must read the newer file.
        if (try? signature(url)) == key { entries[lesson.id] = Entry(key: key, value: value); touch(lesson.id) }
        var result = value; result.transcript = result.transcript?.viewing(lesson.selectedTranslationVariantID); return result
    }
    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }; order.append(id)
        while order.count > 3 { entries.removeValue(forKey: order.removeFirst()) }
    }
}
