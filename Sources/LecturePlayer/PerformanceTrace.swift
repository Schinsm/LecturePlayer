import Foundation

/// Opt-in, numeric diagnostics only. Never records transcript content or credentials.
enum PerformanceTrace {
    static let enabled = ProcessInfo.processInfo.environment["LP_PERFORMANCE"] == "1"
    private static let queue=DispatchQueue(label:"LecturePlayer.performance",qos:.utility)
    static func record(_ name:String,_ seconds:Double) {
        guard enabled else{return}
        queue.async {
            guard let path=ProcessInfo.processInfo.environment["LP_PERFORMANCE_LOG"],let data=try? JSONSerialization.data(withJSONObject:["event":name,"seconds":seconds,"time":Date().timeIntervalSince1970]) else{return}
            let url=URL(fileURLWithPath:path)
            // At most two 1 MB files, with room for the current numeric event.
            if let bytes=(try? FileManager.default.attributesOfItem(atPath:path)[.size]) as? NSNumber,bytes.intValue+data.count+1>1_000_000 {
                let previous=url.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at:previous)
                try? FileManager.default.moveItem(at:url,to:previous)
            }
            if !FileManager.default.fileExists(atPath:path) {FileManager.default.createFile(atPath:path,contents:nil)}
            guard let f=try? FileHandle(forWritingTo:url) else{return};defer{try? f.close()}
            _ = try? f.seekToEnd();try? f.write(contentsOf:data+Data([10]))
        }
    }
    static func measure<T>(_ name:String,_ body:() throws->T) rethrows->T {
        let start=ProcessInfo.processInfo.systemUptime;defer{record(name,ProcessInfo.processInfo.systemUptime-start)};return try body()
    }
}
final class MainThreadProbe {
    private var timer:DispatchSourceTimer?
    init() {
        guard PerformanceTrace.enabled else{return}
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"LecturePlayer.heartbeat"));self.timer=timer
        timer.schedule(deadline:.now()+1,repeating:0.05)
        let gate=ClockDeliveryGate()
        timer.setEventHandler {guard gate.begin() else{return};let sent=ProcessInfo.processInfo.systemUptime;DispatchQueue.main.async {gate.end();PerformanceTrace.record("main.queueDelay",ProcessInfo.processInfo.systemUptime-sent)}}
        timer.resume()
    }
    deinit{timer?.cancel()}
}
