import AppKit
import SwiftUI
import Testing
import Core
@testable import LecturePlayer

@MainActor private struct ReentryHarness: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if store.current != nil { PlayerPage(store:store) }
        else { Text("课程库").frame(maxWidth:.infinity,maxHeight:.infinity) }
    }
}

/// GUI acceptance found these after 0.8.11 build 31: reading columns stayed at the top when a
/// lesson was reopened, and a lesson whose media failed kept the previous lesson's duration.
@MainActor @Suite(.serialized) struct V0811ReentryTests {
    private func descendants<T:NSView>(_ root:NSView, _ type:T.Type)->[T] {
        (root as? T).map{[$0]} ?? root.subviews.flatMap{descendants($0,type)}
    }
    private func stamp(_ seconds:Double)->String {
        let ms=Int((seconds*1000).rounded())
        return String(format:"00:%02d:%02d.%03d",ms/60000,ms/1000%60,ms%1000)
    }

    @Test func failedLoadShowsItsOwnRecordedDurationNotThePreviousLesson() async throws {
        let (root,library,_)=try PersistenceTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let player=Playback()
        defer {player.close()}
        player.load(library.lectures[0])
        try await V04PlaybackTests().wait(player)
        #expect(abs(player.duration-12)<0.2)
        var broken=library.lectures[0];broken.id=UUID();broken.duration=4321
        broken.sources=[MediaSource(role:.screen,path:root.appendingPathComponent("missing.mp4").path)]
        player.load(broken)
        for _ in 0..<200 {if player.phase == .failed {break};try await Task.sleep(for:.milliseconds(25))}
        #expect(player.phase == .failed)
        #expect(player.duration==4321,"A failed lesson must not keep the previous lesson's duration")
        player.close()
        #expect(player.duration==0)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP_RENDER_WINDOW"] == "1"))
    func readingColumnsLocateCurrentPositionOnEveryReentry() async throws {
        _=NSApplication.shared
        let (root,fixtureLibrary,_)=try PersistenceTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        var vtt="WEBVTT\n\n"
        for i in 0..<160 {
            let start=Double(i)*0.075
            vtt+="c\(i)\n\(stamp(start)) --> \(stamp(start+0.07))\nLine \(i) "+String(repeating:"long reading text ",count:8)+"\n\n"
        }
        let transcript=try SubtitleParser.parse(Data(vtt.utf8),format:"vtt")
        var library=fixtureLibrary;library.lastLecture=nil
        var lesson=library.lectures[0]
        lesson.transcriptVersion=transcript.version;lesson.state.position=11;lesson.state.speed=1;lesson.duration=12
        library.lectures=[lesson]
        let repository=try Repository(root:root)
        try repository.write(transcript,for:lesson.id);try repository.save(library)
        // Twenty topics of one chapter each; position 11 s falls in topic 18, far below the fold.
        let cues=transcript.cues
        var chapters:[AnalysisChapter]=[],topics:[AnalysisTopic]=[]
        for t in 0..<20 {
            var chapter=AnalysisChapter(id:"ch\(t)",startCueID:cues[t*8].id,endCueID:cues[t*8+7].id,title:"章节 \(t)",points:["要点 \(t)a","要点 \(t)b","要点 \(t)c"])
            chapter.memberCueIDs=cues[t*8...t*8+7].map(\.id)
            chapters.append(chapter)
            topics.append(AnalysisTopic(id:"t\(t)",title:"主题 \(t)",overview:"概述 \(t) "+String(repeating:"用于撑高目录的说明文字。",count:6),subtopics:[chapter]))
        }
        var document=AnalysisDocument(chapters:chapters,overview:[AnalysisOverviewPoint(text:"总结",chapterID:chapters[0].id)]);document.topics=topics
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:transcript.version)
        record.completed=document;record.completedConfig=AnalysisConfig(model:"gpt-4o-mini");record.completedAt=Date()
        try await AnalysisRepository(root:root).save(record)

        let store=AppStore(root:root)
        store.readingColumns.show(.chapters);store.readingColumns.show(.transcript)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1300,height:780),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:ReentryHarness(store:store));window.contentView=host
        window.orderFrontRegardless()
        defer {store.back();window.orderOut(nil);window.close()}

        for iteration in 0..<3 {
            store.open(lesson.id)
            try await V04PlaybackTests().wait(store.playback)
            var located=false
            var report=""
            for _ in 0..<80 {
                host.layoutSubtreeIfNeeded()
                // Long reading lists only; ordered left to right: chapters, then transcript.
                let lists=descendants(host,NSScrollView.self).filter {
                    ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height+400 && $0.frame.width>200
                }.sorted {$0.convert($0.bounds,to:nil).minX < $1.convert($1.bounds,to:nil).minX}
                report=lists.map {"y=\(Int($0.contentView.bounds.minY))/h=\(Int($0.documentView?.frame.height ?? 0))"}.joined(separator:" ")
                if lists.count==2, lists.allSatisfy({ $0.contentView.bounds.minY > ($0.documentView?.frame.height ?? 0)*0.4 }) {located=true;break}
                try await Task.sleep(for:.milliseconds(50))
            }
            print("REENTRY \(iteration) \(report)")
            #expect(located,"Entry \(iteration): chapters and transcript must scroll to the current position, got \(report)")
            store.back();try await Task.sleep(for:.milliseconds(150))
        }
    }
}
