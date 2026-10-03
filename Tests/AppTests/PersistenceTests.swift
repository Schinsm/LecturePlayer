import Foundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct PersistenceTests {
    func fixture() throws -> (URL,Library,Transcript) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LecturePlayer-tests-\(UUID())")
        let c=Course(name:"Fifth custom course");var library=Library();library.courses=[c]
        let f=Folder(name:"Week / Lecture",courseID:c.id);library.folders=[f]
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Synthetic.mp4")
        var l=Lecture(title:"Test",courseID:c.id,folderID:f.id,url:url,bookmark:nil,identity:"test")
        let t=try SubtitleParser.parse(Data("WEBVTT\n\ncue\n00:01.000 --> 00:10.000\nHello\n".utf8),format:"vtt")
        l.transcriptVersion=t.version;l.state.position=7;l.state.speed=1.5;l.marks=[Mark(seconds:3,note:"Bookmark")];library.lectures=[l];library.lastLecture=l.id
        return(root,library,t)
    }
    @Test func actualSwiftDataReopenAndTranscriptIsolation() throws {
        let(root,library,t)=try fixture();let id=library.lectures[0].id
        do {let r=try Repository(root:root);try r.write(t,for:id);try r.save(library)}
        let r=try Repository(root:root);#expect(try r.load()==library);let file=try r.transcriptURL(id,t.version);let before=try Data(contentsOf:file)
        var changed=try r.load();changed.lectures[0].state.position=8;try r.save(changed)
        #expect(try Data(contentsOf:file)==before);#expect(try r.read(changed.lectures[0])==t)
        #expect(try Repository(root:root).load().lectures[0].state.speed==1.5)
    }
    @Test func invalidLibraryDoesNotReplaceDisk() throws {
        let(root,library,_)=try fixture();let r=try Repository(root:root);try r.save(library);var bad=library;bad.schema=999
        #expect(throws:(any Error).self){try r.save(bad)};#expect(try r.load()==library)
    }
    @Test func realAVFoundationReadySeekPauseAndReopen() async throws {
        let(root,library,_)=try fixture();let r=try Repository(root:root);try r.save(library)
        let player=Playback();var saved=library
        player.save={id,position,duration in guard let i=saved.lectures.firstIndex(where:{$0.id==id}) else{return};saved.lectures[i].state.record(position,ready:true);saved.lectures[i].duration=duration;try? r.save(saved)}
        player.load(library.lectures[0]);player.persist();#expect(saved.lectures[0].state.position==7)
        for _ in 0..<100 {if player.ready || player.error != nil {break};try await Task.sleep(nanoseconds:100_000_000)}
        #expect(player.error==nil);#expect(player.ready);#expect(abs(player.position-7)<0.1);#expect(player.player.rate==0);#expect(player.targetSpeed==1.5)
        player.seek(3);try await Task.sleep(nanoseconds:250_000_000);#expect(abs(player.player.currentTime().seconds-3)<0.1)
        player.toggle();try await Task.sleep(nanoseconds:400_000_000);#expect(player.player.rate==1.5);player.toggle();player.close()
        let reopened=try Repository(root:root).load();#expect(reopened.lectures[0].state.position>3);#expect(reopened.lectures[0].state.speed==1.5)
        player.load(reopened.lectures[0]);for _ in 0..<100{if player.ready{break};try await Task.sleep(nanoseconds:100_000_000)}
        #expect(player.ready);#expect(player.player.rate==0);#expect(abs(player.position-reopened.lectures[0].state.position)<0.1);player.close()
    }
}

@Suite(.serialized) @MainActor struct SeekLifecycleTests {
    @Test func seekThenImmediatelyClosePersistsTarget() async throws {
        let (_, library, _) = try PersistenceTests().fixture()
        let playback = Playback(); playback.player.isMuted = true
        var position = library.lectures[0].state.position
        playback.save = { _, seconds, _ in position = seconds }
        playback.load(library.lectures[0])
        for _ in 0..<100 { if playback.ready { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(playback.ready)
        playback.seek(9); playback.close()
        #expect(position == 9)
    }
}

@Suite(.serialized) @MainActor struct RealLectureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_REAL_SCREEN"] != nil))
    func authorizedLongLectureImportSeekSwitchAndRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        let screen = URL(fileURLWithPath: try #require(env["LP_REAL_SCREEN"]))
        let camera = URL(fileURLWithPath: try #require(env["LP_REAL_CAMERA"]))
        let subtitles = URL(fileURLWithPath: try #require(env["LP_REAL_VTT"]))
        let root = URL(fileURLWithPath: try #require(env["LP_REAL_LIBRARY"]))
        let source = try Data(contentsOf: subtitles)
        let store = AppStore(root: root)
        #expect(!store.fatal)
        for name in ["CourseC", "IM", "CourseB", "Other", "CourseA Real QA"] { store.addCourse(name) }
        store.addFolder("Lecture"); store.selectedFolder = store.library.folders.last?.id
        try store.importPair(video: screen, subtitle: subtitles, title: "CourseA · 屏幕视角（真实测试）")
        try store.importPair(video: camera, subtitle: subtitles, title: "CourseA · 摄像头视角（真实测试）")
        #expect(throws: (any Error).self) { try store.importPair(video: screen, subtitle: subtitles, title: "Duplicate") }
        let screenID = store.library.lectures[0].id, cameraID = store.library.lectures[1].id
        store.playback.player.isMuted = true
        store.updateLecture(screenID) { $0.state.position = 3456; $0.state.speed = 1.5 }
        store.open(screenID)
        try await waitReady(store.playback)
        #expect(store.transcript?.cues.count == 1459)
        #expect(abs(store.playback.duration - 6909.156315) < 0.2)
        #expect(store.playback.player.rate == 0)
        #expect(abs(store.playback.position - 3456) < 0.1)
        let transcript = try #require(store.transcript)
        for index in [0, transcript.cues.count / 2, transcript.cues.count - 1] {
            let target = transcript.target(transcript.cues[index], offset: 0)
            store.playback.seek(target)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(abs(store.playback.player.currentTime().seconds - target) < 0.15)
        }
        store.playback.seek(3456)
        try await Task.sleep(nanoseconds: 300_000_000)
        store.playback.toggle(); try await Task.sleep(nanoseconds: 600_000_000); store.playback.toggle()
        #expect(store.playback.player.rate == 0)
        #expect(store.playback.position >= 3456)
        // Alternate angles repeatedly. They remain distinct references with independent state.
        for _ in 0..<3 {
            store.open(cameraID); try await waitReady(store.playback); store.playback.seek(120)
            store.open(screenID); try await waitReady(store.playback)
            #expect(store.playback.position >= 3456)
        }
        store.playback.seek(3456); store.playback.close()
        let reopened = AppStore(root: root); reopened.playback.player.isMuted = true
        try await waitReady(reopened.playback)
        #expect(reopened.current == screenID)
        #expect(reopened.lecture?.state.speed == 1.5)
        #expect(abs(reopened.playback.position - 3456) < 0.1)
        #expect(reopened.playback.player.rate == 0)
        #expect(reopened.library.lectures.first(where: { $0.id == cameraID })?.state.position == 120)
        #expect(try Data(contentsOf: subtitles) == source)
        for kind in [ExportKind.englishVTT, .bilingualVTT, .bilingualSRT] {
            let export = try Exporter.render(transcript, kind: kind)
            let parsed = try SubtitleParser.parse(export, format: kind.ext)
            #expect(parsed.cues.map(\.start) == transcript.cues.map(\.start))
            #expect(parsed.cues.map(\.end) == transcript.cues.map(\.end))
        }
        let backup = try reopened.snapshot(); try backup.validate()
        #expect(try Codec.decode(Backup.self, Codec.encode(backup)).library == backup.library)
        reopened.playback.close()
    }
    private func waitReady(_ playback: Playback) async throws {
        for _ in 0..<200 { if playback.ready || playback.error != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(playback.error == nil); try #require(playback.ready)
    }
}
