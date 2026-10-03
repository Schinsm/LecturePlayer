import Foundation
import Testing
import SwiftData
@testable import LecturePlayer
@testable import Core

@Suite(.serialized) @MainActor struct V041AppTests {
    @Test func addingCameraPreservesLessonAndTranslations() async throws {
        let (root, library, original) = try PersistenceTests().fixture(); let store = AppStore(root: root)
        var transcript = original; transcript.translations[transcript.cues[0].id] = Translation(ai:"保留",cacheKey:"mock")
        try store.repository?.save(library); store.library = library; try store.repository?.write(transcript, for: library.lectures[0].id)
        let item = library.lectures[0], camera = root.appendingPathComponent("T-s2-full.mp4")
        try Data(contentsOf: URL(fileURLWithPath: item.path)).write(to: camera)
        try await store.attachSecond(item.id, url: camera)
        let result = try #require(store.library.lectures.first)
        #expect(result.id == item.id && result.state == item.state && result.marks == item.marks)
        #expect(result.mediaSources.count == 2 && result.mediaSources[1].role == .camera)
        #expect(try store.repository?.read(result) == transcript)
        let restored = try Repository(root: root).load(); #expect(restored.lectures[0].mediaSources.count == 2)
        do { try await store.attachSecond(item.id,url:camera); Issue.record("third source accepted") } catch { }
    }
    @Test func sidecarFailureNeverLosesSavedTranslations() async throws {
        let (root, library, original) = try PersistenceTests().fixture(); let store = AppStore(root: root); store.library = library; try store.repository?.save(library)
        var t = original; t.translations[t.cues[0].id] = Translation(ai:"已保存",cacheKey:"mock")
        try store.saveTranscript(t, lectureID:library.lectures[0].id)
        #expect(try store.repository?.read(library.lectures[0])?.translations == t.translations)
        await store.saveVisibleTranslations(library.lectures[0].id)?.value
        #expect(store.library.lectures[0].sidecarStatus?.contains("请定位") == true)
        let subtitle = root.appendingPathComponent("original.vtt"); try t.original.write(to:subtitle)
        store.updateLecture(library.lectures[0].id) { $0.subtitlePath = subtitle.path }
        await store.saveVisibleTranslations(library.lectures[0].id)?.value
        #expect(store.library.lectures[0].sidecars?.count == 2)
        #expect(!store.translation.running)
    }
    @Test func directoryRefreshMovesPreservesAndDoesNotDuplicate() async throws {
        let (root, fixture, transcript) = try PersistenceTests().fixture(); let store = AppStore(root: root)
        let mediaRoot = root.appendingPathComponent("Recordings"), folder = mediaRoot.appendingPathComponent("CourseA/Week 2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("T-s1-full.mp4"), subtitle = folder.appendingPathComponent("T-transcript.vtt")
        try Data(contentsOf: URL(fileURLWithPath: fixture.lectures[0].path)).write(to: video); try transcript.original.write(to: subtitle)
        store.library.directoryRoot = mediaRoot.path; try store.repository?.save(store.library)
        try await store.importLesson(row: ImportRow(video: video, subtitle: subtitle, title: "Stable"), managed: false)
        let initial = try #require(store.library.lectures.first)
        store.updateLecture(initial.id) { $0.state.position = 7; $0.state.offset = 14; $0.marks = [Mark(seconds: 3,note: "keep")] }
        var translated = transcript; translated.translations[transcript.cues[0].id] = Translation(ai: "保留",cacheKey:"mock")
        try store.saveTranscript(translated,lectureID:initial.id)
        let renamed = mediaRoot.appendingPathComponent("CourseA/Week 10 Renamed")
        try FileManager.default.moveItem(at: folder,to:renamed)
        for _ in 0..<2 { store.refreshDirectory(); for _ in 0..<300 { if !store.scanning { break }; try await Task.sleep(for:.milliseconds(20)) }; #expect(!store.scanning) }
        let item = try #require(store.library.lectures.first)
        #expect(store.library.lectures.count == 1 && item.id == initial.id && item.state.position == 7 && item.state.offset == 14)
        #expect(item.path.contains("Week 10 Renamed")); #expect(item.subtitlePath?.contains("Week 10 Renamed") == true)
        #expect(try store.repository?.read(item)?.translations == translated.translations); #expect(store.pendingFiles.isEmpty)
        // Already translated selection exits before confirmation, Keychain or network access.
        store.current = item.id; store.transcript = translated
        store.translation.start(store:store,ids:Set(translated.translations.keys))
        #expect(!store.translation.running); #expect(store.translation.status.contains("没有发起请求"))
        try FileManager.default.moveItem(at:renamed,to:root.appendingPathComponent("offline"))
        store.refreshDirectory(); for _ in 0..<300 { if !store.scanning { break }; try await Task.sleep(for:.milliseconds(20)) }
        #expect(store.library.lectures.count == 1); #expect(try store.repository?.read(item)?.translations == translated.translations)
        store.playback.close()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_041_FORMAL_COPY"] != nil))
    func isolatedFormalUpgrade() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LP_041_FORMAL_COPY"])
        let repository = try Repository(root: URL(fileURLWithPath:path)); let library = try repository.load()
        #expect(library.schema == 4); let item = try #require(library.lectures.first)
        #expect(item.state.offset == 14); #expect(item.state.position > 5000)
        #expect(try repository.read(item)?.translatedCount == 5)
        let snapshot = try FileManager.default.contentsOfDirectory(at: repository.root, includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasPrefix("before-v07") }
        #expect(snapshot != nil)
    }
}
