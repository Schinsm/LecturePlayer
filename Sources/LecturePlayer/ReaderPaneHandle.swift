import AppKit
import SwiftUI

/// Event-driven visibility, independent of playback and reader state.
@MainActor final class ReaderHandleVisibility {
    private(set) var hovered=false
    private(set) var focused=false
    private(set) var accessibilityFocused=false
    private(set) var revealed=false
    var changed:((Bool)->Void)?
    private var pending:Task<Void,Never>?
    private let delay:Duration
    init(delay:Duration = .milliseconds(250)) {self.delay=delay}
    deinit {pending?.cancel()}
    func hover(_ value:Bool) {guard hovered != value else{return};hovered=value;update()}
    func focus(_ value:Bool) {focused=value;update()}
    func accessibilityFocus(_ value:Bool) {accessibilityFocused=value;update()}
    func reset() {pending?.cancel();pending=nil;hovered=false;focused=false;accessibilityFocused=false;show(false)}
    private func show(_ value:Bool) {guard revealed != value else{return};revealed=value;changed?(value)}
    private func update() {
        pending?.cancel();pending=nil
        if hovered || focused || accessibilityFocused {show(true);return}
        guard revealed else{return}
        pending=Task { [weak self,delay] in
            do {try await Task.sleep(for:delay)}catch{return}
            guard let self,!self.hovered,!self.focused,!self.accessibilityFocused else{return}
            self.show(false);self.pending=nil
        }
    }
}

/// A passive marker for the video rectangle, excluding its lower control bar.
struct VideoEdgeAnchor:NSViewRepresentable {
    func makeNSView(context:Context)->VideoEdgeMarker {VideoEdgeMarker()}
    func updateNSView(_ view:VideoEdgeMarker,context:Context) {}
}
final class VideoEdgeMarker:NSView {
    private var lastRect=NSRect.null
    private weak var lastHost:ReaderSplitContainer?
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func viewDidMoveToSuperview() {super.viewDidMoveToSuperview();report()}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();report()}
    override func layout() {super.layout();report()}
    override func setFrameOrigin(_ newOrigin:NSPoint) {super.setFrameOrigin(newOrigin);report()}
    override func setFrameSize(_ newSize:NSSize) {super.setFrameSize(newSize);report()}
    private func report() {
        var parent=superview
        while let view=parent {
            if let host=view as? ReaderSplitContainer {
                let rect=host.convert(bounds,from:self)
                if host !== lastHost || rect != lastRect {lastHost=host;lastRect=rect;host.videoMarker=self;host.needsLayout=true}
                return
            }
            parent=view.superview
        }
    }
}

final class ReaderSplitContainer:NSView {
    let split:NSSplitView
    private let retainedDelegate: NSSplitViewDelegate?
    let handle=ReaderPaneToggle(frame:.zero)
    weak var videoMarker:VideoEdgeMarker?
    private var tracking:NSTrackingArea?
    private(set) var sensingRect=NSRect.zero
    init(split:NSSplitView,delegate:NSSplitViewDelegate?=nil) {
        self.split=split;self.retainedDelegate=delegate;super.init(frame:split.frame)
        if let delegate {split.delegate=delegate}
        addSubview(split);addSubview(handle)
        split.autoresizingMask=[.width,.height]
        setAccessibilityElement(false)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func configure(visible:Bool,toggle:@escaping ()->Void) {handle.readerVisible=visible;handle.toggle=toggle}
    override func layout() {
        super.layout();if split.frame != bounds {split.frame=bounds};split.layoutSubtreeIfNeeded()
        guard let first=split.arrangedSubviews.first else{return}
        let edge=convert(first.bounds,from:first).maxX
        let mid=videoMarker.map{convert($0.bounds,from:$0).midY} ?? bounds.midY
        let center=min(max(bounds.minY+56,mid),max(bounds.minY+56,bounds.maxY-56))
        handle.frame=NSRect(x:edge-24,y:center-28,width:24,height:56)
        let rect=NSRect(x:edge-48,y:center-56,width:48,height:112).intersection(bounds)
        if rect != sensingRect {sensingRect=rect;updateTrackingAreas()}
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {removeTrackingArea(tracking)}
        guard !sensingRect.isEmpty else{return}
        let area=NSTrackingArea(rect:sensingRect,options:[.mouseEnteredAndExited,.activeInKeyWindow],owner:self,userInfo:nil)
        tracking=area;addTrackingArea(area)
        if let window {handle.visibility.hover(window.isKeyWindow && sensingRect.contains(convert(window.mouseLocationOutsideOfEventStream,from:nil)))}
    }
    override func mouseEntered(with event:NSEvent) {handle.visibility.hover(true)}
    override func mouseExited(with event:NSEvent) {handle.visibility.hover(false)}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();if window==nil {handle.visibility.reset()}}
}

/// Only this 24 x 56 button handles clicks. Its surrounding tracking area passes through.
final class ReaderPaneToggle:NSButton {
    let visibility=ReaderHandleVisibility()
    var toggle:(()->Void)?
    var readerVisible=true {didSet {updateLabel();needsDisplay=true}}
    private var mouseActivation=false
    override init(frame:NSRect) {
        super.init(frame:frame)
        isBordered=false;title="";focusRingType = .exterior
        target=self;action=#selector(activate);wantsLayer=true;layer?.opacity=0
        setAccessibilityRole(.button);updateLabel()
        visibility.changed={ [weak self] show in self?.reveal(show) }
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(accessibilitySettingsChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    deinit {NSWorkspace.shared.notificationCenter.removeObserver(self)}
    private func updateLabel() {let text=readerVisible ? "隐藏转写与章节":"显示转写与章节";toolTip=text;setAccessibilityLabel(text)}
    @objc private func activate() {toggle?()}
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else {return false}
        performClick(nil)
        return true
    }
    @objc private func accessibilitySettingsChanged() {needsDisplay=true;layer?.removeAllAnimations();layer?.opacity=visibility.revealed ? 1:0}
    private func reveal(_ show:Bool) {
        needsDisplay=true
        guard let layer else{return}
        let target:Float=show ? 1:0,current=layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey:"handleVisibility")
        CATransaction.begin();CATransaction.setDisableActions(true);layer.opacity=target;CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,window != nil {
            let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=current;fade.toValue=target;fade.duration=0.15
            layer.add(fade,forKey:"handleVisibility")
        }
    }
    override var acceptsFirstResponder:Bool {true}
    override func becomeFirstResponder()->Bool {let accepted=super.becomeFirstResponder();if accepted && !mouseActivation {visibility.focus(true);needsDisplay=true};return accepted}
    override func resignFirstResponder()->Bool {let accepted=super.resignFirstResponder();if accepted {visibility.focus(false);needsDisplay=true};return accepted}
    override func setAccessibilityFocused(_ accessibilityFocused:Bool) {super.setAccessibilityFocused(accessibilityFocused);visibility.accessibilityFocus(accessibilityFocused);needsDisplay=true}
    override func mouseDown(with event:NSEvent) {mouseActivation=true;defer{mouseActivation=false};super.mouseDown(with:event)}
    override func keyDown(with event:NSEvent) {
        visibility.focus(true)
        // Space belongs to playback, including while the media is still loading.
        // Return and the accessibility press action remain available for this button.
        if event.keyCode==49 {return}
        if event.keyCode==36 {performClick(nil)}else{super.keyDown(with:event)}
    }
    override func hitTest(_ point:NSPoint)->NSView? {
        guard visibility.revealed else{return nil}
        let local=convert(point,from:superview)
        // Keep the divider's narrow resize target available at the shared edge.
        guard !readerVisible || local.x<bounds.maxX-2 else{return nil}
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect:NSRect) {
        let opaque=NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let shape=NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6)
        shape.appendRect(NSRect(x:bounds.midX,y:bounds.minY,width:bounds.width/2,height:bounds.height))
        (opaque ? NSColor.darkGray:NSColor.black.withAlphaComponent(0.58)).setFill();shape.fill()
        let arrow=NSBezierPath();arrow.lineWidth=2;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
        let x=bounds.midX,y=bounds.midY,d:CGFloat=readerVisible ? 1:-1
        arrow.move(to:NSPoint(x:x-2*d,y:y-5));arrow.line(to:NSPoint(x:x+3*d,y:y));arrow.line(to:NSPoint(x:x-2*d,y:y+5))
        NSColor.white.setStroke();arrow.stroke()
        if visibility.focused || visibility.accessibilityFocused {
            NSColor.keyboardFocusIndicatorColor.setStroke();let ring=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:5,yRadius:5);ring.lineWidth=2;ring.stroke()
        }
    }
}
