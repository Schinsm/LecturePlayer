import Foundation
import SwiftData
import Core

extension Repository {
    private var migrationJournal:URL {root.appendingPathComponent("migration-v07.pending")}
    /// The metadata transaction is the commit point. An interrupted file swap can
    /// be recovered on startup without touching media or credentials.
    func recoverVariantMigration(schema:Int) throws {
        let fm=FileManager.default,journal=migrationJournal,old=journal.appendingPathComponent("original")
        guard fm.fileExists(atPath:journal.path) else{return}
        if schema<4 && fm.fileExists(atPath:old.path) {
            let live=root.appendingPathComponent("transcripts")
            if fm.fileExists(atPath:live.path){try fm.removeItem(at:live)}
            try fm.moveItem(at:old,to:live)
        }
        try fm.removeItem(at:journal)
    }
    func migrateLibrary(_ old:Library) throws -> Library {
        var next=try LibraryMigration.upgrade(old)
        let fm=FileManager.default,live=root.appendingPathComponent("transcripts"),journal=migrationJournal
        var values:[String:Transcript]=[:]
        for url in try fm.contentsOfDirectory(at:live,includingPropertiesForKeys:nil) where url.pathExtension=="json" {
            var t=try Codec.decode(Transcript.self,Data(contentsOf:url));try t.migrateVariants();values[url.lastPathComponent]=t
        }
        for i in next.lectures.indices {
            let l=next.lectures[i]
            if let v=l.transcriptVersion,let t=values["\(l.id)-\(v).json"] {next.lectures[i].selectedTranslationVariantID=t.activeVariantID}
        }
        // Snapshot must succeed before the first mutation.
        try writeRecoverySnapshot(old,to:root.appendingPathComponent("before-v07-\(UUID()).json"))
        try fm.createDirectory(at:journal,withIntermediateDirectories:false)
        let stage=journal.appendingPathComponent("new"),original=journal.appendingPathComponent("original")
        do {
            try fm.copyItem(at:live,to:stage)
            for (name,t) in values {try Codec.encode(t).write(to:stage.appendingPathComponent(name),options:.atomic)}
            try fm.moveItem(at:live,to:original);try fm.moveItem(at:stage,to:live)
            try save(next)
        } catch {
            try recoverVariantMigration(schema:old.schema)
            throw error
        }
        // Committed migrations may finish housekeeping on the next launch.
        try? fm.removeItem(at:journal)
        return next
    }
}

extension Repository {
    /// The 4→5 migration changes metadata only. Preserve raw payloads as well, so a damaged
    /// analysis cannot prevent unrelated lessons from opening or be silently omitted from recovery.
    func snapshotBeforeSchema5(_ library:Library) throws {
        let fm=FileManager.default
        let stage=root.appendingPathComponent(".before-v089-\(UUID())")
        let target=root.appendingPathComponent("before-v089-\(UUID())")
        try fm.createDirectory(at:stage,withIntermediateDirectories:false)
        defer {try? fm.removeItem(at:stage)}
        var safe=library;safe.directoryBookmark=nil
        for i in safe.lectures.indices {
            safe.lectures[i].bookmark=nil;safe.lectures[i].subtitleBookmark=nil
            if safe.lectures[i].sources != nil {for j in safe.lectures[i].sources!.indices {safe.lectures[i].sources![j].bookmark=nil}}
        }
        try Codec.encode(safe).write(to:stage.appendingPathComponent("library.json"),options:.atomic)
        for name in ["transcripts","analyses","processing-queue.json","service-tests.json","generated-writes"] {
            let source=root.appendingPathComponent(name)
            if fm.fileExists(atPath:source.path) {try fm.copyItem(at:source,to:stage.appendingPathComponent(name))}
        }
        try Data("Lecture Player schema 4 recovery snapshot. Contains no service credentials. Raw payloads are preserved, including damaged files. Restore only into an isolated library for inspection.\n".utf8).write(to:stage.appendingPathComponent("README.txt"))
        try fm.moveItem(at:stage,to:target)
    }
}
