import AppKit
import SwiftUI
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct ReaderHandleTests {
    @Test func hoverDelayCancellationAndFocusDoNotPersist() async throws {
        let state=ReaderHandleVisibility(delay:.milliseconds(25));var changes:[Bool]=[]
        state.changed={changes.append($0)}
        #expect(!state.revealed)
        state.hover(true);#expect(state.revealed)
        state.hover(false);#expect(state.revealed)
        state.hover(true)
        try await Task.sleep(for:.milliseconds(45));#expect(state.revealed && changes==[true])
        state.hover(false);state.focus(true)
        try await Task.sleep(for:.milliseconds(45));#expect(state.revealed)
        state.focus(false);state.accessibilityFocus(true)
        try await Task.sleep(for:.milliseconds(45));#expect(state.revealed)
        state.accessibilityFocus(false)
        for _ in 0..<100 {if !state.revealed {break};try await Task.sleep(for:.milliseconds(20))};#expect(!state.revealed && changes==[true,false])
        state.hover(true);state.hover(false);state.reset()
        try await Task.sleep(for:.milliseconds(45));#expect(!state.revealed)
    }
    @Test func hostAnchorsToVideoAndOnlyVisibleButtonInterceptsClicks() {
        _=NSApplication.shared
        let split=StudySplit<Text,Text>.Split(frame:NSRect(x:0,y:0,width:1200,height:700))
        split.isVertical=true;let delegate=StudySplit<Text,Text>.SplitDelegate(split);split.delegate=delegate
        defer {withExtendedLifetime(delegate){}}
        let left=NSView(),right=NSView();split.addArrangedSubview(left);split.addArrangedSubview(right)
        let host=ReaderSplitContainer(split:split);host.frame=split.frame
        split.layout();split.setPosition(740,ofDividerAt:0)
        let marker=VideoEdgeMarker(frame:NSRect(x:10,y:90,width:710,height:580));left.addSubview(marker)
        host.layout()
        let edge=host.convert(left.bounds,from:left).maxX
        #expect(host.handle.frame.maxX==edge)
        #expect(host.handle.frame.midY==host.convert(marker.bounds,from:marker).midY)
        #expect(host.sensingRect.width==48 && host.sensingRect.height==112)
        let center=NSPoint(x:edge-12,y:host.handle.frame.midY)
        #expect(host.hitTest(center) !== host.handle)
        host.handle.visibility.hover(true)
        #expect(host.hitTest(center) === host.handle)
        #expect(host.hitTest(NSPoint(x:edge-35,y:center.y)) !== host.handle)
        #expect(host.hitTest(NSPoint(x:edge-1,y:center.y)) !== host.handle)
        var clicks=0;host.configure(visible:true,toggle:{clicks += 1});host.handle.performClick(nil);#expect(clicks==1)
        let width=left.frame.width
        split.setRightVisible(false);host.configure(visible:false,toggle:{clicks += 1});host.layout()
        #expect(host.handle.frame.maxX==host.bounds.maxX && split.dividerThickness==0)
        #expect(split.arrangedSubviews.count==2 && split.arrangedSubviews[1] === right)
        host.frame.size.width=1400;host.layout();#expect(host.handle.frame.maxX==1400)
        host.frame.size.width=1200;host.layout();split.setRightVisible(true);host.layout()
        print("handle-width",width,left.frame.width,split.expandedRatio,split.frame.width)
        #expect(abs(left.frame.width-width)<2)
        host.handle.visibility.reset();#expect(host.hitTest(NSPoint(x:host.handle.frame.midX,y:host.handle.frame.midY)) !== host.handle)
    }
    @Test func keyboardAndAccessibilityCanRevealHiddenControl() {
        _=NSApplication.shared
        let button=ReaderPaneToggle(frame:NSRect(x:0,y:0,width:24,height:56))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView?.addSubview(button)
        defer{window.close()}
        #expect(window.makeFirstResponder(button));#expect(button.visibility.revealed)
        let keys=PlayerKeys.KeysView();window.contentView?.addSubview(keys);var transportCalls=0;keys.action={_,_ in transportCalls += 1;return true}
        let space=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        #expect(keys.handle(space) == nil && transportCalls==1)
        #expect(window.makeFirstResponder(nil));button.visibility.reset()
        button.setAccessibilityFocused(true);#expect(button.visibility.revealed)
        #expect(button.accessibilityLabel()=="隐藏转写与章节")
        button.readerVisible=false;#expect(button.accessibilityLabel()=="显示转写与章节")
    }
}

@MainActor @Suite(.serialized) struct ReaderHandleAcceptance {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP0871_ACCEPTANCE"]=="1"))
    func latestIsolatedSnapshotPreservedAndPrepareGUI() throws {
        let base=URL(fileURLWithPath:"/private/tmp/LP0871/baseline-data"),root=URL(fileURLWithPath:"/private/tmp/LP0871/regression-data")
        try? FileManager.default.removeItem(at:root);try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root),before=try repo.load()
        let transcripts=try before.lectures.compactMap{try repo.read($0)},analyses=try AnalysisRepository.readAll(root:root)
        try repo.save(before);#expect(try Repository(root:root).load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        let summary=["lessons":before.lectures.count,"cues":transcripts.reduce(0){$0+$1.cues.count},"translations":transcripts.reduce(0){$0+$1.allTranslatedCount},"analyses":analyses.count]
        try JSONSerialization.data(withJSONObject:summary,options:.prettyPrinted).write(to:URL(fileURLWithPath:"/private/tmp/LP0871/evidence/preservation.json"))
        let gui=URL(fileURLWithPath:"/private/tmp/LP0871/gui-data")
        try? FileManager.default.removeItem(at:gui);try FileManager.default.copyItem(at:base,to:gui)
        let qa=try Repository(root:gui);var library=try qa.load()
        let sample=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Synthetic.mp4")
        let target=gui.appendingPathComponent("QA-Synthetic.mp4");try FileManager.default.copyItem(at:sample,to:target)
        library.lastLecture=library.lectures.first{$0.title=="Lecture 9.3"}?.id ?? library.lectures.first?.id
        // Latest reading data, synthetic media: no original media or sidecar paths are writable by QA.
        library.directoryRoot=nil;library.directoryBookmark=nil
        for i in library.lectures.indices {
            library.lectures[i].path=target.path;library.lectures[i].bookmark=nil;library.lectures[i].subtitlePath=nil;library.lectures[i].subtitleBookmark=nil
            library.lectures[i].state.position=3
            if library.lectures[i].sources != nil {for j in library.lectures[i].sources!.indices {library.lectures[i].sources![j].path=target.path;library.lectures[i].sources![j].bookmark=nil}}
        }
        try qa.save(library)
    }
}
