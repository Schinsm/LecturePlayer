import Foundation

/// Metadata is a validation hint, never a replacement for hashing a changed file.
public actor MediaFingerprintCache {
    private struct Entry:Codable {let stamp:FileStamp;let hash:String}
    private var entries:[String:Entry]=[:]
    private var pending:[FileStamp:Task<String,Error>]=[:]
    public static let fileWorkers=RequestScheduler(limit:2)
    private let workers=MediaFingerprintCache.fileWorkers
    private let storage:URL?
    public private(set) var hashReads=0
    public private(set) var cacheHits=0
    public init(storage:URL?=nil) {
        self.storage=storage
        if let storage,let data=try? Data(contentsOf:storage),let saved=try? JSONDecoder().decode([String:Entry].self,from:data) {entries=saved}
    }
    public func hash(_ url:URL) async throws -> String {
        let stamp=try FileStamp.read(url),key=stamp.identity
        if let cached=entries[key],cached.stamp==stamp {cacheHits += 1;return cached.hash}
        if let task=pending[stamp] {
            let value = try await task.value
            guard try FileStamp.read(url)==stamp else {throw Failure("校验期间文件改变")}
            cacheHits += 1;return value
        }
        let task=Task.detached(priority:.utility) { [workers] in
            let lease=try await workers.acquire(lesson:UUID())
            do {
                let value=try DirectoryIndex.hash(url)
                guard try FileStamp.read(url)==stamp else {throw Failure("校验期间文件改变："+url.lastPathComponent)}
                await workers.release(lease);return value
            } catch {await workers.release(lease);throw error}
        }
        pending[stamp]=task;hashReads += 1
        do {
            let value=try await task.value
            entries[key]=Entry(stamp:stamp,hash:value);pending[stamp]=nil
            if entries.count>4096 {entries=entries.filter{$0.key==key}}
            if let storage {
                try? FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true)
                if let data=try? JSONEncoder().encode(entries) {try? data.write(to:storage,options:.atomic)}
            }
            return value
        } catch {pending[stamp]=nil;throw error}
    }
}
