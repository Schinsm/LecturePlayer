import Foundation
import CryptoKit

public enum MediaCopy {
    /// Copies into a new destination only. Partial files are removed on all failure paths.
    @discardableResult public static func copy(from source: URL, to destination: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw Failure("目标文件已存在，不会覆盖") }
        let stamp=try FileStamp.read(source)
        let originalAttributes = try fm.attributesOfItem(atPath: source.path)
        let total = (originalAttributes[.size] as? NSNumber)?.int64Value ?? 0
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capacity = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < total { throw Failure("媒体目录磁盘空间不足") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID())")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw Failure("无法创建媒体文件，请检查空间和权限") }
        defer { try? fm.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: data); hash.update(data: data); count += Int64(data.count)
            progress(total > 0 ? Double(count) / Double(total) * 0.8 : 0)
        }
        try output.synchronize(); try output.close()
        let afterAttributes = try fm.attributesOfItem(atPath: source.path)
        guard count == total, afterAttributes[.modificationDate] as? Date == originalAttributes[.modificationDate] as? Date else { throw Failure("源文件复制期间发生变化") }
        let check = try FileHandle(forReadingFrom: temporary); defer { try? check.close() }
        var verification = SHA256(); var verified: Int64 = 0
        while let data = try check.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); verification.update(data: data); verified += Int64(data.count)
            progress(0.8 + (total > 0 ? Double(verified) / Double(total) * 0.2 : 0))
        }
        let fingerprint=hash.finalize()
        guard try FileStamp.read(source)==stamp else {throw Failure("源文件复制期间发生变化")}
        guard fingerprint == verification.finalize() else { throw Failure("媒体校验失败") }
        try Task.checkCancellation(); try fm.moveItem(at: temporary, to: destination); progress(1)
        return fingerprint.map{String(format:"%02x",$0)}.joined()
    }
}
