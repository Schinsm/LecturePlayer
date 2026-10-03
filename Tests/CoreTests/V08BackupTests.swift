import Foundation
import Testing
@testable import Core

@Suite struct V08BackupTests {
    func fixture() throws -> (Backup, LessonAnalysis, Transcript) {
        let course = Course(name: "Backup QA")
        var library = Library(); library.courses = [course]
        var lesson = Lecture(title: "Lecture", courseID: course.id, folderID: nil, url: URL(fileURLWithPath: "/unchanged/source.mp4"), bookmark: nil, identity: "source")
        let transcript = try SubtitleParser.parse(Data("WEBVTT\n\n1\n00:00:00.000 --> 00:00:03.000\nCash flow matters.\n\n2\n00:00:04.000 --> 00:00:08.000\nCompare earnings with cash.\n".utf8), format: "vtt")
        lesson.transcriptVersion = transcript.version; lesson.state.position = 321; lesson.state.speed = 1.5; lesson.state.offset = 14; lesson.marks = [Mark(seconds: 42, note: "Keep")]
        library.lectures = [lesson]
        var analysis = LessonAnalysis(lessonID: lesson.id, sourceVersion: transcript.version)
        analysis.completed = AnalysisDocument(chapters: [AnalysisChapter(id: "chapter-1", startCueID: transcript.cues[0].id, endCueID: transcript.cues[1].id, title: "现金流 Cash flow", points: ["现金流的重要性", "比较现金流与利润"])], overview: [AnalysisOverviewPoint(text: "现金流与利润需要对照分析", chapterID: "chapter-1")])
        analysis.completedConfig = AnalysisConfig(model: "gpt-4o-mini"); analysis.completedAt = Date(timeIntervalSince1970: 100)
        return (Backup(library: library, transcripts: ["\(lesson.id)-\(transcript.version)": transcript], analyses: try Backup.analysisPayload([analysis])), analysis, transcript)
    }

    @Test func analysisAndHistoricalVersionRoundTripPreserveLearningRecords() throws {
        var (backup, current, transcript) = try fixture()
        let historical = try SubtitleParser.parse(Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHistorical source.\n".utf8), format: "vtt")
        let task = LessonAnalysis(lessonID: current.lessonID, sourceVersion: historical.version)
        backup.transcripts["\(task.lessonID)-\(historical.version)"] = historical
        backup.analyses = try Backup.analysisPayload([current, task])
        let bytes = try Codec.encode(backup); let restored = try Codec.decode(Backup.self, bytes)
        try restored.validate()
        #expect(restored.schema == 4)
        #expect(restored.analyses == backup.analyses)
        #expect(restored.transcripts == backup.transcripts)
        #expect(restored.library.lectures.first?.state == backup.library.lectures.first?.state)
        #expect(restored.library.lectures.first?.marks == backup.library.lectures.first?.marks)
        let markdown = try AnalysisMarkdown.export(current, transcript: transcript, offset: 14, title: "Lecture")
        #expect(markdown.contains("00:00:14–00:00:22")); #expect(markdown.contains("Cash flow"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("apiKey"))
    }

    @Test(arguments: [1, 2, 3]) func oldBackupsDecodeWithoutAnalyses(schema: Int) throws {
        var (backup, _, _) = try fixture(); backup.schema = schema; backup.analyses = nil; backup.library.schema = 4
        var object = try #require(JSONSerialization.jsonObject(with: Codec.encode(backup)) as? [String: Any])
        object.removeValue(forKey: "analyses")
        let decoded = try Codec.decode(Backup.self, JSONSerialization.data(withJSONObject: object))
        try decoded.validate(); #expect(decoded.analyses == nil)
    }

    @Test func rejectsForeignLessonMissingVersionAndInvalidCueLinks() throws {
        let (backup, valid, _) = try fixture()
        var bad = backup
        var record = valid; record.lessonID = UUID(); bad.analyses = try Backup.analysisPayload([record])
        #expect(throws: (any Error).self) { try bad.validate() }
        record = valid; record.sourceVersion = digest("unknown source"); bad.analyses = try Backup.analysisPayload([record])
        #expect(throws: (any Error).self) { try bad.validate() }
        record = valid; record.completed!.chapters[0].endCueID = "not-in-source"; bad.analyses = try Backup.analysisPayload([record])
        #expect(throws: (any Error).self) { try bad.validate() }
        bad = backup; bad.analyses = ["../unsafe": valid]
        #expect(throws: (any Error).self) { try bad.validate() }
        bad = backup; bad.schema = 6
        #expect(throws: (any Error).self) { try bad.validate() }
    }

    @Test func failedMetadataCommitRestoresOriginalPayloadsAndRemovesNewFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v08-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (backup, _, _) = try fixture()
        for name in ["transcripts", "analyses"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let transcriptBytes = Data("old transcript bytes".utf8), analysisBytes = Data("old summary bytes".utf8), mediaBytes = Data("source media unchanged".utf8)
        try transcriptBytes.write(to: root.appendingPathComponent("transcripts/old.json"))
        try analysisBytes.write(to: root.appendingPathComponent("analyses/old.json"))
        try mediaBytes.write(to: root.appendingPathComponent("source.mp4"))
        #expect(throws: (any Error).self) {
            try BackupPayloadTransaction.restore(backup, root: root) { throw Failure("Injected metadata save failure") }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("transcripts/old.json")) == transcriptBytes)
        #expect(try Data(contentsOf: root.appendingPathComponent("analyses/old.json")) == analysisBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transcripts").path) == ["old.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("analyses").path) == ["old.json"])
        #expect(try Data(contentsOf: root.appendingPathComponent("source.mp4")) == mediaBytes)
    }

    @Test func oldBackupRestoreCannotReuseLeftoverSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v08-oldrestore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var (backup, _, _) = try fixture(); backup.schema = 3; backup.analyses = nil; backup.library.schema = 4
        try FileManager.default.createDirectory(at: root.appendingPathComponent("analyses"), withIntermediateDirectories: true)
        try Data("stale summary".utf8).write(to: root.appendingPathComponent("analyses/stale.json"))
        var committed = false
        try BackupPayloadTransaction.restore(backup, root: root) { committed = true }
        #expect(committed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("analyses").path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transcripts").path).count == 1)
    }

    @Test func restoreWithNoOriginalDirectoriesRollsBackNewPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v08-newrestore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (backup, _, _) = try fixture()
        #expect(throws: (any Error).self) { try BackupPayloadTransaction.restore(backup, root: root) { throw Failure("Stop") } }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("analyses").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcripts").path))
    }
}
