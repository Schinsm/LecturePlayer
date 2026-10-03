import Foundation
import Darwin
import Core

/// Watch every discovered directory, not only the top-level folder.
@MainActor final class DirectoryWatch {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var paths: [String: String] = [:]
    private var debounce: DispatchWorkItem?
    var changed: (() -> Void)?
    func update(_ urls: [URL]) {
        let next = Dictionary(urls.map { ($0.path, (try? DirectoryIndex.identity($0)) ?? "missing") }, uniquingKeysWith: { a, _ in a })
        guard next != paths else { return }
        sources.forEach { $0.cancel() }; sources = []; paths = next
        for path in next.keys {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write,.rename,.delete,.extend,.attrib,.revoke], queue: .main)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { Darwin.close(fd) }; source.resume(); sources.append(source)
        }
    }
    func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.changed?() }; debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    deinit { debounce?.cancel(); sources.forEach { $0.cancel() } }
}
