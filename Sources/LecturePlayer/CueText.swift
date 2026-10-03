import AppKit
import SwiftUI

/// TextKit selection owns dragging; a completed unmodified single click owns seeking.
struct CueText: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let lineSpacing: Double
    let jump: () -> Void
    let browse: () -> Void
    var characterJump: ((Int) -> Void)? = nil
    func makeNSView(context: Context) -> SelectableCueView {
        let storage = NSTextStorage(); let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        let view = SelectableCueView(frame: .zero, textContainer: container)
        view.delegate = view
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.textContainerInset = NSSize.zero
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: SelectableCueView, context: Context) {
        view.jump = jump; view.browse = browse; view.characterJump = characterJump
        view.apply(text:text,fontSize:fontSize,lineSpacing:lineSpacing)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableCueView, context: Context) -> CGSize? {
        nsView.measuredSize(width:max(40,proposal.width ?? 300),fontSize:fontSize)
    }
}
final class SelectableCueView: NSTextView, NSTextViewDelegate {
    struct ContentKey:Equatable {let text:String;let size:Double;let spacing:Double}
    var contentKey:ContentKey?
    var heights:[CGFloat:CGFloat]=[:]
    private(set) var attributeBuilds=0
    private(set) var layoutBuilds=0
    func apply(text:String,fontSize:Double,lineSpacing:Double) {
        let key=ContentKey(text:text,size:fontSize,spacing:lineSpacing)
        guard contentKey != key else{return}
        PerformanceTrace.measure("reader.attributedText") {
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=lineSpacing
            textStorage?.setAttributedString(NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]))
            contentKey=key;heights.removeAll(keepingCapacity:true);attributeBuilds += 1;setAccessibilityLabel(text)
        }
    }
    func measuredSize(width:Double,fontSize:Double)->CGSize? {
        if textContainer?.containerSize.width != CGFloat(width) {textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)}
        if let height=heights[width] {return CGSize(width:width,height:height)}
        return PerformanceTrace.measure("reader.layout") {
            guard let layout=layoutManager,let container=textContainer else{return nil}
            layout.ensureLayout(for:container);layoutBuilds += 1
            let height=max(fontSize+5,ceil(layout.usedRect(for:container).height))
            if heights.count>=16 {heights.removeAll(keepingCapacity:true)}
            heights[width]=height;return CGSize(width:width,height:height)
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) { if selectedRange().length > 0 { browse?() } }
    var characterJump: ((Int) -> Void)?
    var jump: (() -> Void)?; var browse: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        super.mouseDown(with: event)
        let end = NSApp.currentEvent?.locationInWindow ?? start
        let moved = hypot(end.x-start.x, end.y-start.y) > 4
        if selectedRange().length > 0 || moved { browse?(); return }
        if event.clickCount == 1 && event.modifierFlags.intersection([.command,.shift,.option,.control]).isEmpty { if let characterJump { characterJump(characterIndexForInsertion(at: convert(end, from: nil))) } else { jump?() } }
    }
}
