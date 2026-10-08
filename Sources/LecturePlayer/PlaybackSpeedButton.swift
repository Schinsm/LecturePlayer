import AppKit
import SwiftUI

/// Native anchor avoids a popup menu using stale coordinates from ViewThatFits.
struct PlaybackSpeedButton: NSViewRepresentable {
    var speed: Double
    var choose: (Double) -> Void
    func makeNSView(context: Context) -> SpeedAnchorButton { SpeedAnchorButton() }
    func updateNSView(_ view: SpeedAnchorButton, context: Context) {
        view.speed = speed; view.choose = choose
        view.title = "\(speed.formatted())× ⌄"
    }
    static func dismantleNSView(_ view: SpeedAnchorButton, coordinator: ()) { view.closePanel() }
}

final class SpeedAnchorButton: NSButton, NSPopoverDelegate {
    static let rates = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5]
    private(set) static weak var active: SpeedAnchorButton?
    var speed = 1.0
    var choose: ((Double) -> Void)?
    private(set) var panel: NSPopover?
    private var observers: [NSObjectProtocol] = []
    override var intrinsicContentSize: NSSize { NSSize(width: 55, height: 24) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; bezelStyle = .regularSquare; target = self; action = #selector(showPanel)
        font = .systemFont(ofSize: 12); title = "1× ⌄"
        setAccessibilityLabel("倍速"); toolTip = "播放速度"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func showPanel() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        if panel?.isShown == true { closePanel(); return }
        Self.active?.closePanel()
        let content = SpeedOptionsView()
        content.selected = Self.rates.firstIndex(of: speed) ?? 1
        content.choose = { [weak self] index in
            guard let self else { return }
            let action = self.choose
            self.closePanel(); action?(Self.rates[index])
        }
        content.dismiss = { [weak self] in self?.closePanel() }
        content.build()
        let controller = NSViewController(); controller.view = content
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        popover.contentViewController = controller; popover.contentSize = content.frame.size; popover.delegate = self
        panel = popover; Self.active = self
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        content.window?.makeFirstResponder(content)
    }
    func closePanel() {
        panel?.close(); panel = nil
        if Self.active === self { Self.active = nil }
    }
    func popoverDidClose(_ notification: Notification) { if Self.active === self { Self.active = nil } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); closePanel()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let window else { return }
        for name in [NSWindow.willMoveNotification, NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.closePanel() })
        }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) { if newOrigin != frame.origin { closePanel() }; super.setFrameOrigin(newOrigin) }
    override func setFrameSize(_ newSize: NSSize) { if newSize != frame.size { closePanel() }; super.setFrameSize(newSize) }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

final class SpeedOptionsView: NSView {
    var selected = 1
    var choose: ((Int) -> Void)?
    var dismiss: (() -> Void)?
    private var buttons: [SpeedOptionRow] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func build() {
        buttons.forEach { $0.removeFromSuperview() }; buttons=[]
        frame = NSRect(x: 0, y: 0, width: 126, height: 7 * 26 + 12)
        for (index, rate) in SpeedAnchorButton.rates.enumerated() {
            let button = SpeedOptionRow(title: "\(rate.formatted())×", target: self, action: #selector(pick(_:)))
            button.isBordered = false; button.tag = index; button.current = index == selected
            button.frame = NSRect(x: 6, y: 6 + index * 26, width: 114, height: 26)
            button.setAccessibilityLabel("\(rate.formatted())倍速")
            button.setAccessibilityValue(button.current ? "当前" : "")
            button.hover = { [weak self] in self?.highlight(index) }
            addSubview(button); buttons.append(button)
        }
    }
    private func highlight(_ index: Int) {
        selected=index
        for button in buttons { button.emphasized=button.tag == index }
    }
    @objc private func pick(_ sender: NSButton) { choose?(sender.tag) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: highlight(max(0, selected - 1))
        case 125: highlight(min(SpeedAnchorButton.rates.count - 1, selected + 1))
        case 36, 49: choose?(selected)
        case 53: dismiss?()
        default: super.keyDown(with: event)
        }
    }
}

/// Menu rows keep the current-rate check separate from keyboard/hover selection.
private final class SpeedOptionRow: NSButton {
    var current=false
    var emphasized=false { didSet { needsDisplay=true } }
    var hover:(()->Void)?
    private var tracking:NSTrackingArea?
    override var acceptsFirstResponder:Bool {false}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        tracking=area;addTrackingArea(area)
    }
    override func mouseEntered(with event:NSEvent) {hover?()}
    override func mouseExited(with event:NSEvent) {emphasized=false}
    override func draw(_ dirtyRect:NSRect) {
        if emphasized || isHighlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.3 : 0.14).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:5,yRadius:5).fill()
        }
        let color=NSColor.labelColor
        if current {
            let symbol=NSImage(systemSymbolName:"checkmark",accessibilityDescription:"当前倍速")?
                .withSymbolConfiguration(.init(pointSize:11,weight:.semibold))
            symbol?.draw(in:NSRect(x:7,y:bounds.midY-6,width:12,height:12),from:.zero,
                         operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        let text=title as NSString, font=NSFont.systemFont(ofSize:13)
        let size=text.size(withAttributes:[.font:font])
        text.draw(at:NSPoint(x:28,y:(bounds.height-size.height)/2),withAttributes:[.font:font,.foregroundColor:color])
    }
}
