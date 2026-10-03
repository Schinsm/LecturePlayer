import AppKit
import AVFoundation
import Testing
import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V0891Tests {
    @Test func lostReadinessDoesNotRemainPermanentlySuccessful() {
        let g=UUID(), b=UUID()
        var state=VideoFirstFrameState(generation:g,binding:b)
        let transition1 = state.observe(generation:g,binding:b,eligible:true,hasFrame:true,now:0)
        #expect(!transition1)
        #expect(state.status == .ready)
        let transition2 = state.observe(generation:g,binding:b,eligible:true,hasFrame:false,now:1)
        #expect(!transition2)
        #expect(state.status == .waiting)
        let transition3 = state.observe(generation:g,binding:b,eligible:true,hasFrame:false,now:6.1)
        #expect(transition3)
        let transition4 = state.observe(generation:g,binding:b,eligible:true,hasFrame:true,now:6.2)
        #expect(!transition4)
        #expect(state.status == .ready)
        let transition5 = state.observe(generation:g,binding:b,eligible:true,hasFrame:false,now:7)
        #expect(!transition5)
        let transition6 = state.observe(generation:g,binding:b,eligible:true,hasFrame:false,now:13)
        #expect(!transition6)
        #expect(state.status == .failed) // one automatic repair, never a seek loop
    }
    @Test func surfaceWaitsForMountAndBoundsThenDetachesWithoutTransportChanges() {
        _=NSApplication.shared
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let surface=VideoSurface(frame:.zero)
        let player=AVPlayer(playerItem:AVPlayerItem(url:URL(fileURLWithPath:"/missing-fixture.mp4")))
        surface.player=player
        #expect(surface.playerLayer.player == nil)
        window.contentView?.addSubview(surface)
        #expect(surface.playerLayer.player == nil)
        surface.frame=CGRect(x:0,y:0,width:400,height:300)
        #expect(surface.playerLayer.player === player)
        #expect(surface.playerLayer.frame == surface.bounds)
        let attachmentCount=surface.attachmentCount
        for _ in 0..<20 {surface.player=player;surface.layout()}
        #expect(surface.attachmentCount == attachmentCount)
        surface.removeFromSuperview()
        #expect(surface.playerLayer.player == nil && player.currentItem != nil)
        window.contentView?.addSubview(surface)
        #expect(surface.playerLayer.player === player)
        surface.setPresentationEnabled(false)
        #expect(surface.playerLayer.player == nil)
        surface.setPresentationEnabled(true)
        #expect(surface.playerLayer.player === player)
        surface.detach()
        #expect(surface.playerLayer.player == nil && surface.player == nil)
        #expect(player.currentItem != nil && player.rate == 0)
    }
    @Test func renderingRepairRetainsItemPositionSpeedAndDoesNotSeekOrSave() async throws {
        _=NSApplication.shared
        let (_,lib,_)=try PersistenceTests().fixture()
        let playback=Playback();defer{playback.close()}
        playback.load(lib.lectures[0]);try await V04PlaybackTests().wait(playback)
        let defaults=UserDefaults(suiteName:"LP0891."+UUID().uuidString)!
        let prefs=PictureInPicturePreferences(defaults:defaults)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let canvas=VideoCanvas.Canvas(frame:CGRect(x:0,y:0,width:800,height:500))
        window.contentView=canvas
        canvas.configure(playback,layout:.screen,swapped:false,preferences:prefs);canvas.layout()
        let oldLayer=canvas.videos[0].playerLayer, item=playback.player.currentItem
        let time=playback.player.currentTime().seconds
        var writes=0,seeks=0
        playback.save={_,_,_ in writes += 1}
        playback.seekCommand={_,_,done in seeks += 1;done(true)}
        defer{playback.save=nil;playback.seekCommand=nil}
        canvas.videos[0].rebuildPresentation()
        #expect(oldLayer.player == nil && oldLayer.superlayer == nil)
        #expect(canvas.videos[0].playerLayer !== oldLayer)
        #expect(canvas.videos[0].playerLayer.player === playback.player)
        #expect(playback.player.currentItem === item && playback.player.rate == 0)
        #expect(abs(playback.player.currentTime().seconds-time)<0.05)
        #expect(writes==0 && seeks==0)
        canvas.tearDown()
        #expect(canvas.videos.allSatisfy{$0.player==nil && $0.playerLayer.player==nil})
        #expect(playback.player.currentItem === item)
    }
    @Test func contextMenuUsesCurrentSavedAndPendingAnalysisState() async throws {
        let(store,source)=try V052AppTests().fixture()
        defer{try? FileManager.default.removeItem(at:store.repository!.root)}
        let lesson=store.library.lectures[0]
        let action=LessonAnalysisMenuAction(store:store,lesson:lesson){}
        #expect(action.availability.action=="生成总结…")
        let chapter=AnalysisChapter(id:"one",startCueID:source.cues.first!.id,endCueID:source.cues.last!.id,title:"保存章节",points:["要点"])
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:source.version)
        record.completed=AnalysisDocument(chapters:[chapter],overview:[AnalysisOverviewPoint(text:"总结",chapterID:chapter.id)])
        record.completedConfig=AnalysisConfig(model:"gpt-4o-mini");record.completedAt=Date()
        store.analysis.accept(record)
        #expect(action.availability.action=="重新生成…")
        var task=AnalysisTaskState(config:AnalysisConfig(model:"gpt-4o-mini"),plan:try AnalysisPlan.make(source))
        task.status = .failed;record.task=task;store.analysis.accept(record)
        #expect(action.availability.action=="继续总结…")
        #expect(store.analysis.exact(lesson.id,version:source.version)?.completed != nil)
        #expect(!store.analysis.running)
    }
}
