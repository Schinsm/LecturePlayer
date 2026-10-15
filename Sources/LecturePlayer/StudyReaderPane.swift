import SwiftUI
import Core

struct ReaderSourceRequest: Equatable {var id=UUID();var cueID:String}

struct ChapterColumn:View {
    @ObservedObject var store:AppStore
    @ObservedObject private var columns:ReadingColumns
    init(store:AppStore){self.store=store;columns=store.readingColumns}
    var body:some View {
        AnalysisPanel(store:store,job:store.analysis,translation:store.translation,playback:store.playback,visible:columns.visible(.chapters)) {cueID in
            guard let id=store.current else{return}
            columns.show(.transcript)
            store.readerPresentation.session(id).sourceRequest=ReaderSourceRequest(cueID:cueID)
        }
    }
}
struct TranscriptColumn:View {
    @ObservedObject var store:AppStore
    @ObservedObject private var columns:ReadingColumns
    @ObservedObject private var session:ReaderSession
    init(store:AppStore){self.store=store;columns=store.readingColumns;session=store.readerPresentation.session(store.current ?? UUID())}
    var body:some View {ReaderPane(store:store,playback:store.playback,visible:columns.visible(.transcript),sourceRequest:session.sourceRequest)}
}
