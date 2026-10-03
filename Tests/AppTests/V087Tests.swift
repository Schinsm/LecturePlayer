import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V087AppTests {
    func fixture() throws -> (AppStore,UserDefaults,String) {
        let (root,original,t)=try PersistenceTests().fixture();var lib=original
        var second=lib.lectures[0];second.id=UUID();second.title="Second";second.identity="second";second.state.position=2
        lib.lectures.append(second)
        var legacy=VideoCaptionPreferences();legacy.enabled=true;legacy.transparency=0.6;legacy.fontSize=28;legacy.mode="英文"
        lib.lectures[0].videoCaptions=legacy;lib.lectures[1].videoCaptions=VideoCaptionPreferences()
        let repo=try Repository(root:root);try repo.save(lib);for lesson in lib.lectures {try repo.write(t,for:lesson.id)}
        let name="LP087-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        let store=AppStore(root:root,preferences:defaults)
        // Repository rows have no ordering contract. Keep fixture roles explicit.
        let order=lib.lectures.map(\.id)
        store.library.lectures.sort {order.firstIndex(of:$0.id)!<order.firstIndex(of:$1.id)!}
        return (store,defaults,name)
    }
    func wait(_ p:Playback) async throws {
        let deadline=Date().addingTimeInterval(10)
        while !p.ready && p.error==nil && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
        #expect(p.ready)
    }
    @Test func globalAppearanceMigratesOnceFlushesOnSwitchAndSurvivesRestart() async throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        #expect(s.captions.value.enabled && s.captions.value.transparency==0.6)
        let before=s.library.lectures.map(\.videoCaptions)
        s.captions.setEditing(true)
        s.captions.update{$0.enabled=false;$0.transparency=0.91;$0.mode="中文";$0.fontSize=32;$0.position="top";$0.margin=0.1;$0.grouped=false}
        let value=s.captions.value
        s.open(s.library.lectures[1].id)
        #expect(s.captions.value==value)
        #expect(s.library.lectures.map(\.videoCaptions)==before)
        let reopened=AppStore(root:s.repository!.root,preferences:d);defer{reopened.playback.close()}
        #expect(reopened.captions.value==value)
        #expect(reopened.captions.value.enabled==false)
        #expect(try reopened.repository!.read(reopened.lecture!)==s.transcript)
        s.captions.update{$0.enabled=true};s.captions.flush()
        let saved=GlobalCaptionPreferences(defaults:d);saved.initialize(legacy:VideoCaptionPreferences())
        #expect(saved.value.enabled && saved.value.transparency==0.91)
    }
    @Test func globalValidationDefaultsAndNoSubtitleDoesNotDisableMemory() throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        var invalid=VideoCaptionPreferences();invalid.fontSize=900;invalid.transparency=2;invalid.margin = -5;invalid.position="bad";invalid.mode="bad"
        s.captionPreferences.save(invalid)
        #expect(s.captionPreferences.value.fontSize==36 && s.captionPreferences.value.transparency==1)
        #expect(s.captionPreferences.value.margin==0 && s.captionPreferences.value.position==nil && s.captionPreferences.value.mode=="双语")
        s.captions.update{$0.enabled=false};s.captions.update{$0.enabled=true};s.captions.flush()
        let second=s.library.lectures[1].id;s.updateLecture(second){$0.transcriptVersion=nil}
        s.open(second);#expect(s.transcript==nil && s.captions.value.enabled)
    }
    @Test func indexDoesNotRebuildOnProgressButUpdatesOnRename() throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        let id=s.library.lectures[0].id,count=s.playlist.rebuildCount,row=s.playlist.rows[id]
        s.updateLecture(id,quiet:true){$0.state.position=8}
        #expect(s.playlist.rebuildCount==count)
        #expect(s.playlist.rows[id] === row);#expect(row?.lesson.state.position==8)
        s.updateLecture(id){$0.title="Renamed"}
        #expect(s.playlist.rebuildCount==count+1)
        #expect(s.playlist.index.entries.contains{$0.title=="Renamed"})
    }
    @Test func playlistPreservesPauseResumesProgressAndLastRapidChoiceWins() async throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        let first=s.library.lectures[0].id,second=s.library.lectures[1].id
        try await wait(s.playback)
        #expect(s.switchFromPlaylist(to:second));try await wait(s.playback)
        #expect(!s.playback.playing && abs(s.playback.position-2)<0.1)
        s.playback.toggle()
        #expect(s.playback.shouldContinueOnSwitch)
        #expect(s.switchFromPlaylist(to:first));#expect(s.switchFromPlaylist(to:second))
        try await wait(s.playback)
        for _ in 0..<100 {if s.playback.playing {break};try await Task.sleep(for:.milliseconds(20))}
        #expect(s.current==second && s.playback.lectureID==second && s.playback.playing)
        s.playback.pause()
        #expect(!s.switchFromPlaylist(to:UUID()))
        s.updateLecture(first){$0.finished=true;$0.state.position=11}
        #expect(s.switchFromPlaylist(to:first));try await wait(s.playback)
        #expect(s.playback.position<0.1 && !s.playback.playing)
        #expect(s.lecture?.finished==false)
    }
    @Test func naturalEndDoesNotAutoAdvanceAndShortCameraDoesNotFinishLesson() async throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        let first=s.library.lectures[0].id,second=s.library.lectures[1].id
        var lesson=s.library.lectures[0];var camera=lesson.mediaSources[0];camera.id=UUID();camera.role = .camera;camera.relativeOffset=1
        lesson.mediaSources=[lesson.mediaSources[0],camera];lesson.state.position=10.5;lesson.state.speed=1
        s.playback.load(lesson,autoplay:true);try await wait(s.playback)
        let deadline=Date().addingTimeInterval(8);var sawShortEnd=false
        while !s.playback.naturallyEnded && Date()<deadline {
            if s.playback.ended.contains(camera.id) && s.playback.position<11.8 {sawShortEnd=true;#expect(!s.playback.naturallyEnded)}
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(sawShortEnd);#expect(s.playback.naturallyEnded && !s.playback.playing)
        #expect(s.current==first && s.lecture?.finished==true)
        #expect(s.switchFromPlaylist(to:second));try await wait(s.playback)
        for _ in 0..<100 {if s.playback.playing {break};try await Task.sleep(for:.milliseconds(20))}
        #expect(s.playback.playing)
    }
    @Test func seekToEndAndMissingMediaAreNotNaturalCompletion() async throws {
        let(s,d,name)=try fixture();defer{s.playback.close();d.removePersistentDomain(forName:name)}
        try await wait(s.playback);s.playback.seek(s.playback.duration)
        try await Task.sleep(for:.milliseconds(250));#expect(!s.playback.naturallyEnded && s.lecture?.finished==false)
        let second=s.library.lectures[1].id;s.updateLecture(second){$0.path="/missing-"+UUID().uuidString;$0.bookmark=nil;$0.sources=nil}
        s.playback.toggle();#expect(s.switchFromPlaylist(to:second))
        for _ in 0..<100 {if s.playback.error != nil {break};try await Task.sleep(for:.milliseconds(20))}
        #expect(s.playback.views.first?.path.hasPrefix("/missing-")==true)
        #expect(s.playback.error != nil)
        #expect(!s.playback.ready)
        #expect(!s.playback.playing)
        #expect(s.current==second && !s.playback.naturallyEnded)
    }
}

@Suite(.serialized) @MainActor struct V087Acceptance {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP087_ACCEPTANCE"]=="1"))
    func latestSnapshotPreservedAndPrepareIsolatedGUI() async throws {
        let base=URL(fileURLWithPath:"/private/tmp/LP087/baseline-data")
        let regression=URL(fileURLWithPath:"/private/tmp/LP087/regression-data")
        try? FileManager.default.removeItem(at:regression);try FileManager.default.copyItem(at:base,to:regression)
        let repo=try Repository(root:regression),before=try repo.load()
        let transcripts=try before.lectures.compactMap{try repo.read($0)},analyses=try AnalysisRepository.readAll(root:regression)
        try repo.writeRecoverySnapshot(before,to:regression.appendingPathComponent("before-v087-test.json"));try repo.save(before)
        #expect(try Repository(root:regression).load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        #expect(try AnalysisRepository.readAll(root:regression)==analyses)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:regression.appendingPathComponent("before-v087-test.json")));try backup.validate()
        #expect(backup.library.lectures.map(\.state)==before.lectures.map(\.state))
        let summary:[String:Int]=["lessons":before.lectures.count,"cues":transcripts.reduce(0){$0+$1.cues.count},"translationsAllVariants":transcripts.reduce(0){$0+$1.allTranslatedCount},"analysisRecords":analyses.count]
        try JSONSerialization.data(withJSONObject:summary,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/private/tmp/LP087/evidence/preservation.json"))
        let gui=URL(fileURLWithPath:"/private/tmp/LP087/gui-data")
        try? FileManager.default.removeItem(at:gui);try FileManager.default.copyItem(at:base,to:gui)
        let qa=try Repository(root:gui);var library=try qa.load()
        library.lastLecture=library.lectures.first{$0.title=="Lecture 9.1"}?.id ?? library.lectures.first?.id
        for i in library.lectures.indices {
            library.lectures[i].bookmark=nil;library.lectures[i].subtitleBookmark=nil
            if library.lectures[i].sources != nil {for j in library.lectures[i].sources!.indices {library.lectures[i].sources![j].bookmark=nil}}
            if let path=library.lectures[i].subtitlePath,FileManager.default.fileExists(atPath:path) {
                let copy=gui.appendingPathComponent("QA-originals/"+library.lectures[i].id.uuidString+"."+URL(fileURLWithPath:path).pathExtension)
                try FileManager.default.createDirectory(at:copy.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(contentsOf:URL(fileURLWithPath:path)).write(to:copy);library.lectures[i].subtitlePath=copy.path
            }
        }
        try qa.save(library)
        print("LP087 preservation",summary)
    }
}
