import Foundation
import SwiftData
import Core

/// Values cross this boundary; ModelContext/MetadataRecord never do.
final class MetadataCommitQueue: @unchecked Sendable {
    private let queue=DispatchQueue(label:"LecturePlayer.metadata",qos:.utility)
    private let container:ModelContainer
    private var pending:[UUID:[String:Any]]=[:]
    private var lastError:Error?
    private var pendingLast: Data?
    init(container:ModelContainer){self.container=container}
    static func difference(_ old:Any,_ new:Any)->[String:Any] {
        guard let before=old as? [String:Any],let after=new as? [String:Any] else{return [:]}
        var patch:[String:Any]=[:]
        for key in Set(before.keys).union(after.keys) {
            let a=before[key] ?? NSNull(),b=after[key] ?? NSNull()
            if let x=a as? NSDictionary,let y=b as? NSDictionary {let child=difference(x,y);if !child.isEmpty{patch[key]=child}}
            else if !NSDictionary(dictionary:["v":a]).isEqual(to:["v":b]) {patch[key]=b}
        }
        return patch
    }
    static func merge(_ patch:[String:Any],into value:[String:Any])->[String:Any] {
        var result=value
        for (key,item) in patch {
            if let child=item as? [String:Any] {result[key]=merge(child,into:result[key] as? [String:Any] ?? [:])}
            else if item is NSNull {result.removeValue(forKey:key)} else {result[key]=item}
        };return result
    }
    func submit(old:Lecture,new:Lecture,completion:@escaping (Error?)->Void) {
        queue.async { [self] in
            do {
                let patch=Self.difference(try JSONSerialization.jsonObject(with:Codec.encode(old)),try JSONSerialization.jsonObject(with:Codec.encode(new)))
                // Compose patches without dropping deletion markers.
                pending[new.id]=Self.compose(pending[new.id] ?? [:],patch)
                if let lastError {throw lastError}
                try commit();lastError=nil;DispatchQueue.main.async{completion(nil)}
            }catch{lastError=error;DispatchQueue.main.async{completion(error)}}
        }
    }
    private static func compose(_ first:[String:Any],_ next:[String:Any])->[String:Any] {
        var result=first;for (k,v) in next {if let child=v as? [String:Any] {result[k]=compose(result[k] as? [String:Any] ?? [:],child)}else{result[k]=v}};return result
    }
    private func commit() throws {
        guard !pending.isEmpty || pendingLast != nil else{return}
        try PerformanceTrace.measure("metadata.commit") {
            let context=ModelContext(container);context.autosaveEnabled=false
            for (id,patch) in pending where !patch.isEmpty {
                let key="l-\(id)"
                var fetch=FetchDescriptor<MetadataRecord>(predicate:#Predicate{$0.key == key});fetch.fetchLimit=1
                guard let row=try context.fetch(fetch).first else{throw Failure("课件元数据已不存在，尚未保存本次调整")}
                let old=try JSONSerialization.jsonObject(with:row.payload) as? [String:Any] ?? [:]
                row.payload=try JSONSerialization.data(withJSONObject:Self.merge(patch,into:old),options:[.sortedKeys])
            }
            if let payload=pendingLast {
                let key="last"; var fetch=FetchDescriptor<MetadataRecord>(predicate:#Predicate{$0.key == key}); fetch.fetchLimit=1
                if let row=try context.fetch(fetch).first { row.payload=payload } else { context.insert(MetadataRecord(key:key,payload:payload)) }
            }
            do{try context.save();pending.removeAll();pendingLast=nil}catch{context.rollback();throw error}
        }
    }
    func setLastLesson(_ id: UUID, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do { pendingLast=try Codec.encode(Optional(id)); if let lastError {throw lastError}; try commit(); DispatchQueue.main.async {completion(nil)} }
            catch {lastError=error;DispatchQueue.main.async {completion(error)}}
        }
    }
    func flushAsync() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in do {try commit();lastError=nil;c.resume()} catch {lastError=error;c.resume(throwing:error)} }
        }
    }
    /// Used only at explicit durable boundaries, never in view rendering.
    func flush() throws {try queue.sync {do{try commit();lastError=nil}catch{lastError=error;throw error}}}
}
