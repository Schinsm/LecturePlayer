import Foundation
import SwiftData
import Core

@Model final class MetadataRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(key: String, payload: Data) { self.key = key; self.payload = payload }
}
@MainActor final class Repository {
    let root: URL; let container: ModelContainer; var context: ModelContext
    let commits:MetadataCommitQueue
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: root.appendingPathComponent("Library.store"))
        container = try ModelContainer(for: MetadataRecord.self, configurations: configuration)
        context = ModelContext(container); context.autosaveEnabled = false
        commits=MetadataCommitQueue(container:container)
    }
    func load() throws -> Library {
        try commits.flush(); context=ModelContext(container);context.autosaveEnabled=false
        let rows = try context.fetch(FetchDescriptor<MetadataRecord>())
        try recoverVariantMigration(schema: rows.first(where:{$0.key=="schema"}).flatMap{try? Codec.decode(Int.self,$0.payload)} ?? 4)
        guard !rows.isEmpty else { return Library() }
        var library = Library(); library.schema = 1
        for row in rows {
            if row.key == "schema" { library.schema = try Codec.decode(Int.self, row.payload) }
            else if row.key == "directoryRoot" { library.directoryRoot = try Codec.decode(String?.self, row.payload) }
            else if row.key == "directoryBookmark" { library.directoryBookmark = try Codec.decode(Data?.self, row.payload) }
            else if row.key == "last" { library.lastLecture = try Codec.decode(UUID?.self, row.payload) }
            else if row.key.hasPrefix("c-") { library.courses.append(try Codec.decode(Course.self, row.payload)) }
            else if row.key.hasPrefix("f-") { library.folders.append(try Codec.decode(Folder.self, row.payload)) }
            else if row.key.hasPrefix("l-") { library.lectures.append(try Codec.decode(Lecture.self, row.payload)) }
        }
        if library.schema < 4 {return try migrateLibrary(library)}
        try library.validate()
        return library
    }
    func writeRecoverySnapshot(_ library: Library, to url: URL? = nil) throws {
        try commits.flush()
        var safe = library; safe.directoryBookmark = nil
        for i in safe.lectures.indices {
            safe.lectures[i].bookmark = nil; safe.lectures[i].subtitleBookmark = nil
            if safe.lectures[i].sources != nil { for j in safe.lectures[i].sources!.indices { safe.lectures[i].sources![j].bookmark = nil } }
        }
        var transcripts: [String: Transcript] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("transcripts"), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            transcripts[file.deletingPathExtension().lastPathComponent] = try Codec.decode(Transcript.self, Data(contentsOf: file))
        }
        let analyses = try Backup.analysisPayload(AnalysisRepository.readAll(root: root))
        let backup = Backup(library: safe, transcripts: transcripts, analyses: analyses, processing: try ImportProcessingEntry.read(root:root)); try backup.validate()
        let target = url ?? root.appendingPathComponent("before-relink-\(UUID()).json")
        let temporary = root.appendingPathComponent(".snapshot-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Codec.encode(backup).write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: target)
    }
    func save(_ library: Library) throws {
        try commits.flush(); context=ModelContext(container);context.autosaveEnabled=false
        try library.validate()
        var expected: [String: Data] = ["schema": try Codec.encode(library.schema), "last": try Codec.encode(library.lastLecture)]
        expected["directoryRoot"] = try Codec.encode(library.directoryRoot); expected["directoryBookmark"] = try Codec.encode(library.directoryBookmark)
        for c in library.courses { expected["c-\(c.id)"] = try Codec.encode(c) }
        for f in library.folders { expected["f-\(f.id)"] = try Codec.encode(f) }
        for l in library.lectures { expected["l-\(l.id)"] = try Codec.encode(l) }
        let rows = try context.fetch(FetchDescriptor<MetadataRecord>())
        for row in rows { if let data = expected.removeValue(forKey: row.key) { if row.payload != data { row.payload = data } } else { context.delete(row) } }
        for (key, payload) in expected { context.insert(MetadataRecord(key: key, payload: payload)) }
        do { try context.save() } catch { context.rollback(); throw error }
    }
    func transcriptURL(_ lectureID: UUID, _ version: String) throws -> URL {
        guard version.count == 64, version.allSatisfy({ $0.isHexDigit }) else { throw Failure("无效字幕文件标识") }
        return root.appendingPathComponent("transcripts/\(lectureID)-\(version).json")
    }
    func read(_ lecture: Lecture, variantID:String? = nil) throws -> Transcript? {
        TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}
        guard let version = lecture.transcriptVersion else { return nil }
        let t = try Codec.decode(Transcript.self, Data(contentsOf: transcriptURL(lecture.id, version))); try t.validate(); return t.viewing(variantID ?? lecture.selectedTranslationVariantID)
    }
    func write(_ transcript: Transcript, for lectureID: UUID) throws { TranscriptTransactions.lock.lock();defer{TranscriptTransactions.lock.unlock()}; try transcript.validate(); try Codec.encode(transcript).write(to: transcriptURL(lectureID, transcript.version), options: .atomic) }
}
