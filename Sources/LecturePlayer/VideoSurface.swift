import AppKit
import AVFoundation

/// The transport outlives a player page. Bind its rendering layer only while
/// this surface is mounted and sized, and release it when the page goes away.
@MainActor final class VideoSurface: NSView {
    private(set) var playerLayer = AVPlayerLayer()
    private var readiness: NSKeyValueObservation?
    private var readinessGeneration = UUID()
    private var itemObservation: NSKeyValueObservation?
    private weak var attachedItem: AVPlayerItem?
    private var enabled = true
    private(set) var attachmentCount = 0
    private(set) var rebuildCount = 0
    @objc dynamic private(set) var isReadyForDisplay = false
    var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { synchronizeAttachment(); return }
            itemObservation = nil
            itemObservation = player?.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.synchronizeAttachment() }
            }
            synchronizeAttachment()
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        installLayer()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    private func installLayer() {
        let current = playerLayer
        let token = UUID(); readinessGeneration = token
        current.videoGravity = .resizeAspect
        current.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(current)
        readiness = current.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readinessGeneration == token else { return }
                self.refreshReadiness()
            }
        }
        layoutVideoLayer()
    }
    private func refreshReadiness() {
        let ready = playerLayer.player != nil && attachedItem === player?.currentItem
            && attachedItem != nil && playerLayer.isReadyForDisplay
        if isReadyForDisplay != ready { isReadyForDisplay = ready }
    }
    func setPresentationEnabled(_ value: Bool) {
        enabled = value
        synchronizeAttachment()
    }
    func synchronizeAttachment() {
        let mounted = enabled && window != nil && !isHiddenOrHasHiddenAncestor
            && bounds.width > 1 && bounds.height > 1
        let target = mounted ? player : nil
        if playerLayer.player !== target || attachedItem !== target?.currentItem {
            // Rebinding the same AVPlayer to a different item must not reuse
            // readiness from the previous lesson.
            playerLayer.player = nil; attachedItem = nil
            isReadyForDisplay = false
            layoutVideoLayer()
            if let target, let item = target.currentItem {
                attachedItem = item; playerLayer.player = target
                attachmentCount += 1
            }
        }
        refreshReadiness()
    }
    /// A bounded presentation-only repair. No seek, item replacement or audio change.
    func rebuildPresentation() {
        readiness = nil; playerLayer.player = nil; playerLayer.removeFromSuperlayer()
        attachedItem = nil; isReadyForDisplay = false
        playerLayer = AVPlayerLayer(); rebuildCount += 1
        installLayer(); synchronizeAttachment()
    }
    func detach() {
        itemObservation = nil; player = nil
        playerLayer.player = nil; attachedItem = nil; isReadyForDisplay = false
    }
    private func layoutVideoLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        playerLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    override func layout() { super.layout(); layoutVideoLayer(); synchronizeAttachment() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); layoutVideoLayer(); synchronizeAttachment()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); layoutVideoLayer(); synchronizeAttachment()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layoutVideoLayer() }
    deinit { playerLayer.player = nil }
}
