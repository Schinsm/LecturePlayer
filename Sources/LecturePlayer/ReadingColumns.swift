import AppKit
import SwiftUI

@MainActor final class ReadingColumns: ObservableObject {
    enum Pane: String, Codable {case chapters, transcript}
    struct Preferences: Codable, Equatable {
        var enabled=true, chapters=true, transcript=true
        var chapterWidth=300.0, transcriptWidth=360.0
        var narrowPane:Pane = .transcript
    }
    @Published private(set) var value:Preferences
    @Published private(set) var compact=false
    private let defaults:UserDefaults
    private var saveTask:Task<Void,Never>?
    private var widthTask:Task<Void,Never>?
    private var pendingCompact:Bool?
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"readingColumns.v1"),let saved=try? JSONDecoder().decode(Preferences.self,from:data) {value=saved}
        else {var initial=Preferences();initial.enabled=defaults.object(forKey:"readerPaneVisible")==nil || defaults.bool(forKey:"readerPaneVisible");value=initial}
        value.chapterWidth=max(280,value.chapterWidth.isFinite ? value.chapterWidth:300)
        value.transcriptWidth=max(320,value.transcriptWidth.isFinite ? value.transcriptWidth:360)
    }
    func compact(at width:CGFloat)->Bool {compact ? width < 1160 : width < 1120}
    func updateWidth(_ width:CGFloat) {
        let next=compact(at:width)
        guard pendingCompact != next else{return}
        widthTask?.cancel();widthTask=nil;pendingCompact=nil
        guard next != compact else{return}
        pendingCompact=next
        widthTask=Task {await Task.yield();guard !Task.isCancelled else{return};compact=next;pendingCompact=nil;widthTask=nil}
    }
    func visible(_ pane:Pane,compact override:Bool?=nil)->Bool {
        guard value.enabled else{return false}
        let requested=pane == .chapters ? value.chapters:value.transcript
        guard requested else{return false}
        if (override ?? compact) && value.chapters && value.transcript {return value.narrowPane==pane}
        return true
    }
    func toggleAll() {value.enabled.toggle();if !value.chapters && !value.transcript {value.chapters=true;value.transcript=true};flush()}
    func hide(_ pane:Pane) {
        let isLast = pane == .chapters ? !value.transcript : !value.chapters
        if isLast {value.enabled=false}
        else if pane == .chapters {value.chapters=false}else{value.transcript=false}
        flush()
    }
    func show(_ pane:Pane) {
        value.enabled=true
        if pane == .chapters {value.chapters=true}else{value.transcript=true}
        value.narrowPane=pane;flush()
    }
    func selectNarrow(_ pane:Pane) {value.narrowPane=pane;flush()}
    func resize(chapters:CGFloat?,transcript:CGFloat?) {
        var next=value
        if let chapters {next.chapterWidth=max(280,chapters)}
        if let transcript {next.transcriptWidth=max(320,transcript)}
        guard next != value else{return};value=next
        saveTask?.cancel();saveTask=Task {do{try await Task.sleep(for:.milliseconds(300))}catch{return};flush()}
    }
    func flush() {saveTask?.cancel();saveTask=nil;defaults.set(try? JSONEncoder().encode(value),forKey:"readingColumns.v1");defaults.set(value.enabled,forKey:"readerPaneVisible")}
    deinit {saveTask?.cancel();widthTask?.cancel()}
}

/// Stable hosts retain each panel's scroll/selection state while it is hidden.
struct ReadingColumnsHost<Video:View, Chapters:View, Transcript:View>:NSViewRepresentable {
    @ObservedObject var columns:ReadingColumns
    let identity:UUID?
    let video:Video;let chapters:Chapters;let transcript:Transcript
    init(columns:ReadingColumns,identity:UUID?,@ViewBuilder video:()->Video,@ViewBuilder chapters:()->Chapters,@ViewBuilder transcript:()->Transcript) {
        self.columns=columns;self.identity=identity;self.video=video();self.chapters=chapters();self.transcript=transcript()
    }
    final class Coordinator {var identity:UUID?}
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->ReaderSplitContainer {
        let split=ReadingColumnsSplit(columns:columns)
        split.addArrangedSubview(NSHostingView(rootView:video))
        split.addArrangedSubview(NSHostingView(rootView:chapters))
        split.addArrangedSubview(NSHostingView(rootView:transcript))
        context.coordinator.identity=identity
        let host=ReaderSplitContainer(split:split,delegate:ReadingColumnsSplit.Delegate(split))
        host.configure(visible:columns.value.enabled,toggle:columns.toggleAll)
        return host
    }
    func updateNSView(_ host:ReaderSplitContainer,context:Context) {
        host.configure(visible:columns.value.enabled,toggle:columns.toggleAll)
        guard let split=host.split as? ReadingColumnsSplit else{return}
        split.applyLayout()
        if context.coordinator.identity != identity {
            context.coordinator.identity=identity
            (split.arrangedSubviews[0] as? NSHostingView<Video>)?.rootView=video
            (split.arrangedSubviews[1] as? NSHostingView<Chapters>)?.rootView=chapters
            (split.arrangedSubviews[2] as? NSHostingView<Transcript>)?.rootView=transcript
        }
        host.needsLayout=true
    }
    static func dismantleNSView(_ view:ReaderSplitContainer,coordinator:Coordinator) {(view.split as? ReadingColumnsSplit)?.columns.flush();view.handle.visibility.reset()}
}

final class ReadingColumnsSplit:NSSplitView {
    let columns:ReadingColumns
    private var applying=false
    init(columns:ReadingColumns) {self.columns=columns;super.init(frame:.zero);isVertical=true;dividerStyle = .thin}
    required init?(coder:NSCoder){fatalError()}
    var visibleIndices:[Int] {[0]+(columns.visible(.chapters,compact:columns.compact(at:bounds.width)) ? [1]:[])+(columns.visible(.transcript,compact:columns.compact(at:bounds.width)) ? [2]:[])}
    override func layout(){super.layout();applyLayout()}
    override func resizeSubviews(withOldSize oldSize:NSSize){applyLayout()}
    func applyLayout() {
        guard !applying,arrangedSubviews.count==3,bounds.width>0 else{return}
        applying=true;defer{applying=false}
        columns.updateWidth(bounds.width)
        let shown=visibleIndices
        let room=max(0,bounds.width-CGFloat(shown.count-1)*dividerThickness)
        var chapter=shown.contains(1) ? CGFloat(columns.value.chapterWidth):0
        var transcript=shown.contains(2) ? CGFloat(columns.value.transcriptWidth):0
        let minimum=CGFloat(shown.contains(1) ? 280:0)+CGFloat(shown.contains(2) ? 320:0)
        let available=max(minimum,room-480)
        if chapter+transcript>available {
            let excess=chapter+transcript-available
            let reducible=max(0,chapter-(chapter>0 ? 280:0))+max(0,transcript-(transcript>0 ? 320:0))
            if reducible>0 {chapter -= excess*max(0,chapter-280)/reducible;transcript -= excess*max(0,transcript-320)/reducible}
        }
        let widths=[max(0,room-chapter-transcript),chapter,transcript]
        var x:CGFloat=0
        for i in arrangedSubviews.indices {
            let view=arrangedSubviews[i];view.isHidden = !shown.contains(i)
            view.frame=NSRect(x:x,y:0,width:shown.contains(i) ? widths[i]:0,height:bounds.height)
            if shown.contains(i) {x += widths[i];if i != shown.last {x += dividerThickness}}
        }
        needsDisplay=true;(superview as? ReaderSplitContainer)?.needsLayout=true
    }
    override func drawDivider(in rect:NSRect) {
        guard visibleIndices.dropLast().contains(where:{abs(arrangedSubviews[$0].frame.maxX-rect.minX)<1}) else{return}
        super.drawDivider(in:rect)
    }
    final class Delegate:NSObject,NSSplitViewDelegate {
        weak var split:ReadingColumnsSplit?
        init(_ split:ReadingColumnsSplit){self.split=split}
        func splitView(_ view:NSSplitView,shouldHideDividerAt index:Int)->Bool {guard let split else{return true};return !split.visibleIndices.dropLast().contains(index)}
        func splitView(_ view:NSSplitView,effectiveRect rect:NSRect,forDrawnRect drawn:NSRect,ofDividerAt index:Int)->NSRect {splitView(view,shouldHideDividerAt:index) ? .zero:rect}
        func splitView(_ view:NSSplitView,constrainMinCoordinate proposed:CGFloat,ofSubviewAt index:Int)->CGFloat {
            guard let split else{return proposed};return index==0 ? 480:split.arrangedSubviews[1].frame.minX+280
        }
        func splitView(_ view:NSSplitView,constrainMaxCoordinate proposed:CGFloat,ofSubviewAt index:Int)->CGFloat {
            guard let split else{return proposed}
            return view.bounds.width-(index==0 ? CGFloat(split.visibleIndices.contains(1) ? 280:0)+CGFloat(split.visibleIndices.contains(2) ? 320:0):320)-split.dividerThickness
        }
        func splitViewDidResizeSubviews(_ note:Notification) {
            guard let split,!split.applying,split.arrangedSubviews.count==3 else{return}
            let shown=split.visibleIndices
            split.columns.resize(chapters:shown.contains(1) ? split.arrangedSubviews[1].frame.width:nil,transcript:shown.contains(2) ? split.arrangedSubviews[2].frame.width:nil)
            (split.superview as? ReaderSplitContainer)?.needsLayout=true
        }
    }
}

struct ReadingPaneHeader<Actions:View>:View {
    let title:String;let pane:ReadingColumns.Pane
    @ObservedObject var columns:ReadingColumns
    let following:Bool;let follow:()->Void;let actions:Actions
    init(_ title:String,pane:ReadingColumns.Pane,columns:ReadingColumns,following:Bool,follow:@escaping()->Void,@ViewBuilder actions:()->Actions){self.title=title;self.pane=pane;self.columns=columns;self.following=following;self.follow=follow;self.actions=actions()}
    var body:some View {
        HStack(spacing:8) {
            if columns.compact && columns.value.chapters && columns.value.transcript {
                Picker("阅读栏",selection:Binding(get:{columns.value.narrowPane},set:columns.selectNarrow)) {
                    Text("章节").tag(ReadingColumns.Pane.chapters);Text("转写").tag(ReadingColumns.Pane.transcript)
                }.labelsHidden().fixedSize()
            } else {Text(title).font(.headline)}
            Spacer(minLength:4)
            if !following {Button("跟随",action:follow).help("回到当前播放位置")}
            actions
            Button{columns.hide(pane)}label:{Image(systemName:"sidebar.right")}.help("收起"+title).accessibilityLabel("收起"+title)
        }.buttonStyle(.borderless).controlSize(.small).frame(height:26)
    }
}
