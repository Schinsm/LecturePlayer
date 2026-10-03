import Foundation
import AVFoundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct TimingProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_REAL_SCREEN"] != nil))
    func threePositionMediaTimelineProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        let transcript = try SubtitleParser.parse(Data(contentsOf: URL(fileURLWithPath: try #require(env["LP_REAL_VTT"]))), format: "vtt")
        var rows: [[String: Any]] = []
        for key in ["LP_REAL_SCREEN", "LP_REAL_CAMERA"] {
            let url = URL(fileURLWithPath: try #require(env[key]))
            let player = Playback(); player.player.isMuted = true
            let lecture = Lecture(title: "Timeline probe", courseID: UUID(), folderID: nil, url: url, bookmark: nil, identity: key)
            player.load(lecture)
            for _ in 0..<200 { if player.ready || player.error != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
            try #require(player.ready)
            for seconds in [450.0, 3300, 6300] {
                let cue = try #require(transcript.cues.min { abs(Double($0.start)/1000-seconds) < abs(Double($1.start)/1000-seconds) })
                for offset in [0.0, 2.0, -2.0, 14.0] {
                    let target = transcript.target(cue, offset: offset)
                    player.seek(target)
                    try await Task.sleep(for: .milliseconds(250))
                    let actual = player.player.currentTime().seconds
                    #expect(abs(actual-target) < 0.002)
                    rows.append(["view": key == "LP_REAL_SCREEN" ? "screen" : "camera", "originalSeconds": Double(cue.start)/1000, "endSeconds": Double(cue.end)/1000, "offsetSeconds": offset, "effectiveSeconds": target, "playerSeconds": actual, "seekErrorSeconds": actual-target, "auditoryMismatch": "not assessed"])
                }
            }
            player.close()
        }
        if let path = env["LP_UI_LIBRARY"] {
            let repository = try Repository(root: URL(fileURLWithPath: path))
            var library = Library(); let course = Course(name: "0.3 同步实测"); library.courses = [course]
            for (key,title) in [("LP_REAL_SCREEN","屏幕 · 版权片头测试"),("LP_REAL_CAMERA","摄像头 · 版权片头测试")] {
                var lecture = Lecture(title: title, courseID: course.id, folderID: nil, url: URL(fileURLWithPath: try #require(env[key])), bookmark: nil, identity: key)
                lecture.transcriptVersion = transcript.version; lecture.state.position = 400.970; lecture.state.speed = 1.5
                library.lectures.append(lecture); try repository.write(transcript, for: lecture.id)
            }
            library.lastLecture = library.lectures.first?.id
            try repository.save(library)
        }
        if let path = env["LP_PROBE_REPORT"] { try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

@Suite(.serialized) @MainActor struct SyncPersistenceTests {
    @Test func perLectureOffsetSurvivesRepositoryReopenAndBackup() throws {
        let (root, original, t) = try PersistenceTests().fixture()
        var library = original
        library.lectures[0].state.subtitleOffsetSeconds = 14
        var second = library.lectures[0]; second.id = UUID(); second.state.subtitleOffsetSeconds = -1.5
        library.lectures.append(second)
        let repository = try Repository(root: root)
        try repository.write(t, for: library.lectures[0].id); try repository.write(t, for: second.id)
        try repository.save(library)
        let reopened = try Repository(root: root).load()
        #expect(reopened.lectures.first { $0.id == original.lectures[0].id }?.state.subtitleOffsetSeconds == 14)
        #expect(reopened.lectures.first { $0.id == second.id }?.state.subtitleOffsetSeconds == -1.5)
        #expect(reopened.lectures[0].state.position == 7); #expect(reopened.lectures[0].state.speed == 1.5)
        let store = AppStore(root: root); let backup = try store.snapshot()
        let copy = try Codec.decode(Backup.self, Codec.encode(backup)); #expect(copy.library == reopened)
        #expect(try repository.read(reopened.lectures[0])?.original == t.original)
        store.playback.close()
    }
    @Test func cachedCellChangesWhenEffectiveClickTargetChanges() {
        let cue = Cue(id: "test", start: 1000, end: 3000, en: "Text")
        let before = CueCell(cue: cue, translation: nil, mode: "双语", fontSize: 17, spacing: 5, active: false, match: true, targetSeconds: SubtitleTimingMapper().seekTarget(cue), seek: { _ in })
        let after = CueCell(cue: cue, translation: nil, mode: "双语", fontSize: 17, spacing: 5, active: false, match: true, targetSeconds: SubtitleTimingMapper(offset: 14).seekTarget(cue), seek: { _ in })
        #expect(before != after); #expect(after.targetSeconds == 15)
    }
}
