import Foundation
import Darwin

public enum FileSaveOutcome:String,Sendable {case unchanged,written,conflict,failed}
public struct SidecarWriteReport:Sendable {
    public var files:[String:String];public var outcome:FileSaveOutcome
    public var writes:Int=0;public var bytes:Int=0
    public var records:[GeneratedFileRecord]=[]
}
public struct StorageIssue:Error,LocalizedError,Sendable {
    public enum Kind:String,Sendable {case noSpace,permission,unavailable,conflict,unknown}
    public let kind:Kind
    public init(_ kind:Kind){self.kind=kind}
    public init(_ error:Error) {
        if let issue=error as? StorageIssue {self=issue;return}
        var e=error as NSError
        for _ in 0..<8 {if let underlying=e.userInfo[NSUnderlyingErrorKey] as? NSError {e=underlying}else{break}}
        switch (e.domain,e.code) {
        case (NSPOSIXErrorDomain,Int(ENOSPC)),(NSCocoaErrorDomain,NSFileWriteOutOfSpaceError):kind = .noSpace
        case (NSPOSIXErrorDomain,Int(EACCES)),(NSPOSIXErrorDomain,Int(EPERM)),(NSPOSIXErrorDomain,Int(EROFS)),(NSCocoaErrorDomain,NSFileWriteNoPermissionError):kind = .permission
        case (NSPOSIXErrorDomain,Int(ENOENT)),(NSPOSIXErrorDomain,Int(ENOTDIR)),(NSCocoaErrorDomain,NSFileNoSuchFileError),(NSCocoaErrorDomain,NSFileReadNoSuchFileError):kind = .unavailable
        default:kind = .unknown
        }
    }
    public var errorDescription:String? {
        switch kind {
        case .noSpace:return "磁盘空间不足，请释放空间后重试保存。"
        case .permission:return "没有写入权限，请重新授权或选择可写目录后重试。"
        case .unavailable:return "文件或目录不可用，请检查文件位置后重试。"
        case .conflict:return "文件已被人工修改，已保留原文件；请选择其他保存位置。"
        case .unknown:return "保存失败，原因尚不明确。请检查诊断记录后重试保存。"
        }
    }
}
/// Fixed vocabulary only: never accepts paths, response bodies, subtitle text or credentials.
public enum StorageDiagnostics {
    public enum Operation:String {case scan,sidecar,transcript,metadata}
    private static let lock=NSLock()
    public static let capacity=65_536
    public static func record(root:URL,operation:Operation,outcome:FileSaveOutcome,bytes:Int=0,count:Int=1,error:Error?=nil) {
        lock.lock();defer{lock.unlock()}
        var entry:[String:Any]=["time":Date().timeIntervalSince1970,"operation":operation.rawValue,"outcome":outcome.rawValue,"bytes":bytes,"count":count]
        if let error {entry["category"]=StorageIssue(error).kind.rawValue;entry["code"]=(error as NSError).code}
        do {
            let dir=root.appendingPathComponent("Diagnostics");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let file=dir.appendingPathComponent("storage.jsonl"),old=dir.appendingPathComponent("storage.previous.jsonl")
            var line=try JSONSerialization.data(withJSONObject:entry,options:.sortedKeys);line.append(10)
            if (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 > capacity-line.count {
                if FileManager.default.fileExists(atPath:old.path){try FileManager.default.removeItem(at:old)}
                try FileManager.default.moveItem(at:file,to:old)
            }
            if !FileManager.default.fileExists(atPath:file.path){try Data().write(to:file,options:.withoutOverwriting)}
            let handle=try FileHandle(forWritingTo:file);defer{try? handle.close()};try handle.seekToEnd();try handle.write(contentsOf:line)
        }catch { /* Diagnostic failure must never retry or block saving course data. */ }
    }
}
