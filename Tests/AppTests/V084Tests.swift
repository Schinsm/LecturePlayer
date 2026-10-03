import AppKit
import Core
import Testing
@testable import LecturePlayer

@MainActor @Suite("0.8.4 keyboard, follow emphasis and chapter location",.serialized)
struct V084Tests {
    private func window()->NSWindow {
        _=NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;return window
    }
    private func key(_ code:UInt16,window:NSWindow,modifiers:NSEvent.ModifierFlags=[],repeatKey:Bool=false)throws->NSEvent {
        try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:repeatKey,keyCode:code))
    }
    @Test func readonlyTranscriptSpaceWorksWithoutLosingSelectionButEditorAndArrowsStayNative() throws {
        let window=window(),keys=PlayerKeys.KeysView(frame:.zero)
        let text=NSTextView(frame:NSRect(x:0,y:0,width:400,height:200))
        text.isEditable=false;text.isSelectable=true;text.string="cash flow evidence"
        window.contentView?.addSubview(keys);window.contentView?.addSubview(text)
        defer{keys.removeFromSuperview();text.removeFromSuperview();window.close()}
        var calls=0;keys.action={_,_ in calls += 1;return true}
        #expect(window.makeFirstResponder(text));text.setSelectedRange(NSRange(location:0,length:4))
        #expect(keys.handle(try key(49,window:window))==nil);#expect(calls==1)
        #expect(text.selectedRange()==NSRange(location:0,length:4))
        let arrow=try key(123,window:window);#expect(keys.handle(arrow) === arrow);#expect(calls==1)
        _=keys.handle(try key(49,window:window,repeatKey:true));#expect(calls==1)
        text.isEditable=true
        let typing=try key(49,window:window);#expect(keys.handle(typing) === typing);#expect(calls==1)
        text.isEditable=false;text.setSelectedRange(NSRange(location:0,length:0))
        #expect(keys.handle(try key(123,window:window))==nil);#expect(calls==2)
    }
    @Test func sheetAndDifferentWindowNeverDispatchPlayback() throws {
        let main=window(),sheet=window(),keys=PlayerKeys.KeysView(frame:.zero)
        main.contentView?.addSubview(keys);var calls=0;keys.action={_,_ in calls += 1;return true}
        defer{main.endSheet(sheet);keys.removeFromSuperview();sheet.close();main.close()}
        let other=try key(49,window:sheet);#expect(keys.handle(other) === other)
        main.beginSheet(sheet)
        let event=try key(49,window:main);#expect(keys.handle(event) === event);#expect(calls==0)
    }
    @Test func customBindingsPersistRejectConflictsAndRestoreDefaults() throws {
        let suite="LP084-"+UUID().uuidString,prefs=try #require(UserDefaults(suiteName:suite));defer{prefs.removePersistentDomain(forName:suite)}
        let model=PlaybackShortcuts(preferences:prefs)
        #expect(model.resolve(49,[]) == .toggle)
        #expect(model.set(PlaybackCommand.forward.initial,for:.toggle) != nil)
        #expect(model.set(PlaybackKey(code:12,modifiers:.command,name:"Q"),for:.toggle) != nil)
        #expect(model.set(PlaybackKey(code:49,modifiers:.command,name:"空格"),for:.toggle) != nil)
        let custom=PlaybackKey(code:35,modifiers:[.command,.shift],name:"P")
        #expect(model.set(custom,for:.toggle)==nil)
        let restored=PlaybackShortcuts(preferences:prefs)
        #expect(restored.resolve(49,[])==nil)
        #expect(restored.resolve(35,[.command,.shift,.capsLock]) == .toggle)
        #expect(restored.key(.toggle).label=="⇧⌘P")
        restored.reset();#expect(PlaybackShortcuts(preferences:prefs).resolve(49,[]) == .toggle)
    }
    @Test func corruptOrDuplicateSettingsFallBackAndCueSeekKeepsOffset() throws {
        let suite="LP084-"+UUID().uuidString,prefs=try #require(UserDefaults(suiteName:suite));defer{prefs.removePersistentDomain(forName:suite)}
        var duplicate=Dictionary(uniqueKeysWithValues:PlaybackCommand.allCases.map{($0,$0.initial)})
        duplicate[.forward]=duplicate[.toggle];prefs.set(try JSONEncoder().encode(duplicate),forKey:"playbackShortcuts.v1")
        let model=PlaybackShortcuts(preferences:prefs)
        #expect(model.resolve(124,[]) == .forward)
        let cues=[Cue(id:"a",start:1000,end:2000,en:"a"),Cue(id:"b",start:8000,end:9000,en:"b")],mapper=SubtitleTimingMapper(offset:14)
        #expect(model.transport(.previousCue,position:18,cues:cues,mapper:mapper) == .seek(15))
        #expect(model.transport(.nextCue,position:18,cues:cues,mapper:mapper) == .seek(22))
        #expect(model.transport(.nextCue,position:30,cues:cues,mapper:mapper)==nil)
    }
    @Test func bilingualFragmentRangesFollowRealCueAndClearDuringGap() throws {
        let cues=[Cue(id:"a",start:0,end:1000,en:"Speaker 0: The cash flow"),Cue(id:"b",start:1300,end:2200,en:"Speaker 0: is negative.")]
        let unit=try #require(ReadingUnits.make(cues).first)
        let content=unit.content(translations:["a":Translation(ai:"现金流",cacheKey:"a"),"b":Translation(ai:"为负。",cacheKey:"b")],mode:"双语")
        let timeline=TranscriptTimeline(cues),mapper=SubtitleTimingMapper(offset:14)
        for (time,id) in [(14.5,"a"),(15.5,"b")] {
            let ids=timeline.active(at:time,mapper:mapper)
            let ranges=content.spans.filter{ids.contains($0.cueID)}
            #expect(ranges.count==2 && ranges.allSatisfy{$0.cueID==id})
            for range in ranges {#expect(content.cue(atUTF16:range.range.location)==id)}
        }
        #expect(timeline.active(at:15.1,mapper:mapper).isEmpty)
        #expect(!content.text.contains("Speaker"))
        #expect(cues[0].en.hasPrefix("Speaker"))
    }
    @Test func repeatedTextUpdatesDoNotRebuildLayoutOrSelection() throws {
        let storage=NSTextStorage(),layout=NSLayoutManager(),container=NSTextContainer(size:NSSize(width:320,height:10000))
        storage.addLayoutManager(layout);layout.addTextContainer(container)
        let view=SelectableCueView(frame:.zero,textContainer:container)
        let text="Cash flow is negative.\n现金流为负。"
        view.apply(text:text,fontSize:18,lineSpacing:5)
        let original=try #require(view.measuredSize(width:320,fontSize:18))
        view.setSelectedRange(NSRange(location:5,length:4));let selection=view.selectedRange()
        for _ in 0..<1000 {
            view.apply(text:text,fontSize:18,lineSpacing:5)
            #expect(view.measuredSize(width:320,fontSize:18)==original)
        }
        #expect(view.layoutBuilds==1 && view.attributeBuilds==1)
        #expect(view.string==text && view.selectedRange()==selection)
        #expect(layout.temporaryAttribute(.underlineStyle,atCharacterIndex:10,effectiveRange:nil)==nil)
        #expect(view.selectedRange()==selection && view.heights.count==1)
    }
    @Test func collapsedParentLocationAndChapterGapsUseSameTimeline() {
        let chapters=[AnalysisChapter(id:"a",startCueID:"q1",endCueID:"q2",title:"概念",points:["说明"]),AnalysisChapter(id:"b",startCueID:"q3",endCueID:"q4",title:"例题",points:["说明"])]
        let topics=[AnalysisTopic(id:"parent",title:"主题",overview:"概述",subtopics:chapters)]
        let parents=ChapterActivity.parents(topics)
        let index=[ChapterPositionIndex.Entry(id:"a",start:0,end:10),ChapterPositionIndex.Entry(id:"b",start:12,end:25)]
        let current=ChapterPositionIndex.current(index,seconds:20-14)
        #expect(current=="a" && current.flatMap{parents[$0]}=="parent")
        #expect(ChapterPositionIndex.current(index,seconds:25-14)==nil)
        #expect(ChapterActivity.parents([]).isEmpty)
        // Parent resolution does not depend on which topics the user has expanded.
        let session=ReaderSession();session.expandedTopics=[]
        #expect(current.flatMap{parents[$0]}=="parent" && session.expandedTopics.isEmpty)
    }
}
