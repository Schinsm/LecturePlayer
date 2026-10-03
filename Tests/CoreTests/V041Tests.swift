import Foundation
import Testing
@testable import Core

@Suite struct V041CoreTests {
    @Test func captureRolesAndAmbiguousPairs() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/CourseA/Week 7/" + name) }
        let a = url("T-s1-full.mp4"), b = url("T-s2-full.mp4")
        #expect(ImportPlanner.role(for: a) == .screen); #expect(ImportPlanner.role(for: b) == .camera)
        for name in ["T-s10-full.mp4", "Ts1.mp4", "T-s1-s2.mp4"] { #expect(ImportPlanner.role(for: url(name)) == nil) }
        #expect(ImportPlanner.companion(for: a, in: [a,b]) == b)
        #expect(ImportPlanner.companion(for: a, in: [a,b,url("T-s2-full.mov")]) == nil)
        #expect(ImportPlanner.companion(for: a, in: [a,URL(fileURLWithPath: "/tmp/elsewhere/T-s2-full.mp4")]) == nil)
    }
    @Test func directoryMoveAndDuplicateIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/recordings"), url = root.appendingPathComponent("CourseA/Week 10/Workshop/T.mp4")
        var library = Library(); var lesson = Lecture(title: "Keep", courseID: UUID(), folderID: nil, url: url, bookmark: nil, identity: "stable")
        lesson.state.position = 5139; lesson.state.offset = 14; lesson.marks = [Mark(seconds: 4,note: "keep")]
        let before = lesson
        DirectoryIndex.classify(&lesson, root: root, library: &library)
        #expect(library.courses.first?.name == "CourseA"); #expect(library.folders.map(\.name) == ["Week 10", "Workshop"])
        #expect(lesson.id == before.id && lesson.state == before.state && lesson.marks == before.marks)
        DirectoryIndex.classify(&lesson, root: root, library: &library); #expect(library.courses.count == 1 && library.folders.count == 2)
        var source = lesson.mediaSources[0]; source.contentHash = "hash"
        let moved = IndexedMedia(url: root.appendingPathComponent("CourseA/Week 2/T.mp4"), identity: "stable")
        #expect(DirectoryIndex.match(source, files: [moved])?.url == moved.url)
        let copy = IndexedMedia(url: url, identity: "new", hash: "hash")
        #expect(DirectoryIndex.match(source, files: [copy])?.url == url)
        #expect(DirectoryIndex.match(source, files: [copy,IndexedMedia(url: moved.url,identity:"other",hash:"hash")]) == nil)
        #expect(DirectoryIndex.relativeDirectory(URL(fileURLWithPath: "/tmp/recordings-other/CourseA/a.mp4"), root: root) == nil)
    }
    @Test func visibleTranslationsPreserveTimeAndManualEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("WEBVTT\n\noriginal-cue\n00:00:01.000 --> 00:00:03.000\nHello\n\nsecond\n00:00:04.000 --> 00:00:05.000\nWorld\n".utf8)
        let subtitle = root.appendingPathComponent("English.vtt"); try original.write(to: subtitle)
        var t = try SubtitleParser.parse(original, format: "vtt"); t.translations[t.cues[0].id] = Translation(ai: "你好", cacheKey: "mock")
        var lesson = Lecture(title: "test", courseID: UUID(), folderID: nil, url: root.appendingPathComponent("a.mp4"), bookmark: nil, identity: "a"); lesson.state.offset = 14
        lesson.sidecars = try SidecarWriter.write(t, lesson: lesson, beside: subtitle)
        let path = try #require(lesson.sidecars?.keys.first(where: { $0.hasSuffix("zh.vtt") }))
        let parsed = try SubtitleParser.parse(Data(contentsOf: URL(fileURLWithPath: path)), format: "vtt")
        #expect(parsed.cues.count == 1); #expect(parsed.cues[0].start == 1000 && parsed.cues[0].sourceID == "original-cue")
        let edited = Data("manual changes".utf8); try edited.write(to: URL(fileURLWithPath: path))
        t.translations[t.cues[1].id] = Translation(ai:"世界",cacheKey:"mock")
        let files = try SidecarWriter.write(t, lesson: lesson, beside: subtitle)
        #expect(files.count == 2); #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == edited)
        #expect(try Data(contentsOf: subtitle) == original)
        #expect(try ImportPlanner.scan([root]).map(\.path) == [DirectoryIndex.canonical(subtitle).path])
        var missing=lesson;missing.path=root.appendingPathComponent("missing/a.mp4").path
        #expect(throws: (any Error).self) { try SidecarWriter.write(t, lesson: missing, beside: subtitle) }
    }
}
