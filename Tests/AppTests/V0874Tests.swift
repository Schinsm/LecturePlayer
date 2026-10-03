import Foundation
import AVFoundation
import Combine
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V0874Tests {
    func fixture() throws -> (URL, Library, Transcript) {
        let (root, library, t) = try PersistenceTests().fixture()
        let r=try Repository(root:root);try r.write(t,for:library.lectures[0].id);try r.save(library)
        return(root,library,t)
    }
    @Test func missingDuplicatedAndCancelledCallbacksResolveOnce() async throws {
        let start=Date()
        #expect(await PlaybackCallback.wait(seconds:0.03) { _ in } == false)
        #expect(Date().timeIntervalSince(start)<2)
        #expect(await PlaybackCallback.wait {done in done(true);done(false)} == true)
        let task=Task {await PlaybackCallback.wait(seconds:5) {_ in}}
        task.cancel(); #expect(await task.value == false)
        let late=await PlaybackCallback.wait(seconds:0.01) { done in DispatchQueue.global().asyncAfter(deadline:.now()+0.04){done(true)} }
        #expect(late == false);try await Task.sleep(for:.milliseconds(60))
    }
    @Test func driftRequiresPersistenceAndCooldown() {
        var policy=PlaybackDriftPolicy();let id=UUID()
        let check0=policy.needsCorrection(id:id,drift:0.2,now:0);#expect(!check0)
        let check1=policy.needsCorrection(id:id,drift:0.4,now:1);#expect(!check1)
        let check2=policy.needsCorrection(id:id,drift:0.4,now:1.29);#expect(!check2)
        let check3=policy.needsCorrection(id:id,drift:0.4,now:1.31);#expect(check3)
        let check4=policy.needsCorrection(id:id,drift:0.4,now:2);#expect(!check4)
        let check5=policy.needsCorrection(id:id,drift:0.4,now:3);#expect(!check5)
        let check6=policy.needsCorrection(id:id,drift:0.4,now:3.32);#expect(check6)
    }
    @Test func failedSeekMissingPrerollAndPauseRecover() async throws {
        let (_,library,_)=try fixture();let p=Playback();defer{p.close()}
        p.player.isMuted=true;p.load(library.lectures[0]);try await V04PlaybackTests().wait(p)
        p.seekCommand={_,_,done in done(false)};p.seek(3)
        for _ in 0..<100 {if p.phase == .failed {break};try await Task.sleep(for:.milliseconds(20))};#expect(p.phase == .failed);#expect(!p.waiting)
        p.seekCommand=nil;p.seek(4)
        try await Task.sleep(for:.milliseconds(150));#expect(abs(p.position-4)<0.1)
        p.commandTimeout=0.05;p.prerollCommand={_,_,_ in};p.toggle()
        for _ in 0..<100 {if p.phase == .failed {break};try await Task.sleep(for:.milliseconds(20))};#expect(p.phase == .failed);#expect(!p.playing)
        p.commandTimeout=5;p.prerollCommand=nil;p.toggle()
        for _ in 0..<100 {if p.playing {break};try await Task.sleep(for:.milliseconds(20))};#expect(p.playing)
        let old=p.position;try await Task.sleep(for:.milliseconds(250));#expect(p.position>old)
        p.seekCommand={_,_,_ in};p.seek(2);p.pause()
        try await Task.sleep(for:.milliseconds(100));#expect(p.phase == .paused);#expect(!p.waiting)
        p.seekCommand=nil;p.seek(5);try await Task.sleep(for:.milliseconds(150));#expect(abs(p.position-5)<0.1)
    }
    @Test func lateSeekCannotChangeNewLesson() async throws {
        let (_,library,_)=try fixture();let p=Playback();defer{p.close()}
        p.load(library.lectures[0]);try await V04PlaybackTests().wait(p)
        var completion:((Bool)->Void)?
        p.seekCommand={_,_,done in completion=done};p.seek(2)
        await Task.yield();try await Task.sleep(for:.milliseconds(30))
        var next=library.lectures[0];next.id=UUID();next.state.position=6
        p.seekCommand=nil;p.load(next);completion?(true);try await V04PlaybackTests().wait(p)
        #expect(p.lectureID==next.id);#expect(abs(p.position-6)<0.1)
    }
    @Test func readingCacheInvalidatesWithoutGlobalLockAndKeepsThreeLessons() async throws {
        let(root,library,t)=try fixture();let loader=LessonLoadCoordinator();let r=try Repository(root:root);let lesson=library.lectures[0]
        let first=try await loader.load(lesson,root:root),second=try await loader.load(lesson,root:root)
        #expect(first.reading.revision==second.reading.revision)
        var edited=t;edited.translations[t.cues[0].id]=Translation(ai:"测试",cacheKey:"mock")
        try r.write(edited,for:lesson.id)
        let updated=try await loader.load(lesson,root:root)
        #expect(updated.reading.revision != first.reading.revision);#expect(updated.transcript?.translations == edited.translations)
        for _ in 0..<3 {var next=lesson;next.id=UUID();try r.write(t,for:next.id);_ = try await loader.load(next,root:root)}
        let evicted=try await loader.load(lesson,root:root);#expect(evicted.reading.revision != updated.reading.revision)
        await loader.clear()
        // A writer held on another thread must not delay an atomic snapshot read.
        let locked=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        DispatchQueue.global().async {TranscriptTransactions.lock.lock();locked.signal();release.wait();TranscriptTransactions.lock.unlock()}
        locked.wait()
        let loading=Task.detached {defer{release.signal()};return try await loader.load(lesson,root:root)}
        _ = try await loading.value
    }
    @Test func slowOpenImmediateStateAndLastSelectionWins() async throws {
        let(root,original,t)=try fixture();var library=original;var next=library.lectures[0];next.id=UUID();next.title="Second";next.state.position=2;library.lectures.append(next);library.lastLecture=nil
        let r=try Repository(root:root);try r.write(t,for:next.id);try r.save(library)
        let store=AppStore(root:root);defer{store.playback.close()}
        await store.lessonLoader.setReader {url in Thread.sleep(forTimeInterval:0.2);return try Data(contentsOf:url)}
        let start=Date();store.open(library.lectures[0].id)
        #expect(store.current==library.lectures[0].id && store.lessonLoading);#expect(Date().timeIntervalSince(start)<0.1)
        store.open(next.id)
        for _ in 0..<100 {if !store.lessonLoading{break};try await Task.sleep(for:.milliseconds(20))}
        #expect(store.current==next.id);#expect(store.transcript?.version==t.version);#expect(store.preparedReading != nil)
        try await store.repository?.commits.flushAsync();#expect(try r.load().lastLecture==next.id)
    }
    @Test func orderedAsyncMetadataFlushPreservesFields() async throws {
        let(root,library,_)=try fixture();let r=try Repository(root:root);let initial=library.lectures[0]
        var a=initial;a.state.position=4;var b=a;b.state.speed=2
        r.commits.submit(old:initial,new:a){_ in};r.commits.submit(old:a,new:b){_ in};r.commits.setLastLesson(initial.id){_ in}
        try await r.commits.flushAsync();let loaded=try r.load()
        #expect(loaded.lectures[0].state.position==4);#expect(loaded.lectures[0].state.speed==2)
    }
    @Test func clockTicksDoNotInvalidatePlaybackRoot() async throws {
        let(_,library,_)=try fixture();let p=Playback();defer{p.close()};p.player.isMuted=true
        p.load(library.lectures[0]);try await V04PlaybackTests().wait(p);p.seek(2);try await Task.sleep(for:.milliseconds(100));p.toggle()
        try await Task.sleep(for:.milliseconds(400))
        var roots=0,ticks=0;let a=p.objectWillChange.sink{roots += 1};let b=p.clock.$snapshot.sink{_ in ticks += 1}
        try await Task.sleep(for:.milliseconds(600))
        #expect(ticks>=3);#expect(roots==0);a.cancel();b.cancel()
    }
}

@Suite(.serialized) @MainActor struct V0874Acceptance {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP0874_LONG"] == "1"))
    func continuousDualThirtyMinutes() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/LP0874/baseline-data")
        let r=try Repository(root:root),library=try r.load()
        var lesson=try #require(library.lectures.first{ $0.mediaSources.count==2 && $0.duration>2400 })
        lesson.bookmark=nil
        var sources=lesson.mediaSources;for i in sources.indices {sources[i].bookmark=nil};lesson.mediaSources=sources
        lesson.state.position=30;lesson.state.speed=1
        let p=Playback(preferences:UserDefaults(suiteName:"LP0874.LongRun")!);defer{p.close()}
        p.player.isMuted=true;p.secondaryPlayer.isMuted=true
        let t=try #require(try r.read(lesson));let timeline=TranscriptTimeline(t.cues)
        p.load(lesson);try await V04PlaybackTests().wait(p);p.toggle()
        for _ in 0..<100 {if p.playing{break};try await Task.sleep(for:.milliseconds(50))}
        try #require(p.playing)
        let started=Date();var samples:[[String:Double]]=[];var maxAge=0.0,maxDrift=0.0
        var updates=0;let sink=p.clock.$snapshot.sink{_ in updates += 1};defer{sink.cancel()}
        while Date().timeIntervalSince(started)<1800 {
            try await Task.sleep(for:.milliseconds(200))
            let audio=p.audioID.flatMap{id in p.views.first{$0.id==id}} ?? p.views[0]
            let primary=p.player,secondary=p.secondaryPlayer
            let measured=await Task.detached { (primary.currentTime().seconds,secondary.currentTime().seconds) }.value
            let actual=(audio.id==p.views[0].id ? measured.0:measured.1)-audio.relativeOffset
            let age=abs(actual-p.position),drift=abs(measured.0-measured.1 + p.views[1].relativeOffset-p.views[0].relativeOffset)
            maxAge=max(maxAge,age);maxDrift=max(maxDrift,drift)
            let cueCount=timeline.active(at:p.position,mapper:lesson.state.timingMapper).count
            samples.append(["elapsed":Date().timeIntervalSince(started),"actual":actual,"snapshot":p.position,"age":age,"drift":drift,"cues":Double(cueCount),"corrections":Double(p.correctionCount)])
            if samples.count % 150 == 0 {
                print("LONG_RUN \(Int(Date().timeIntervalSince(started)))s age=\(maxAge) drift=\(maxDrift)")
                try JSONSerialization.data(withJSONObject:["elapsed":Date().timeIntervalSince(started),"maxAge":maxAge,"maxDrift":maxDrift,"updates":updates,"corrections":p.correctionCount,"lastSample":samples.last ?? [:]],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP0874/long-progress.json"),options:.atomic)
            }
            #expect(p.playing && !p.waiting)
        }
        #expect(maxAge<0.5);#expect(p.position>1800)
        try JSONSerialization.data(withJSONObject:["elapsed":Date().timeIntervalSince(started),"maxAge":maxAge,"maxDrift":maxDrift,"updates":updates,"corrections":p.correctionCount,"samples":samples],options:[.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP0874/long-run.json"),options:.atomic)
    }
}
