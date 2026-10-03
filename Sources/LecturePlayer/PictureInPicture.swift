import AppKit
import Combine
import Core

struct PictureInPicturePlacement: Codable, Equatable {
    var x: Double = 1
    var y: Double = 1
    var width: Double = 0.32
    var validated: Self {
        var v = self
        v.x = x.isFinite ? min(1, max(0, x)) : 1
        v.y = y.isFinite ? min(1, max(0, y)) : 1
        v.width = width.isFinite ? min(0.5, max(0.18, width)) : 0.32
        return v
    }
}

/// The live value is observed only by the video canvas, never the transcript/store.
@MainActor final class PictureInPicturePreferences: ObservableObject {
    static let key = "pictureInPicturePlacement.v1"
    @Published private(set) var value: PictureInPicturePlacement
    private let defaults: UserDefaults
    private var saved: PictureInPicturePlacement
    private var pendingSave: Task<Void, Never>?
    private(set) var writeCount = 0
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PictureInPicturePlacement.self, from: $0) } ?? .init()
        value = loaded.validated; saved = loaded.validated
    }
    func preview(_ next: PictureInPicturePlacement) {
        let v = next.validated
        if value != v { value = v }
    }
    func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard value != saved, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key); saved = value; writeCount += 1
    }
    func reset() { preview(.init()); flush() }
    deinit { pendingSave?.cancel() }
}

/// Coordinates use a flipped video canvas. Position is a fraction of usable travel,
/// so right/bottom attachment survives changes to window size and video aspect ratio.
enum PictureInPictureGeometry {
    static func frame(bounds: CGRect, aspect: CGFloat, placement: PictureInPicturePlacement) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, aspect.isFinite, aspect > 0 else { return nil }
        let margin = min(12, min(bounds.width, bounds.height) / 4)
        let area = bounds.insetBy(dx: margin, dy: margin)
        let v = placement.validated
        let width = min(bounds.width * v.width, area.width, area.height * aspect)
        let height = width / aspect
        return CGRect(x: area.minX + (area.width - width) * v.x,
                      y: area.minY + (area.height - height) * v.y, width: width, height: height)
    }
    static func moving(origin: CGPoint, bounds: CGRect, aspect: CGFloat, placement: PictureInPicturePlacement) -> PictureInPicturePlacement {
        guard let rect = frame(bounds: bounds, aspect: aspect, placement: placement) else { return placement }
        let margin = min(12, min(bounds.width, bounds.height) / 4)
        var next = placement
        let travelX = bounds.width - 2 * margin - rect.width
        let travelY = bounds.height - 2 * margin - rect.height
        next.x = travelX > 0 ? (origin.x - bounds.minX - margin) / travelX : placement.x
        next.y = travelY > 0 ? (origin.y - bounds.minY - margin) / travelY : placement.y
        return next.validated
    }
    static func aspect(_ size: CGSize) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}

/// Transparent interaction surface confined to the inset. No global mouse monitor.
final class PictureInPictureHandle: NSView {
    var move: ((CGFloat, CGFloat, Bool) -> Void)?
    var resize: ((CGFloat, CGFloat, Bool) -> Void)?
    var commit: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var down: CGPoint?
    private var resizing = false
    private var gripVisible: Bool { hovered || window?.firstResponder === self }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("画中画小窗")
        setAccessibilityHelp("拖动移动，右下角缩放。方向键移动，加减键调整大小。")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "向左移动", target: self, selector: #selector(left)),
            NSAccessibilityCustomAction(name: "向右移动", target: self, selector: #selector(right)),
            NSAccessibilityCustomAction(name: "向上移动", target: self, selector: #selector(up)),
            NSAccessibilityCustomAction(name: "向下移动", target: self, selector: #selector(downward)),
            NSAccessibilityCustomAction(name: "放大", target: self, selector: #selector(larger)),
            NSAccessibilityCustomAction(name: "缩小", target: self, selector: #selector(smaller))
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { commit?(); needsDisplay = true; return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard gripVisible else { return }
        NSColor.black.withAlphaComponent(0.6).setFill()
        let grip = CGRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 24, height: 24)
        NSBezierPath(roundedRect: grip, xRadius: 4, yRadius: 4).fill()
        NSColor.white.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        for n in [6.0, 11.0] {
            path.move(to: CGPoint(x: bounds.maxX - n - 4, y: bounds.maxY - 4))
            path.line(to: CGPoint(x: bounds.maxX - 4, y: bounds.maxY - n - 4))
        }; path.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); border.lineWidth = 2; border.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down = superview?.convert(event.locationInWindow, from: nil)
        let p = convert(event.locationInWindow, from: nil)
        resizing = p.x >= bounds.maxX - 24 && p.y >= bounds.maxY - 24
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = down, let p = superview?.convert(event.locationInWindow, from: nil) else { return }
        if resizing { resize?(p.x - previous.x, p.y - previous.y, false) } else { move?(p.x - previous.x, p.y - previous.y, false) }
        down = p
    }
    override func mouseUp(with event: NSEvent) { down = nil; commit?() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { down = nil; commit?() }; super.viewWillMove(toWindow: newWindow) }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 20 : 5
        switch event.keyCode {
        case 123: move?(-step, 0, true)
        case 124: move?(step, 0, true)
        case 125: move?(0, step, true)
        case 126: move?(0, -step, true)
        default:
            if event.characters == "+" || event.characters == "=" { resize?(10, 0, true) }
            else if event.characters == "-" { resize?(-10, 0, true) }
            else { super.keyDown(with: event) }
        }
    }
    @objc private func left() -> Bool { move?(-10, 0, true); return true }
    @objc private func right() -> Bool { move?(10, 0, true); return true }
    @objc private func up() -> Bool { move?(0, -10, true); return true }
    @objc private func downward() -> Bool { move?(0, 10, true); return true }
    @objc private func larger() -> Bool { resize?(10, 0, true); return true }
    @objc private func smaller() -> Bool { resize?(-10, 0, true); return true }
}
