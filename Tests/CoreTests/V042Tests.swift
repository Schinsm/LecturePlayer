import Foundation
import Testing
@testable import Core

struct V042CoreTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-042-\(UUID())")
        for subject in ["CourseC","CourseA","IM","CourseB"] { for week in ["Week1","Week2","Week8","Week10"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(subject + "/" + week), withIntermediateDirectories: true) } }
        return DirectoryIndex.canonical(root)
    }
    @Test func emptyTreeIndependentOfLessonsAndRepeatedScan() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scanner = DirectoryScanner(); let result = try await scanner.scan(root, settle: .milliseconds(5))
        var library = Library()
        for _ in 0..<2 { DirectoryIndex.buildTree(result.directories,root: root,library: &library) }
        #expect(library.courses.count == 4 && library.folders.count == 16 && library.lectures.isEmpty)
        #expect(result.issues.isEmpty)
        #expect(library.folders.filter { $0.courseID == library.courses[0].id }.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending } == ["Week1","Week2","Week8","Week10"])
        try library.validate()
    }
    @Test func sixVideosThreeCandidatesGeneratedSubtitlesIgnored() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for subject in ["CourseA","IM","CourseB"] {
            let folder = root.appendingPathComponent(subject + "/Week8")
            for name in ["T-s1-full.mp4","T-s2-full.mp4","T-transcript.vtt","T.lectureplayer-id.zh.vtt"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        }
        let result = try await DirectoryScanner().scan(root,settle: .milliseconds(5))
        #expect(result.media.count == 6 && result.files.count == 9)
        #expect(DirectoryIndex.pendingGroups(result.media.map(\.url)).count == 3)
    }
    @Test func changingFileIsDeferredAndHashCacheInvalidated() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("CourseA/Week8/T.mp4"); try Data("first".utf8).write(to: file)
        let scanner = DirectoryScanner()
        let first = try await scanner.scan(root,settle: .milliseconds(5))
        let task = Task { try await scanner.scan(root,settle: .milliseconds(150)) }
        try await Task.sleep(for: .milliseconds(40)); try Data("new larger contents".utf8).write(to: file)
        let unstable = try await task.value
        #expect(unstable.unstable && unstable.media.isEmpty)
        let final = try await scanner.scan(root,settle: .milliseconds(5))
        #expect(final.media[0].hash != first.media[0].hash)
        #expect(throws: (any Error).self) { try FileStamp.read(root.appendingPathComponent("missing")) }
    }
    @Test func missingPrimaryUsesCameraAndCrossDirectoryConflict() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var library = Library(); DirectoryIndex.buildTree([root.appendingPathComponent("CourseA/Week8"),root.appendingPathComponent("IM/Week8")],root: root,library: &library)
        let camera = root.appendingPathComponent("CourseA/Week8/T-s2-full.mp4"); try Data("camera".utf8).write(to: camera)
        var lesson = Lecture(title:"keep",courseID:library.courses[0].id,folderID:nil,url:root.appendingPathComponent("missing.mp4"),bookmark:nil,identity:"old")
        lesson.mediaSources.append(MediaSource(role:.camera,path:camera.path,bookmark:nil,identity:"cam"))
        lesson.state.position = 5254; lesson.state.offset = 14; let original = lesson
        #expect(DirectoryIndex.classifyAvailable(&lesson,root:root,library:&library).isEmpty)
        #expect(lesson.directoryPath == camera.deletingLastPathComponent().path && lesson.path == original.path && lesson.state == original.state)
        let screen = root.appendingPathComponent("IM/Week8/T-s1-full.mp4"); try Data("screen".utf8).write(to: screen)
        var sources = lesson.mediaSources; sources[0].path = screen.path; lesson.mediaSources = sources
        #expect(DirectoryIndex.classifyAvailable(&lesson,root:root,library:&library).count == 2)
        #expect(lesson.directoryPath == camera.deletingLastPathComponent().path)
        lesson.directoryChoice = screen.deletingLastPathComponent().path
        #expect(DirectoryIndex.classifyAvailable(&lesson,root:root,library:&library).isEmpty)
        #expect(lesson.directoryPath == lesson.directoryChoice)
    }
    @Test func unreadableSubtreeIsPartialAndMissingRootThrows() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("CourseB"); try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        let result = try await DirectoryScanner().scan(root,settle: .milliseconds(5))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        #expect(!result.issues.isEmpty && result.directories.contains(root.appendingPathComponent("CourseA/Week8")))
        do { _ = try await DirectoryScanner().scan(root.appendingPathComponent("not-found")); Issue.record("missing root accepted") } catch {}
    }
}

struct LegacyDirectoryAssociationTests {
    @Test func uniqueLegacyCourseKeepsGlossaryAndIdentity() {
        var library=Library(); var course=Course(name:"CourseA"); course.glossary="custom terminology"; library.courses=[course]
        let root=URL(fileURLWithPath:"/tmp/recordings")
        DirectoryIndex.buildTree([root.appendingPathComponent("CourseA/Week8")],root:root,library:&library)
        #expect(library.courses.count == 1 && library.courses[0].id == course.id && library.courses[0].glossary == course.glossary)
    }
}
