import AppKit
import SwiftUI
import Core

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    var beforeTerminate:(() throws->Void)?
    var drainBeforeTerminate:(() async->Void)?
    private var terminating=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminating {return .terminateLater}
        do {
            try beforeTerminate?()
            guard let drainBeforeTerminate else{return .terminateNow}
            terminating=true
            Task {@MainActor in
                await drainBeforeTerminate()
                do {try beforeTerminate?();sender.reply(toApplicationShouldTerminate:true)}
                catch {terminating=false;sender.reply(toApplicationShouldTerminate:false)}
            }
            return .terminateLater
        }
        catch {let alert=NSAlert();alert.messageText="学习设置尚未保存";alert.informativeText="已保留待保存内容。请重试保存后再退出。\n"+error.localizedDescription;alert.addButton(withTitle:"返回应用");alert.runModal();return .terminateCancel}
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {NSApp.windows.first(where:{$0.identifier?.rawValue=="main"})?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
struct PlayerKeys:NSViewRepresentable {
    var enabled = true
    var action:(UInt16,NSEvent.ModifierFlags)->Bool
    func makeNSView(context:Context)->KeysView {let v=KeysView();v.action=action;v.enabled=enabled;return v}
    func updateNSView(_ v:KeysView,context:Context){v.action=action;v.enabled=enabled}
    class KeysView:NSView {
        var action:((UInt16,NSEvent.ModifierFlags)->Bool)?;var monitor:Any?
        var enabled = true {didSet {if enabled != oldValue {updateMonitor()}}}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateMonitor()}
        private func updateMonitor() {
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard enabled,window != nil else{return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
                guard let self else{return event}
                return self.handle(event)
            }
        }
        func handle(_ event:NSEvent)->NSEvent? {
            guard enabled,let window,event.window === window,!isHiddenOrHasHiddenAncestor,window.attachedSheet == nil,NSApp.modalWindow == nil else{return event}
            let responder=window.firstResponder
            if let anchor = SpeedAnchorButton.active, anchor.window === window {return event}
            if responder is PictureInPictureHandle && ([123,124,125,126].contains(event.keyCode) || ["+","=","-"].contains(event.characters ?? "")) {return event}
            if responder is ReaderPaneToggle {return event}
            if let text=responder as? NSTextView {
                if text.isEditable || text.hasMarkedText() {return event}
                if text.selectedRange().length>0 && [123,124,125,126].contains(event.keyCode) {return event}
            }
            if let field=responder as? NSTextField,field.isEditable {return event}
            if event.isARepeat {return PlaybackShortcuts.shared.resolve(event.keyCode,event.modifierFlags) == nil ? event:nil}
            return action?(event.keyCode,event.modifierFlags.intersection(.deviceIndependentFlagsMask))==true ? nil : event
        }
        deinit{if let monitor{NSEvent.removeMonitor(monitor)}}
    }
}

enum PlayerTransportShortcut:Equatable {
    case toggle
    case seek(Double)
    static func resolve(_ code:UInt16,modifiers:NSEvent.ModifierFlags,position:Double,cues:[Cue],mapper:SubtitleTimingMapper)->Self? {
        guard !modifiers.contains(.command),!modifiers.contains(.control) else{return nil}
        if code==49,modifiers.isEmpty {return .toggle}
        guard code==123 || code==124 else{return nil}
        if modifiers.contains(.option) {
            let points=cues.map{mapper.seekTarget($0)}.sorted()
            let target=code==123 ? points.last{$0<position-0.3} : points.first{$0>position+0.3}
            return target.map{.seek($0)}
        }
        return .seek(position+(code==123 ? -5 : 5))
    }
}
struct WindowPersistence:NSViewRepresentable {
    func makeNSView(context:Context)->PersistView{PersistView()}
    func updateNSView(_ view:PersistView,context:Context){}
    class PersistView:NSView {
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();guard let window else{return};window.setFrameAutosaveName("LecturePlayerMainWindow")}
    }
}

struct StudySplit<Left: View, Right: View>: NSViewRepresentable {
    let left: Left; let right: Right;let identity:UUID?; let rightVisible:Bool; let toggleReader:()->Void
    class Coordinator {var identity:UUID?}
    func makeCoordinator()->Coordinator {Coordinator()}
    init(identity:UUID?=nil,rightVisible:Bool=true,toggleReader:@escaping ()->Void = {},@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) { self.toggleReader=toggleReader;self.rightVisible=rightVisible;self.identity=identity;self.left = left(); self.right = right() }
    func makeNSView(context: Context) -> ReaderSplitContainer {
        let split = Split(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(NSHostingView(rootView: left)); split.addArrangedSubview(NSHostingView(rootView: right))
        context.coordinator.identity=identity; split.setRightVisible(rightVisible);
        let host=ReaderSplitContainer(split:split,delegate:SplitDelegate(split));host.configure(visible:rightVisible,toggle:toggleReader);return host
    }
    func updateNSView(_ host: ReaderSplitContainer, context: Context) {
        guard let split=host.split as? Split else{return}
        host.configure(visible:rightVisible,toggle:toggleReader)
        split.setRightVisible(rightVisible);host.needsLayout=true
        guard context.coordinator.identity != identity else{return};context.coordinator.identity=identity
        (split.arrangedSubviews[0] as? NSHostingView<Left>)?.rootView = left
        (split.arrangedSubviews[1] as? NSHostingView<Right>)?.rootView = right
    }
    /// NSObject answers only its own protocol selectors; never forwards menu queries to the split.
    final class SplitDelegate: NSObject, NSSplitViewDelegate {
        weak var split: Split?
        init(_ split: Split) {self.split=split;super.init()}
        func splitView(_ view:NSSplitView,shouldHideDividerAt index:Int)->Bool {split?.rightVisible == false}
        func splitView(_ view:NSSplitView,effectiveRect rect:NSRect,forDrawnRect drawn:NSRect,ofDividerAt index:Int)->NSRect {split?.rightVisible == false ? .zero : rect}
        func splitView(_ view:NSSplitView,constrainMinCoordinate proposed:CGFloat,ofSubviewAt index:Int)->CGFloat {420}
        func splitView(_ view:NSSplitView,constrainMaxCoordinate proposed:CGFloat,ofSubviewAt index:Int)->CGFloat {view.bounds.width-300}
        func splitViewDidResizeSubviews(_ notification:Notification) {split?.splitViewDidResizeSubviews(notification)}
    }
    class Split: NSSplitView {
        private var saveTimer:Timer?
        deinit{saveTimer?.invalidate()}
        var initialized = false; var restoring = false
        private(set) var rightVisible = true
        private(set) var expandedRatio:CGFloat = 0.6
        override var dividerThickness:CGFloat { rightVisible ? super.dividerThickness : 0 }
        override func drawDivider(in rect:NSRect) {
            if rightVisible {super.drawDivider(in:rect)}
        }
        func splitView(_ splitView:NSSplitView,shouldHideDividerAt dividerIndex:Int)->Bool { !rightVisible }
        func splitView(_ splitView:NSSplitView,effectiveRect proposedEffectiveRect:NSRect,forDrawnRect drawnRect:NSRect,ofDividerAt dividerIndex:Int)->NSRect {
            rightVisible ? proposedEffectiveRect : .zero
        }
        private func fillCollapsedArea() {
            guard !rightVisible,arrangedSubviews.count==2 else{return}
            arrangedSubviews[0].frame=bounds
            arrangedSubviews[1].frame=NSRect(x:bounds.maxX,y:bounds.minY,width:0,height:bounds.height)
        }
        func setRightVisible(_ visible:Bool) {
            guard rightVisible != visible, arrangedSubviews.count == 2 else{return}
            saveTimer?.invalidate()
            if rightVisible && bounds.width > 0 && initialized {expandedRatio=arrangedSubviews[0].frame.width/bounds.width}
            rightVisible=visible;restoring=true
            arrangedSubviews[1].isHidden = !visible
            adjustSubviews()
            if visible && initialized {setPosition(bounds.width*expandedRatio,ofDividerAt:0)}
            fillCollapsedArea()
            needsLayout=true;needsDisplay=true
            arrangedSubviews.forEach{$0.needsDisplay=true}
            restoring=false
        }
        override func layout() {
            super.layout()
            fillCollapsedArea()
            guard !initialized, bounds.width > 720 else { return }
            initialized = true; restoring = true
            let saved = UserDefaults.standard.double(forKey: "studySplitRatio")
            expandedRatio = saved > 0 ? min(0.75, max(0.35, saved)) : 0.6
            if rightVisible {setPosition(bounds.width * expandedRatio, ofDividerAt: 0)}
            restoring = false
        }
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 420 }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { bounds.width - 300 }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            (superview as? ReaderSplitContainer)?.needsLayout=true
            guard initialized, rightVisible, !restoring, bounds.width > 0, let first = arrangedSubviews.first else { return }
            let ratio=first.frame.width / bounds.width; expandedRatio=ratio
            saveTimer?.invalidate();saveTimer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:false){_ in UserDefaults.standard.set(ratio,forKey:"studySplitRatio")}
        }
    }
}

struct StudyFullscreenButton: View {
    @LPState private var full=false
    var body:some View {
        Button { (NSApp.windows.first{$0.identifier?.rawValue=="main"} ?? NSApp.keyWindow)?.toggleFullScreen(nil) } label: {Image(systemName:full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")}
        .help(full ? "退出学习全屏" : "学习全屏").accessibilityLabel(full ? "退出学习全屏" : "学习全屏")
        .onAppear{full=(NSApp.windows.first{$0.identifier?.rawValue=="main"} ?? NSApp.keyWindow)?.styleMask.contains(.fullScreen) ?? false}
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didEnterFullScreenNotification)){_ in full=true}
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didExitFullScreenNotification)){_ in full=false}
    }
}
