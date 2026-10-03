import Foundation

public struct RequestNotDispatched: Error, Sendable {public init(){}}
/// Shared by all generation entry points. A lease lasts through validation and durable save.
public actor RequestScheduler {
    public struct Lease: Sendable { public let id:UUID; public let queueSeconds:Double }
    private struct Waiter {let id:UUID;let lesson:UUID;let serial:String?;let since:Date;let continuation:CheckedContinuation<Lease,Error>}
    private let limit:Int
    private var active:[UUID:String]=[:]
    private var waiting:[Waiter]=[]
    private var stopped=false
    private var lastLesson:UUID?
    public init(limit:Int=2) {self.limit=max(1,limit)}
    public var activeCount:Int {active.count}
    public func resume() {guard active.isEmpty,waiting.isEmpty else{return};stopped=false}
    public func pause() {
        stopped=true;let old=waiting;waiting=[]
        for waiter in old {waiter.continuation.resume(throwing:RequestNotDispatched())}
    }
    public func acquire(lesson:UUID,serial:String?=nil) async throws -> Lease {
        let id=UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !stopped,!Task.isCancelled else {continuation.resume(throwing:RequestNotDispatched());return}
                waiting.append(Waiter(id:id,lesson:lesson,serial:serial,since:Date(),continuation:continuation));dispatch()
            }
        } onCancel: {Task {await self.cancel(id)}}
    }
    private func cancel(_ id:UUID) {
        if let i=waiting.firstIndex(where:{$0.id==id}) {waiting.remove(at:i).continuation.resume(throwing:RequestNotDispatched())}
    }
    public func release(_ lease:Lease) {active[lease.id]=nil;dispatch()}
    private func dispatch() {
        while !stopped,active.count<limit {
            let available=waiting.indices.filter {i in waiting[i].serial.map{!active.values.contains($0)} ?? true}
            guard let index=available.first(where:{waiting[$0].lesson != lastLesson}) ?? available.first else{return}
            let item=waiting.remove(at:index);lastLesson=item.lesson;active[item.id]=item.serial ?? ""
            item.continuation.resume(returning:Lease(id:item.id,queueSeconds:Date().timeIntervalSince(item.since)))
        }
    }
}
