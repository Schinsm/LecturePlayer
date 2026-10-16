import SwiftUI
import AVFoundation
import Core
import Darwin

struct ThumbnailRequest:Sendable {
    let source:MediaSource
    static func source(for lesson:Lecture)->MediaSource? {
        lesson.mediaSources.sorted { $0.role == .screen && $1.role != .screen }.first { FileManager.default.fileExists(atPath:$0.path) }
    }
    static func time(duration:Double)->Double { duration > 30 ? 30 : max(0,duration / 2) }
    func key(at seconds:Double)->String {
        // Only basic stat metadata is needed. attributesOfItem also reads extended
        // attributes, which can block indefinitely for file-provider files.
        var info = stat()
        let found = source.path.withCString { stat($0, &info) } == 0
        let version=(source.contentHash ?? "") + "-\(found ? info.st_size : 0)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        return digest("\(source.id)-\(version)-\(seconds)-256x144-v1")
    }
}
actor ThumbnailRenderer {
    static let shared=ThumbnailRenderer()
    nonisolated(unsafe) static var cloudRecheck:Duration = .seconds(3)
    /// One lstat off the main thread; never downloads.
    nonisolated static func stillInCloud(_ path:String) async -> Bool {
        await Task.detached(priority:.utility) {CloudFile.isOnlineOnly(URL(fileURLWithPath:path))}.value
    }
    let root:URL
    var active=0;var peakActive=0
    var waiters:[CheckedContinuation<Void,Never>]=[]
    init(root:URL?=nil) {
        self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("local.LecturePlayer/Thumbnails")
    }
    private func acquire() async {
        if active >= 2 {await withCheckedContinuation{waiters.append($0)}}
        else{active += 1;peakActive=max(peakActive,active)}
    }
    private func release() {
        if waiters.isEmpty {active -= 1}else{waiters.removeFirst().resume()}
    }
    func source(for lesson:Lecture)->MediaSource? { ThumbnailRequest.source(for:lesson) }
    func image(_ request:ThumbnailRequest) async throws -> URL {
        await acquire();defer{release()};try Task.checkCancellation()
        var url=URL(fileURLWithPath:request.source.path)
        if let bookmark=request.source.bookmark {var stale=false;if let resolved=try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale){url=resolved}}
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        // A preview would download the whole video; wait until it is on this Mac.
        if CloudFile.isOnlineOnly(url) {throw OnlineOnly()}
        let asset=AVURLAsset(url:url)
        let duration=try await asset.load(.duration).seconds
        guard duration.isFinite,duration>0 else{throw Failure("视频时长不可用")}
        let seconds=ThumbnailRequest.time(duration:duration),target=root.appendingPathComponent(request.key(at:seconds)+".png")
        if FileManager.default.fileExists(atPath:target.path) {return target}
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:256,height:144)
        let (image,_)=try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600))
        try Task.checkCancellation()
        let bitmap=NSBitmapImageRep(cgImage:image)
        guard let data=bitmap.representation(using:.png,properties:[:]) else{throw Failure("缩略图编码失败")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:target,options:.atomic);return target
    }
}
struct OnlineOnly:Error {}
struct LessonThumbnail:View {
    let lesson:Lecture
    var width:CGFloat=128
    var height:CGFloat=72
    var radius:CGFloat=8
    @LPState private var image:NSImage?
    @LPState private var failed=false
    @LPState private var missing=false
    @LPState private var cloud=false
    // Body/task identity must use in-memory data only; no filesystem work on
    // SwiftUI's layout thread. The renderer checks content metadata off-main.
    private var identity:String { lesson.mediaSources.map { "\($0.id)-\($0.path)-\($0.contentHash ?? "")-\($0.role)" }.joined(separator:"|") }
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:radius).fill(.quaternary)
            if let image {Image(nsImage:image).resizable().scaledToFill().frame(width:width,height:height)}
            else if cloud {VStack(spacing:4){Image(systemName:"icloud");Text("在云端").font(.caption2)}.foregroundStyle(.secondary).help("视频只在云端，打开时下载")}
            else {VStack(spacing:4){Image(systemName:missing ? "video.slash" : "video");Text(missing ? "视频缺失" : failed ? "无法生成预览" : "正在生成预览").font(.caption2)}}
        }.frame(width:width,height:height).clipShape(RoundedRectangle(cornerRadius:radius))
        .task(id:identity) {
            image=nil;failed=false;missing=false;cloud=false
            guard let source=await ThumbnailRenderer.shared.source(for:lesson) else{missing=true;return}
            while !Task.isCancelled {
                do{let url=try await ThumbnailRenderer.shared.image(ThumbnailRequest(source:source));try Task.checkCancellation();image=NSImage(contentsOf:url);cloud=false;return}
                catch is OnlineOnly {
                    // Render once the video arrives, e.g. after it was opened or pre-downloaded.
                    cloud=true
                    try? await Task.sleep(for:ThumbnailRenderer.cloudRecheck)
                    while !Task.isCancelled, await ThumbnailRenderer.stillInCloud(source.path) {try? await Task.sleep(for:ThumbnailRenderer.cloudRecheck)}
                }
                catch{if !Task.isCancelled{failed=true};return}
            }
        }
    }
}
