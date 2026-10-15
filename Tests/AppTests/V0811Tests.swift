import AppKit
import AVFoundation
import SwiftUI
import Testing
import Core
@testable import LecturePlayer

@MainActor private struct PlaybackNavigationHarness: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if store.current != nil { PlayerPage(store:store) }
        else { Text("课程库").frame(maxWidth:.infinity,maxHeight:.infinity) }
    }
}
@MainActor @Suite(.serialized) struct V0811Tests {
    private func descendants<T:NSView>(_ root:NSView, _ type:T.Type)->[T] {
        (root as? T).map{[$0]} ?? root.subviews.flatMap{descendants($0,type)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP_RENDER_WINDOW"] == "1"))
    func actualPlayerPageReceivesAsynchronousMediaAndReopens() async throws {
        _=NSApplication.shared
        let (root,varLibrary,transcript)=try PersistenceTests().fixture()
        var library=varLibrary; library.lastLecture=nil
        let original=library.lectures[0]
        library.lectures=(0..<3).map {index in
            var lesson=original;lesson.id=UUID();lesson.title="Synthetic \(index+1)";lesson.state.position=Double(index+1)
            if index>0 {lesson.sources=[MediaSource(role:.screen,path:lesson.path),MediaSource(role:.camera,path:lesson.path)]}
            lesson.layout = index==0 ? .screen : index==1 ? .horizontal : .inset
            return lesson
        }
        let repo=try Repository(root:root)
        for lesson in library.lectures {try repo.write(transcript,for:lesson.id)};try repo.save(library)
        let store=AppStore(root:root)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:1250,height:780),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:PlaybackNavigationHarness(store:store));window.contentView=host
        window.orderFrontRegardless()
        defer {store.back();window.orderOut(nil);window.close()}
        for iteration in 0..<20 {
            let lesson=library.lectures[iteration%3]
            store.open(lesson.id)
            try await V04PlaybackTests().wait(store.playback)
            try await Task.sleep(for:.milliseconds(500))
            let canvas=try #require(descendants(host,VideoCanvas.Canvas.self).first)
            print("PAGE_MOUNT \(iteration) modelSources=\(store.playback.views.count) canvasSources=\(canvas.sources.count) frame=\(canvas.frame) child=\(canvas.videos[0].frame) hidden=\(canvas.videos[0].isHidden) bound=\(canvas.videos[0].playerLayer.player != nil)")
            #expect(canvas.sources.map(\.id)==store.playback.views.map(\.id))
            #expect(canvas.videos[0].playerLayer.player === store.playback.player)
            #expect(!canvas.videos[0].isHidden && canvas.videos[0].bounds.width>0)
            for _ in 0..<100 {
                if canvas.videos.prefix(lesson.mediaSources.count).allSatisfy({$0.isReadyForDisplay}) {break}
                try await Task.sleep(for:.milliseconds(50))
            }
            for (i,source) in store.playback.views.enumerated() {
                let surface=canvas.videos[i]
                #expect(surface.isReadyForDisplay && !surface.visibleRect.isEmpty)
                let item=try #require(store.playback.player(for:source).currentItem)
                #expect(store.playback.hasCurrentItemFrame(sourceID:source.id,generation:store.playback.displayGeneration,item:item))
                #expect(surface.rebuildCount==0,"Routine entry must not need automatic surface recovery")
            }
            #expect(store.lecture?.layout==lesson.layout)
            if iteration%2==1 {
                store.playback.toggle()
                for _ in 0..<100 {if store.playback.playing {break};try await Task.sleep(for:.milliseconds(20))}
                let snapshot=store.playback.videoPresentation,position=store.playback.position
                try await Task.sleep(for:.milliseconds(300))
                #expect(store.playback.position>position)
                #expect(store.playback.videoPresentation==snapshot,"Clock ticks must not invalidate media presentation")
                store.playback.pause()
            }
            store.back();try await Task.sleep(for:.milliseconds(100))
        }
    }
}

@MainActor @Suite(.serialized) struct V0811LayoutTests {
    func settings()->(UserDefaults,String) {let name="LP0811.Columns."+UUID().uuidString;return(UserDefaults(suiteName:name)!,name)}
    func settle(_ condition:()->Bool)async throws {
        for _ in 0..<100 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        #expect(condition())
    }
    @Test func rapidResizeAndLastPaneRestore()async throws {
        let (defaults,name)=settings();defer{defaults.removePersistentDomain(forName:name)}
        let columns=ReadingColumns(defaults:defaults)
        columns.updateWidth(1000);columns.updateWidth(1300)
        try await Task.sleep(for:.milliseconds(30));#expect(!columns.compact)
        columns.hide(.chapters);columns.hide(.transcript)
        #expect(!columns.value.enabled)
        columns.toggleAll()
        #expect(!columns.visible(.chapters) && columns.visible(.transcript))
    }
    @Test func responsiveColumnsRestorePreferencesAndRemainIndependent()async throws {
        let (defaults,name)=settings();defer{defaults.removePersistentDomain(forName:name)}
        let columns=ReadingColumns(defaults:defaults)
        let saved=columns.value
        columns.updateWidth(1000);try await settle {columns.compact}
        #expect(columns.visible(.transcript) && !columns.visible(.chapters))
        #expect(columns.value==saved)
        columns.selectNarrow(.chapters);#expect(columns.visible(.chapters) && !columns.visible(.transcript))
        columns.updateWidth(1140);#expect(columns.compact)
        columns.updateWidth(1200);try await settle {!columns.compact};#expect(!columns.compact && columns.visible(.chapters) && columns.visible(.transcript))
        columns.hide(.chapters);columns.toggleAll();columns.toggleAll()
        #expect(!columns.visible(.chapters) && columns.visible(.transcript))
        columns.resize(chapters:340,transcript:380);columns.flush()
        #expect(ReadingColumns(defaults:defaults).value==columns.value)
    }
    @Test func legacyHiddenSettingAndThreeColumnGeometry()async throws {
        let (defaults,name)=settings();defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:"readerPaneVisible")
        let columns=ReadingColumns(defaults:defaults);#expect(!columns.value.enabled)
        let split=ReadingColumnsSplit(columns:columns)
        let delegate=ReadingColumnsSplit.Delegate(split);split.delegate=delegate
        for _ in 0..<3 {split.addArrangedSubview(NSView())}
        split.frame=CGRect(x:0,y:0,width:1300,height:700);split.applyLayout()
        #expect(split.arrangedSubviews[0].frame.width==1300)
        columns.toggleAll();split.applyLayout()
        #expect(split.arrangedSubviews[1].frame.width==300 && split.arrangedSubviews[2].frame.width==360)
        let expected=split.arrangedSubviews.map(ObjectIdentifier.init)
        columns.hide(.chapters);split.applyLayout()
        #expect(split.arrangedSubviews[1].isHidden && split.arrangedSubviews[1].frame.width==0)
        #expect(split.arrangedSubviews[2].frame.maxX==1300)
        columns.show(.chapters);split.applyLayout()
        #expect(split.arrangedSubviews.map(ObjectIdentifier.init)==expected)
        split.setPosition(700,ofDividerAt:0)
        #expect(abs(split.arrangedSubviews[0].frame.width-700)<2)
        columns.flush()
    }
    @Test func speedLabelUsesSeparateVerticallyCenteredSymbol() {
        let button=SpeedAnchorButton(frame:CGRect(x:0,y:0,width:80,height:24))
        button.speed=1.25;button.updateLabel();button.layoutSubtreeIfNeeded()
        let label=button.subviews.compactMap{$0 as? NSTextField}.first
        let arrow=button.subviews.compactMap{$0 as? NSImageView}.first
        #expect(label?.stringValue=="1.25×" && arrow?.image != nil)
        #expect(abs((label?.frame.midY ?? 0)-(arrow?.frame.midY ?? 100))<=1)
        #expect(button.title.isEmpty)
    }
}
