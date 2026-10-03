import Foundation
import AVFoundation
import SwiftData
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V04PlaybackTests {
    @Test func continuousVolumeMuteAndPersistence() {
        let name = "volume-\(UUID())"; let prefs = UserDefaults(suiteName: name)!; defer { prefs.removePersistentDomain(forName: name) }
        let p = Playback(preferences: prefs); p.setVolume(0.37123); #expect(p.volume == 0.37123); p.toggleMute(); #expect(p.volume == 0); p.toggleMute(); #expect(p.volume == 0.37123)
        let reopened = Playback(preferences: prefs); #expect(reopened.volume == 0.37123); #expect(!reopened.playing); p.close(); reopened.close()
    }
    @Test func studyPackageWithAndWithoutMedia() async throws {
        let (root, library, transcript) = try PersistenceTests().fixture(); let repo = try Repository(root: root); try repo.write(transcript, for: library.lectures[0].id); try repo.save(library)
        let store = AppStore(root: root); defer { store.playback.close() }
        let noMedia = root.appendingPathComponent("NoMedia.lecturestudy")
        try await store.writeStudyPackage(item: library.lectures[0], destination: noMedia, includeMedia: false)
        let data = try Data(contentsOf: noMedia.appendingPathComponent("Library.json")); let restored = try Codec.decode(Backup.self, data); try restored.validate()
        #expect(restored.library.lectures[0].marks == library.lectures[0].marks); #expect(restored.transcripts.values.first == transcript)
        #expect(!FileManager.default.fileExists(atPath: noMedia.appendingPathComponent("Media").path)); #expect(restored.library.lectures[0].bookmark == nil)
        let withMedia = root.appendingPathComponent("WithMedia.lecturestudy")
        try await store.writeStudyPackage(item: library.lectures[0], destination: withMedia, includeMedia: true)
        let backup = try Codec.decode(Backup.self, Data(contentsOf: withMedia.appendingPathComponent("Library.json")))
        let path = backup.library.lectures[0].mediaSources[0].path
        #expect(path.hasPrefix("Media/")); #expect(try Data(contentsOf: withMedia.appendingPathComponent(path)) == Data(contentsOf: URL(fileURLWithPath: library.lectures[0].path)))
        #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
    }
    @Test func managedImportFailureDoesNotCommit() async throws {
        let (root, library, _) = try PersistenceTests().fixture(); let store = AppStore(root: root); store.addCourse("Import QA")
        let row = ImportRow(video: URL(fileURLWithPath: library.lectures[0].path), title: "Managed")
        let blocked = root.appendingPathComponent("not-a-directory"); try Data("blocked".utf8).write(to: blocked)
        do { try await store.importLesson(row: row, managed: true, destinationRoot: blocked); Issue.record("Copy should fail") } catch { }
        #expect(store.library.lectures.isEmpty); #expect(try store.repository?.load().lectures.isEmpty == true)
        let mediaRoot = root.appendingPathComponent("Media")
        try await store.importLesson(row: row, managed: true, destinationRoot: mediaRoot)
        let imported = try #require(store.library.lectures.first); #expect(imported.mediaSources[0].managed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: imported.path)) == Data(contentsOf: row.video)); #expect(FileManager.default.fileExists(atPath: row.video.path))
        store.playback.close()
    }
    @Test func repositoryMigrationSnapshotAndRollback() throws {
        let (root, fixture, originalTranscript) = try PersistenceTests().fixture(); var transcript = originalTranscript
        transcript.translations[transcript.cues[0].id] = Translation(ai: "已保存译文", cacheKey: "mock")
        let repository = try Repository(root: root)
        var old = fixture; old.schema = 1; old.lectures[0].state.offset = 14
        try repository.write(transcript, for: old.lectures[0].id)
        repository.context.insert(MetadataRecord(key: "schema", payload: try Codec.encode(1)))
        repository.context.insert(MetadataRecord(key: "c-\(old.courses[0].id)", payload: try Codec.encode(old.courses[0])))
        repository.context.insert(MetadataRecord(key: "f-\(old.folders[0].id)", payload: try Codec.encode(old.folders[0])))
        repository.context.insert(MetadataRecord(key: "l-\(old.lectures[0].id)", payload: try Codec.encode(old.lectures[0])))
        try repository.context.save()
        let migrated = try repository.load(); #expect(migrated.schema == 4); #expect(migrated.lectures[0].state == old.lectures[0].state); #expect(try repository.read(migrated.lectures[0]) == transcript)
        let snapshots = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("before-v07-") }
        #expect(snapshots.count == 1); let backup = try Codec.decode(Backup.self, Data(contentsOf: snapshots[0])); try backup.validate(); #expect(backup.library.schema == 1)
        // A corrupt legacy record must not replace the on-disk version or write an upgrade snapshot.
        let brokenRoot = root.appendingPathComponent("broken"); let broken = try Repository(root: brokenRoot)
        broken.context.insert(MetadataRecord(key: "schema", payload: try Codec.encode(1)))
        broken.context.insert(MetadataRecord(key: "l-bad", payload: Data("bad".utf8))); try broken.context.save()
        #expect(throws: (any Error).self) { try broken.load() }
        let rows = try broken.context.fetch(FetchDescriptor<MetadataRecord>()); #expect(try Codec.decode(Int.self, rows.first { $0.key == "schema" }!.payload) == 1)
    }
    @Test func dualSyntheticSeekOffsetAudioAndMissing() async throws {
        let (_, fixture, _) = try PersistenceTests().fixture(); var lesson = fixture.lectures[0]
        lesson.path = URL(fileURLWithPath: lesson.path).deletingLastPathComponent().appendingPathComponent("SyntheticAudio.mp4").path
        var camera = lesson.mediaSources[0]; camera.id = UUID(); camera.role = .camera; camera.relativeOffset = 1
        lesson.mediaSources = [lesson.mediaSources[0], camera]
        let p = Playback(preferences: UserDefaults(suiteName: "dual-test")!); p.player.isMuted = true; p.secondaryPlayer.isMuted = true
        p.load(lesson); try await wait(p); #expect(p.views.count == 2); #expect(p.player.rate == 0 && p.secondaryPlayer.rate == 0)
        p.seek(3)
        // Seek completion depends on AVFoundation scheduling, not a fixed 250 ms delay.
        for _ in 0..<100 {if abs(p.player.currentTime().seconds-3)<0.01 && abs(p.secondaryPlayer.currentTime().seconds-4)<0.01 {break};try await Task.sleep(for:.milliseconds(50))}
        #expect(abs(p.player.currentTime().seconds - 3) < 0.01); #expect(abs(p.secondaryPlayer.currentTime().seconds - 4) < 0.01)
        p.setVolume(0.37); #expect(p.player.volume == Float(0.37)); #expect(p.secondaryPlayer.volume == 0)
        p.selectAudio(camera.id); #expect(p.player.volume == 0); #expect(p.secondaryPlayer.volume == Float(0.37))
        p.toggle()
        // AVPlayer preroll is asynchronous; wait for the actual start, not a fixed wall-clock delay.
        for _ in 0..<100 { if p.player.rate == 1.5 && p.secondaryPlayer.rate == 1.5 { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(p.player.rate == 1.5); #expect(p.secondaryPlayer.rate == 1.5)
        #expect(abs(p.secondaryPlayer.currentTime().seconds - p.player.currentTime().seconds - 1) < 0.1)
        p.pause(); p.seek(11.5)
        for _ in 0..<100 {if p.ended.contains(camera.id) {break};try await Task.sleep(for:.milliseconds(50))}
        #expect(p.ended.contains(camera.id)); p.close()
        var sources = lesson.mediaSources; sources[0].path = "/missing-\(UUID()).mp4"; sources[0].bookmark = nil; lesson.mediaSources = sources
        p.load(lesson); try await wait(p); #expect(p.ready); #expect(p.missing.contains(sources[0].id)); #expect(p.audioID == camera.id); p.close()
        lesson.state.position = 100; lesson.duration = 200
        var saved = 100.0; p.save = { _, value, _ in saved = value }; p.load(lesson); try await wait(p)
        try await Task.sleep(for: .milliseconds(200)); p.persist(); #expect(abs(p.position - 100) < 0.001); #expect(abs(saved - 100) < 0.001); p.close()
    }
    func wait(_ p: Playback) async throws { for _ in 0..<300 { if p.ready { return }; try await Task.sleep(for: .milliseconds(50)) }; try #require(p.ready) }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_DUAL_REAL"] != nil))
    func realDualTenMinuteRun() async throws {
        let env = ProcessInfo.processInfo.environment
        let screen = URL(fileURLWithPath: try #require(env["LP_REAL_SCREEN"])), camera = URL(fileURLWithPath: try #require(env["LP_REAL_CAMERA"]))
        let course = Course(name: "0.4 隔离验收")
        var lesson = Lecture(title: "双视频实测", courseID: course.id, folderID: nil, url: screen, bookmark: nil, identity: "screen")
        lesson.week = 7; lesson.sessionType = "Lecture"; lesson.topic = "双视频实测"; lesson.customTitle = false; lesson.state.offset = 14
        lesson.mediaSources = [MediaSource(path: screen.path), MediaSource(role: .camera, path: camera.path)]
        let p = Playback(preferences: UserDefaults(suiteName: "dual-real-qa")!); p.player.isMuted = true; p.secondaryPlayer.isMuted = true; p.load(lesson); try await wait(p)
        var samples: [[String: Double]] = []; var maximum = 0.0
        for target in [20.0, 3450, 6880] {
            p.seek(target); try await Task.sleep(for: .milliseconds(400)); #expect(abs(p.player.currentTime().seconds - target) < 0.01); #expect(abs(p.secondaryPlayer.currentTime().seconds - target) < 0.01)
            p.toggle(); try await Task.sleep(for: .seconds(2)); p.pause()
            #expect(abs(p.player.currentTime().seconds - p.secondaryPlayer.currentTime().seconds) < 0.1)
        }
        p.seek(400); try await Task.sleep(for: .milliseconds(300)); p.toggle()
        let started = Date(); let seconds = Double(env["LP_DUAL_SECONDS"] ?? "605") ?? 605
        while Date().timeIntervalSince(started) < seconds || p.position < 1000 {
            guard Date().timeIntervalSince(started) < seconds + 60 else { Issue.record("Unable to play 600 seconds within the bounded test session"); break }
            try await Task.sleep(for: .seconds(1))
            let drift = abs(p.player.currentTime().seconds - p.secondaryPlayer.currentTime().seconds)
            if p.playing && !p.waiting && p.player.rate == 1 && p.secondaryPlayer.rate == 1 { maximum = max(maximum, drift); #expect(drift <= 0.1) }
            samples.append(["elapsed": Date().timeIntervalSince(started), "screen": p.player.currentTime().seconds, "camera": p.secondaryPlayer.currentTime().seconds, "drift": drift, "screenRate": Double(p.player.rate), "cameraRate": Double(p.secondaryPlayer.rate), "stable": (p.playing && !p.waiting && p.player.rate == 1 && p.secondaryPlayer.rate == 1) ? 1 : 0])
            if samples.count % 30 == 0 { print("DUAL_PROGRESS \(samples.count)s maxDrift=\(maximum)") }
        }
        p.pause(); #expect(p.position >= 1000); p.close()
        if let path = env["LP_DUAL_REPORT"] { try JSONSerialization.data(withJSONObject: ["samples": samples, "maxStableDrift": maximum, "duration": Date().timeIntervalSince(started), "auditory": "not assessed; both players muted"], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        if let path = env["LP_DUAL_UI_LIBRARY"] {
            let root = URL(fileURLWithPath: path); let r = try Repository(root: root); var library = Library(); library.courses = [course]
            var t = try SubtitleParser.parse(Data(contentsOf: URL(fileURLWithPath: try #require(env["LP_REAL_VTT"]))), format: "vtt")
            if let first = t.cues.first { t.translations[first.id] = Translation(ai: "隔离测试译文", cacheKey: "mock") }
            lesson.transcriptVersion = t.version; lesson.state.position = 414.97; lesson.marks = [Mark(seconds: 414.97, note: "QA bookmark")]
            library.lectures = [lesson]; library.lastLecture = lesson.id; try r.write(t, for: lesson.id); try r.save(library)
        }
    }
}
