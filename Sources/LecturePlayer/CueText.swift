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
        container.widthTracksTextView = false; container.lineFragmentPadding = 0
        let view = SelectableCueView(frame: .zero, textContainer: container)
        view.delegate = view
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.textContainerInset = NSSize.zero
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: SelectableCueView, context: Context) {
        view.jump = jump; view.browse = browse; view.characterJump = characterJump
        view.apply(text:text,fontSize:fontSize,lineSpacing:lineSpacing)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableCueView, context: Context) -> CGSize? {
        // SwiftUI may measure a reused representable before updateNSView runs.
        nsView.apply(text:text,fontSize:fontSize,lineSpacing:lineSpacing)
        return nsView.measuredSize(width:max(1,proposal.width ?? nsView.bounds.width),fontSize:fontSize)
    }
}
struct CueTextLayoutKey: Hashable {
    let text: String
    let width: CGFloat
    let fontSize: Double
    let lineSpacing: Double
    let scale: CGFloat
}
final class SelectableCueView: NSTextView, NSTextViewDelegate {
    struct ContentKey:Equatable {let text:String;let size:Double;let spacing:Double}
    var contentKey:ContentKey?
    var heights:[CGFloat:CGFloat]=[:]
    private var layoutCache:[CueTextLayoutKey:CGFloat]=[:]
    private let measurementStorage=NSTextStorage()
    private let measurementLayout=NSLayoutManager()
    private let measurementContainer=NSTextContainer(size:.zero)
    private var measurementReady=false
    private func syncRenderingWidth() {
        let scale=max(1,window?.backingScaleFactor ?? 2)
        let width=max(1,floor(bounds.width*scale)/scale)
        textContainer?.widthTracksTextView=false
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
            needsDisplay=true
        }
    }
    override func setFrameSize(_ newSize:NSSize) {super.setFrameSize(newSize);syncRenderingWidth()}
    override func layout() {super.layout();syncRenderingWidth()}
    private(set) var attributeBuilds=0
    private(set) var layoutBuilds=0
    func apply(text:String,fontSize:Double,lineSpacing:Double) {
        let key=ContentKey(text:text,size:fontSize,spacing:lineSpacing)
        guard contentKey != key else{return}
        PerformanceTrace.measure("reader.attributedText") {
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=lineSpacing
            textStorage?.setAttributedString(NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]))
            contentKey=key;heights.removeAll(keepingCapacity:true);layoutCache.removeAll(keepingCapacity:true);invalidateIntrinsicContentSize();attributeBuilds += 1;setAccessibilityLabel(text)
        }
    }
    func measuredSize(width:Double,fontSize:Double)->CGSize? {
        let scale=max(1,window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        // SwiftUI can issue speculative widths after assigning the final frame.
        // Measuring must never mutate the live text container or its selection.
        let width=max(1,floor(width*scale)/scale)
        let key=CueTextLayoutKey(text:contentKey?.text ?? string,width:width,
                                 fontSize:contentKey?.size ?? fontSize,lineSpacing:contentKey?.spacing ?? 0,scale:scale)
        if let height=layoutCache[key] {return CGSize(width:width,height:height)}
        return PerformanceTrace.measure("reader.layout") {
            guard let storage=textStorage else{return nil}
            if !measurementReady {
                measurementStorage.addLayoutManager(measurementLayout)
                measurementLayout.addTextContainer(measurementContainer)
                measurementContainer.lineFragmentPadding=0
                measurementContainer.widthTracksTextView=false
                measurementReady=true
            }
            if !measurementStorage.isEqual(to:storage) {measurementStorage.setAttributedString(storage)}
            let layout=measurementLayout,container=measurementContainer
            container.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for:container);layoutBuilds += 1
            var bottom=layout.usedRect(for:container).maxY
            if layout.extraLineFragmentTextContainer === container {bottom=max(bottom,layout.extraLineFragmentUsedRect.maxY)}
            let height=ceil(max(NSFont.systemFont(ofSize:fontSize).boundingRectForFont.height,bottom)*scale)/scale
            if layoutCache.count>=16 {layoutCache.removeAll(keepingCapacity:true);heights.removeAll(keepingCapacity:true)}
            layoutCache[key]=height;heights[width]=height
            return CGSize(width:width,height:height)
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
