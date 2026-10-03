import Foundation
import AVFoundation
import Testing
@testable import Core
@testable import LecturePlayer
@Suite(.serialized) @MainActor struct V082LocalLoadTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP082_LOCAL_LOAD"] == "1"))
    func dualPlaybackDuringAuthorizedLocalEvaluation() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/LP082/data"),repo=try Repository(root:root),library=try repo.load()
        var lesson=try #require(library.lectures.first{$0.mediaSources.count==2 && $0.mediaSources.allSatisfy{FileManager.default.fileExists(atPath:$0.path)}})
        lesson.sources=lesson.mediaSources.map{var s=$0;s.bookmark=nil;return s};lesson.bookmark=nil;lesson.state.position=90;lesson.state.speed=1
        let defaults=UserDefaults(suiteName:"LP082-Benchmark-"+UUID().uuidString)!
        defaults.set(0.0,forKey:"playbackVolume")
        let playback=Playback(preferences:defaults);playback.load(lesson)
        defer {playback.close()}
        for _ in 0..<200 {if playback.ready {break};try await Task.sleep(for:.milliseconds(50))}
        try #require(playback.ready)
        let players=[playback.player,playback.secondaryPlayer]
        let outputs=players.map {player in
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            player.currentItem?.add(output);return output
        }
        playback.toggle()
        let directory=URL(fileURLWithPath:"/private/tmp/LP082")
        try Data("ready".utf8).write(to:directory.appendingPathComponent("dual.ready"))
        let start=Date();var frames=[0,0],samples=0,maxDrift=0.0,maxDelay=0.0
        while Date().timeIntervalSince(start)<900 && !FileManager.default.fileExists(atPath:directory.appendingPathComponent("dual.done").path) {
            let began=Date();try await Task.sleep(for:.milliseconds(33))
            maxDelay=max(maxDelay,Date().timeIntervalSince(began)-0.033)
            for i in 0..<2 {
                let time=players[i].currentTime()
                if outputs[i].hasNewPixelBuffer(forItemTime:time),outputs[i].copyPixelBuffer(forItemTime:time,itemTimeForDisplay:nil) != nil {frames[i]+=1}
            }
            if playback.playing && !playback.waiting {maxDrift=max(maxDrift,abs(players[0].currentTime().seconds-players[1].currentTime().seconds))}
            samples+=1
        }
        let data:[String:Any]=["seconds":Date().timeIntervalSince(start),"decodedFrames":frames,"samples":samples,"maxMainActorDelaySeconds":maxDelay,"maxClockDifferenceSeconds":maxDrift,"finalPosition":playback.position,"muted":players.allSatisfy{$0.volume==0},"visualGUI":false]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("dual-playback.json"))
        #expect(frames.allSatisfy{$0>30})
        #expect(players.allSatisfy{$0.volume==0})
        #expect(FileManager.default.fileExists(atPath:directory.appendingPathComponent("dual.done").path))
    }
}
