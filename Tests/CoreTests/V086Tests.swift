import Foundation
import Testing
@testable import Core

@Suite(.serialized) struct V086CoreTests {
    @Test func schedulerBoundsSerialResourcesPauseAndCancellation() async throws {
        let scheduler=RequestScheduler(),a=UUID(),b=UUID()
        let first=try await scheduler.acquire(lesson:a,serial:"azure")
        let same=Task{try await scheduler.acquire(lesson:b,serial:"azure")}
        let other=try await scheduler.acquire(lesson:b)
        #expect(await scheduler.activeCount==2)
        let waiting=Task{try await scheduler.acquire(lesson:a)}
        try await Task.sleep(for:.milliseconds(20))
        await scheduler.pause();await scheduler.release(first);await scheduler.release(other)
        do {_ = try await same.value;Issue.record("Paused request was dispatched")} catch {}
        do {_ = try await waiting.value;Issue.record("Paused request was dispatched")} catch {}
        #expect(await scheduler.activeCount==0)
        await scheduler.resume()
        let x=try await scheduler.acquire(lesson:a),y=try await scheduler.acquire(lesson:b)
        let cancelled=Task{try await scheduler.acquire(lesson:a)}
        cancelled.cancel();await scheduler.release(x);await scheduler.release(y)
        do {_ = try await cancelled.value;Issue.record("Cancelled waiter dispatched")} catch {}
    }
    @Test func fingerprintDedupPersistsAndInvalidatesSameSizeChange() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("sample.mp4"),db=root.appendingPathComponent("cache.json")
        try Data(repeating:65,count:8_000_000).write(to:file)
        let cache=MediaFingerprintCache(storage:db)
        async let a=cache.hash(file);async let b=cache.hash(file)
        let (one,two)=try await(a,b);#expect(one==two);#expect(await cache.hashReads==1)
        let reopen=MediaFingerprintCache(storage:db)
        #expect(try await reopen.hash(file)==one);#expect(await reopen.hashReads==0)
        let stamp=try FileStamp.read(file)
        try Data(repeating:66,count:8_000_000).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:stamp.modified],ofItemAtPath:file.path)
        #expect(try FileStamp.read(file).changed != stamp.changed)
        #expect(try await reopen.hash(file) != one);#expect(await reopen.hashReads==1)
        let dest=root.appendingPathComponent("copied.mp4")
        #expect(try MediaCopy.copy(from:file,to:dest)==DirectoryIndex.hash(dest))
    }
}
