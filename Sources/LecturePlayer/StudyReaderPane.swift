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
    private var panel: String {session.panel == "chapters" ? "chapters" : "transcript"}
    var body: some View {
        VStack(spacing: 0) {
            Picker("转写或章节", selection: Binding(get: {panel}, set: setPanel)) {
                Text("转写").tag("transcript"); Text("章节").tag("chapters")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.top, 10)
                .accessibilityLabel("转写或章节")
            // Both views keep their identity, so changing tabs does not reset search or scroll state.
            ZStack {
                ReaderPane(store: store, playback: playback, visible: readerVisible && panel == "transcript", sourceRequest: sourceRequest)
                    .opacity(panel == "transcript" ? 1 : 0).allowsHitTesting(panel == "transcript").accessibilityHidden(panel != "transcript")
                AnalysisPanel(store: store, job: store.analysis, translation: store.translation, playback: playback, visible:readerVisible && panel == "chapters") {cueID in
                    setPanel("transcript"); sourceRequest = ReaderSourceRequest(cueID: cueID)
                }.opacity(panel == "chapters" ? 1 : 0).allowsHitTesting(panel == "chapters").accessibilityHidden(panel != "chapters")
            }
        }
    }
    private func setPanel(_ value: String) {if let id = store.current {store.readerPresentation.select(value,lesson:id)}}
}
