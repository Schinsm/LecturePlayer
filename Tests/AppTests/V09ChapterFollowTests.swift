import AppKit
import SwiftUI
import Testing
import Core
@testable import LecturePlayer

#if DEBUG // Reads ChapterRowProbe, which exists only in debug builds.
@MainActor private struct FollowHarness: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if store.current != nil { PlayerPage(store:store) }
        else { Text("课程库").frame(maxWidth:.infinity,maxHeight:.infinity) }
    }
}

/// 0.8.11 build 32 located the current chapter on re-entry, but while the lesson kept playing the
/// chapter column stopped following: the highlighted chapter slid below the visible area.
@MainActor @Suite(.serialized) struct V09ChapterFollowTests {
    private func stamp(_ seconds:Double)->String {
        let ms=Int((seconds*1000).rounded())
        return String(format:"00:%02d:%02d.%03d",ms/60000,ms/1000%60,ms%1000)
    }
    private func descendants<T:NSView>(_ root:NSView,_ type:T.Type)->[T] {
        (root as? T).map{[$0]} ?? root.subviews.flatMap{descendants($0,type)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP_RENDER_WINDOW"] == "1"))
    func chapterColumnFollowsAcrossChapterBoundariesWhilePlaying() async throws {
        _=NSApplication.shared
        let (root,fixtureLibrary,_)=try PersistenceTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        var vtt="WEBVTT\n\n"
        for i in 0..<160 {
            let start=Double(i)*0.075
            vtt+="c\(i)\n\(stamp(start)) --> \(stamp(start+0.07))\nLine \(i)\n\n"
        }
        let transcript=try SubtitleParser.parse(Data(vtt.utf8),format:"vtt")
        var library=fixtureLibrary;library.lastLecture=nil
        var lesson=library.lectures[0]
        lesson.transcriptVersion=transcript.version;lesson.state.position=0.2;lesson.state.speed=1;lesson.duration=12
        library.lectures=[lesson]
        let repository=try Repository(root:root)
        try repository.write(transcript,for:lesson.id);try repository.save(library)
        // Eight topics of four 0.375 s chapters each. Real topics hold several chapters, so scrolling to
        // the topic header alone leaves later chapters of that topic below the fold.
        let cues=transcript.cues
        var chapters:[AnalysisChapter]=[],topics:[AnalysisTopic]=[]
        for t in 0..<8 {
            var children:[AnalysisChapter]=[]
            for c in 0..<4 {
                let n=t*4+c
                var chapter=AnalysisChapter(id:"ch\(n)",startCueID:cues[n*5].id,endCueID:cues[n*5+4].id,title:"章节 \(n)",points:(0..<3).map {"要点 \(n)-\($0) "+String(repeating:"展开说明的文字。",count:5)})
                chapter.memberCueIDs=cues[n*5...n*5+4].map(\.id)
                children.append(chapter)
            }
            chapters+=children
            topics.append(AnalysisTopic(id:"t\(t)",title:"主题 \(t)",overview:"概述 \(t) "+String(repeating:"用于撑高目录的说明文字。",count:4),subtopics:children))
        }
        var document=AnalysisDocument(chapters:chapters,overview:[AnalysisOverviewPoint(text:"总结",chapterID:chapters[0].id)]);document.topics=topics
        var record=LessonAnalysis(lessonID:lesson.id,sourceVersion:transcript.version)
        record.completed=document;record.completedConfig=AnalysisConfig(model:"gpt-4o-mini");record.completedAt=Date()
        try await AnalysisRepository(root:root).save(record)

        let store=AppStore(root:root)
        store.readingColumns.show(.chapters);store.readingColumns.show(.transcript)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1300,height:780),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:FollowHarness(store:store));window.contentView=host
        window.orderFrontRegardless()
        defer {store.back();window.orderOut(nil);window.close()}
        store.open(lesson.id)
        try await V04PlaybackTests().wait(store.playback)

        /// The chapter list is the leftmost long scroll view; the current row must lie inside its viewport.
        func visibleCheck()->(Bool,String) {
            host.layoutSubtreeIfNeeded()
            guard let list=descendants(host,NSScrollView.self).filter({($0.documentView?.frame.height ?? 0)>$0.contentView.bounds.height+200 && $0.frame.width>200})
                .min(by:{$0.convert($0.bounds,to:nil).minX<$1.convert($1.bounds,to:nil).minX}) else {return (false,"no list")}
            var viewport=list.convert(list.contentView.frame,to:nil)
            viewport.origin.y=host.bounds.height-viewport.maxY  // to SwiftUI's top-left window space
            let expected="ch\(min(31,Int(store.playback.position/0.375)))"
            guard let (id,row)=ChapterRowProbe.current else {return (false,"no current row, y=\(Int(list.contentView.bounds.minY))")}
            guard id==expected else {return (false,"current row \(id), expected \(expected)")}
            let inside=row.midY>viewport.minY && row.midY<viewport.maxY
            return (inside,"\(id) row=\(Int(row.minY))…\(Int(row.maxY)) viewport=\(Int(viewport.minY))…\(Int(viewport.maxY)) y=\(Int(list.contentView.bounds.minY))")
        }
        func expectFollows(_ label:String) async throws {
            var result=(false,"")
            for _ in 0..<60 {result=visibleCheck();if result.0 {break};try await Task.sleep(for:.milliseconds(50))}
            print("FOLLOW \(label) \(result.1)")
            #expect(result.0,"\(label): current chapter must stay visible, got \(result.1)")
        }

        try await expectFollows("start")
        // Jumps that cross many chapter boundaries, forwards and backwards.
        for (seconds,label) in [(2.8,"seek ch7"),(5.9,"seek ch15"),(10.3,"seek ch27"),(4.4,"back ch11"),(11.8,"seek ch31")] {
            store.playback.seek(seconds)
            try await expectFollows(label)
        }
        // Continuous playback through several chapters and a topic boundary.
        store.playback.seek(1.6)
        store.playback.toggle()
        try await Task.sleep(for:.milliseconds(2600))
        // The fixture changes chapter every 0.375 s; stop before checking so a loaded machine is not racing the clock.
        store.playback.pause()
        try await expectFollows("after playing")
    }
}
#endif
