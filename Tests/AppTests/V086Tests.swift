import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V086AppTests {
    @Test func bilingualLayoutUsesCurrentContentAndFullMeasuredHeight() throws {
        let storage=NSTextStorage(),layout=NSLayoutManager(),container=NSTextContainer(size:.zero)
        storage.addLayoutManager(layout);layout.addTextContainer(container);container.lineFragmentPadding=0;container.widthTracksTextView=false
        let view=SelectableCueView(frame:.zero,textContainer:container);view.textContainerInset = .zero
        let source="So once we have forecast, how do we turn them into an estimate of what the company is worth?\n那么，一旦我们完成预测，如何将这些预测转化为对公司价值的估计？"
        for size in [14.0,22,32] {for width in [210.0,360,577,800] {
            view.apply(text:source,fontSize:size,lineSpacing:6)
            let measured=try #require(view.measuredSize(width:width,fontSize:size))
            view.frame=NSRect(origin:.zero,size:measured)
            layout.ensureLayout(for:container)
            #expect(layout.usedRect(for:container).maxY<=measured.height)
            #expect(container.containerSize.width==measured.width)
            #expect(layout.numberOfGlyphs==storage.length)
        }}
        view.apply(text:"Short",fontSize:18,lineSpacing:3)
        let short=try #require(view.measuredSize(width:300,fontSize:18))
        view.apply(text:source,fontSize:18,lineSpacing:3)
        let long=try #require(view.measuredSize(width:300,fontSize:18))
        #expect(long.height>short.height)
        #expect(view.heights.count==1)
    }
    @Test func hostedRowsStayInsideTheirFramesAfterWidthAndContentChanges() async throws {
        let model=LayoutFixture()
        let host=NSHostingView(rootView:LayoutFixtureView(model:model))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:1600),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=host
        defer {window.contentView=nil}
        func textViews(_ view:NSView)->[SelectableCueView] {(view as? SelectableCueView).map{[$0]} ?? view.subviews.flatMap(textViews)}
        for width in [600.0,250,430] {
            window.setContentSize(NSSize(width:width,height:1600))
            for font in [17.0,30] {
                model.font=font;model.suffix=String(repeating:"估值需要预测未来的现金流和折现率。 ",count:4)
                try await Task.sleep(for:.milliseconds(60));host.layoutSubtreeIfNeeded()
                let rows=textViews(host);try #require(rows.count==2)
                for view in rows {
                    let manager=try #require(view.layoutManager),container=try #require(view.textContainer)
                    // A later speculative measurement must not squeeze the rendered row.
                    _ = view.measuredSize(width:55,fontSize:font)
                    manager.ensureLayout(for:container)
                    #expect(manager.usedRect(for:container).maxY<=view.bounds.height+1)
                    #expect(abs(container.containerSize.width-view.bounds.width)<1)
                }
                let frames=rows.map{$0.convert($0.bounds,to:host)}
                #expect(!frames[0].intersects(frames[1]))
            }
        }
    }
    @Test func latestLibraryRoundTripAndQAConfiguration() async throws {
        guard ProcessInfo.processInfo.environment["LP086_ACCEPTANCE"]=="1" else{return}
        let root=URL(fileURLWithPath:"/private/tmp/LP086/baseline-data")
        let destination=URL(fileURLWithPath:"/private/tmp/LP086/regression-data")
        try? FileManager.default.removeItem(at:destination);try FileManager.default.copyItem(at:root,to:destination)
        let repo=try Repository(root:destination),before=try repo.load()
        let transcripts=try before.lectures.compactMap{try repo.read($0)},analyses=try AnalysisRepository.readAll(root:destination)
        let snapshot=destination.appendingPathComponent("before-v086-test.json")
        try repo.writeRecoverySnapshot(before,to:snapshot);try repo.save(before)
        #expect(try Repository(root:destination).load()==before)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        #expect(try AnalysisRepository.readAll(root:destination)==analyses)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:snapshot));try backup.validate()
        #expect(backup.library.lectures.map(\.state)==before.lectures.map(\.state))
        print("LP086 preservation: lessons=\(before.lectures.count), cues=\(transcripts.reduce(0){$0+$1.cues.count}), translations=\(transcripts.reduce(0){$0+$1.translatedCount}), analyses=\(analyses.count)")
    }
}

@MainActor private final class LayoutFixture:ObservableObject {
    @Published var font=17.0
    @Published var suffix=""
}
private struct LayoutFixtureView:View {
    @ObservedObject var model:LayoutFixture
    var body:some View {
        VStack(spacing:18) {
            ForEach(0..<2,id:\.self) {i in
                VStack(alignment:.leading,spacing:7) {
                    Text("00:00:29").font(.caption)
                    CueText(text:"So once we have forecast, how do we convert them into an estimate of what the company is worth?\n那么，一旦我们完成预测，如何将这些预测转化为对公司价值的估计？"+model.suffix,fontSize:model.font,lineSpacing:5,jump:{},browse:{})
                }.padding(10).frame(maxWidth:.infinity).background(i==0 ? Color.blue.opacity(0.14):Color.clear)
            }
            Spacer(minLength:0)
        }.padding(12)
    }
}
