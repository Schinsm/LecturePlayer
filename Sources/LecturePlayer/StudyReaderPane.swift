import SwiftUI
import Core

struct ReaderSourceRequest: Equatable {var id = UUID(); var cueID: String}

struct StudyReaderPane: View {
    @AppStorage("readerPaneVisible") private var readerVisible = true
    @ObservedObject var store: AppStore
    let playback: Playback
    @LPState private var sourceRequest: ReaderSourceRequest?
    @ObservedObject private var session:ReaderSession
    init(store:AppStore,playback:Playback){self.store=store;self.playback=playback;session=store.readerPresentation.session(store.current ?? UUID())}
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                AnalysisPanel(store:store,job:store.analysis,translation:store.translation,playback:playback,visible:readerVisible) {cueID in
                    sourceRequest=ReaderSourceRequest(cueID:cueID)
                }
                .frame(height:session.chapterDirectoryExpanded ? min(440,geometry.size.height * 0.45) : min(190,geometry.size.height * 0.30))
                .clipped()
                Divider()
                ReaderPane(store:store,playback:playback,visible:readerVisible,sourceRequest:sourceRequest)
                    .frame(maxHeight:.infinity)
            }
        }
    }
}
