import Foundation
import Testing
@testable import Core

@Suite struct V04CoreTests {
    @Test func tagsNamesAndNumericWeeks() throws {
        var lesson = Lecture(title: "original.mp4", courseID: UUID(), folderID: nil, url: URL(fileURLWithPath: "/tmp/a.mp4"), bookmark: nil, identity: "a")
        lesson.week = 7; lesson.sessionType = "Lecture"; lesson.topic = "Ratios"; lesson.customTitle = false
        #expect(lesson.displayTitle == "Week 07 · Lecture · Ratios")
        #expect(lesson.matches(week: 7, type: "Lecture")); #expect(!lesson.matches(week: 1, type: nil))
        lesson.customTitle = true; #expect(lesson.displayTitle == "original.mp4")
        lesson.customTitle = false; lesson.week = nil; lesson.sessionType = "Custom"; #expect(lesson.displayTitle == "Custom · Ratios")
        #expect([11,2,7].sorted() == [2,7,11])
    }
    @Test func legacyMigrationPreservesEverythingAndRejectsFuture() throws {
        let course = Course(name: "Legacy"); var old = Library(); old.schema = 1; old.courses = [course]
        var lesson = Lecture(title: "Legacy", courseID: course.id, folderID: nil, url: URL(fileURLWithPath: "/tmp/old.mp4"), bookmark: nil, identity: "legacy")
        lesson.state.position = 3456; lesson.state.speed = 1.5; lesson.state.offset = 14; lesson.marks = [Mark(seconds: 55, note: "Keep")]; old.lectures = [lesson]
        let migrated = try LibraryMigration.upgrade(old)
        #expect(migrated.schema == 4); #expect(migrated.lectures[0].id == lesson.id); #expect(migrated.lectures[0].state == lesson.state); #expect(migrated.lectures[0].marks == lesson.marks)
        #expect(migrated.lectures[0].mediaSources[0].managed == false); #expect(migrated.lectures[0].path == lesson.path)
        var backup = Backup(library: old, transcripts: [:]); backup.schema = 1; try backup.validate()
        let decoded = try Codec.decode(Backup.self, Codec.encode(backup)); #expect(try LibraryMigration.upgrade(decoded.library) == migrated)
        old.schema = 999; #expect(throws: (any Error).self) { try LibraryMigration.upgrade(old) }
    }
    @Test func verifiedCopyAndFailurePreserveOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), destination = root.appendingPathComponent("managed/file")
        let data = Data(repeating: 127, count: 9_000_000); try data.write(to: original)
        try MediaCopy.copy(from: original, to: destination)
        #expect(try Data(contentsOf: destination) == data); #expect(try Data(contentsOf: original) == data)
        #expect(throws: (any Error).self) { try MediaCopy.copy(from: original, to: destination) }
        let absent = root.appendingPathComponent("absent"); #expect(throws: (any Error).self) { try MediaCopy.copy(from: absent, to: root.appendingPathComponent("failed")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("failed").path))
    }
    @Test func cancelledCopyLeavesNoDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 1, count: 8_000_000).write(to: source)
        let task = Task.detached { try MediaCopy.copy(from: source, to: target) { value in if value > 0.1 { withUnsafeCurrentTask { $0?.cancel() } } } }
         do { try await task.value; Issue.record("Cancellation ignored") } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
