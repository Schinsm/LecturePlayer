import Foundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V0874Benchmark {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP0874_BENCH"] == "1"))
    func isolatedOpenTimings() async throws {
        let tag=ProcessInfo.processInfo.environment["LP_BENCH_TAG"] ?? "new"
        let base=URL(fileURLWithPath:"/private/tmp/LP0874/baseline-data")
        let root=URL(fileURLWithPath:"/private/tmp/LP0874/benchmark-"+tag+"-"+UUID().uuidString)
        try FileManager.default.copyItem(at:base,to:root)
        let repo=try Repository(root:root);var fixture=try repo.load()
        for i in fixture.lectures.indices {
            fixture.lectures[i].bookmark=nil
            var sources=fixture.lectures[i].mediaSources
            for j in sources.indices {sources[j].bookmark=nil};fixture.lectures[i].mediaSources=sources
        }
        fixture.lastLecture=nil;try repo.save(fixture)
        let store=AppStore(root:root);defer{store.back()}
        store.playback.player.isMuted=true;store.playback.secondaryPlayer.isMuted=true
        let lessons=store.library.lectures.filter{$0.transcriptVersion != nil}.sorted{$0.id.uuidString<$1.id.uuidString}
        var samples:[[String:Any]]=[]
        for mode in ["paused","dualPlayback","mockSave"] {
            for round in 0..<3 {
                for i in 0..<10 {
                    let lesson=lessons[i % lessons.count]
                    if mode=="dualPlayback",store.playback.ready {store.playback.toggle();try await Task.sleep(for:.milliseconds(100))}
                    var writer:Task<Void,Never>?
                    if mode=="mockSave",let version=lesson.transcriptVersion {
                        let file=try store.repository!.transcriptURL(lesson.id,version)
                        writer=Task.detached {
                            // Mock durable atomic results; no service calls or altered business content.
                            if let bytes=try? Data(contentsOf:file) { for _ in 0..<10 {try? bytes.write(to:file,options:.atomic);try? await Task.sleep(for:.milliseconds(30))} }
                        }
                    }
                    let start=ProcessInfo.processInfo.systemUptime
                    store.open(lesson.id)
                    let synchronous=ProcessInfo.processInfo.systemUptime-start
                    await Task.yield()
                    let firstTurn=ProcessInfo.processInfo.systemUptime-start
                    for _ in 0..<500 {if store.transcript?.version==lesson.transcriptVersion && store.playback.ready {break};try await Task.sleep(for:.milliseconds(10))}
                    let full=ProcessInfo.processInfo.systemUptime-start
                    samples.append(["mode":mode,"round":round,"index":i,"synchronous":synchronous,"firstTurn":firstTurn,"full":full])
                    await writer?.value
                }
            }
        }
        try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/private/tmp/LP0874/benchmark-"+tag+".json"))
    }
}
