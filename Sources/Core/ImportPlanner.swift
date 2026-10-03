import Foundation
public enum ImportPlanner {
    public static let media:Set<String>=["mp4","mov"]
    public static let subtitles:Set<String>=["vtt","srt","txt"]
    public static func includes(_ url: URL) -> Bool { !url.lastPathComponent.hasPrefix(".") && !isGenerated(url) }
    public static func requireLocal(_ url:URL) throws {
        let values=try url.resourceValues(forKeys:[.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem==true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {throw Failure("文件尚未下载到本地。请先在 Finder 中下载，再导入或播放。")}
        guard FileManager.default.isReadableFile(atPath:url.path) else{throw Failure("文件无法读取，请重新定位或授权")}
    }
    public static func scan(_ roots:[URL]) throws->[URL] {
        var files:[URL]=[];let keys:Set<URLResourceKey>=[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.isHiddenKey]
        for root in roots {
            let values=try root.resourceValues(forKeys:keys)
            guard includes(root), values.isSymbolicLink != true else{continue}
            if values.isDirectory==true {
                var scanError:Error?
                guard let iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{_,error in scanError=error;return false}) else{throw Failure("无法扫描所选目录")}
                while let url=iterator.nextObject() as? URL {let v=try url.resourceValues(forKeys:keys);if !includes(url) || v.isSymbolicLink==true {iterator.skipDescendants();continue};if v.isRegularFile==true && (media.union(subtitles)).contains(url.pathExtension.lowercased()) {files.append(url)}}
                if let scanError{throw scanError}
            } else if media.union(subtitles).contains(root.pathExtension.lowercased()){files.append(root)}
        }
        return Array(Set(files.filter { !isGenerated($0) })).sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
    }
    public static func candidates(for video:URL,in files:[URL])->[URL] {
        let matched=files.filter{subtitles.contains($0.pathExtension.lowercased()) && !isGenerated($0) && (normalized($0)==normalized(video) || echoStem($0)==echoStem(video))}
        let adjacent=matched.filter{$0.deletingLastPathComponent()==video.deletingLastPathComponent()}
        return adjacent.isEmpty ? matched : adjacent
    }
    static func echoStem(_ url: URL) -> String {
        normalized(url).replacingOccurrences(of: "[._ -](s[12][._ -]full|transcript)$", with: "", options: .regularExpression)
    }
    public static func role(for url: URL) -> MediaRole? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let s1 = name.range(of: "(?:^|[._ -])s1(?=$|[._ -])", options: .regularExpression) != nil
        let s2 = name.range(of: "(?:^|[._ -])s2(?=$|[._ -])", options: .regularExpression) != nil
        return s1 == s2 ? nil : (s1 ? .screen : .camera)
    }
    public static func captureKey(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: "(^|[._ -])s[12](?=$|[._ -])", with: "$1view", options: .regularExpression)
    }
    public static func companion(for url: URL, in files: [URL]) -> URL? {
        guard let role = role(for: url) else { return nil }
        let group = Array(Set(files)).filter { media.contains($0.pathExtension.lowercased()) && $0.deletingLastPathComponent() == url.deletingLastPathComponent() && captureKey($0) == captureKey(url) }
        guard group.count == 2 else { return nil }
        return group.first { $0 != url && self.role(for: $0) != nil && self.role(for: $0) != role }
    }
    public static func isGenerated(_ url: URL) -> Bool { url.lastPathComponent.contains(".lectureplayer-") }
    static func normalized(_ url:URL)->String {url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of:"[._ -](en|eng|english|en-us|en-au|en-gb)$",with:"",options:.regularExpression)}
}
