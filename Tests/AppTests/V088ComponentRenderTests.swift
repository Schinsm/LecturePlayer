import AppKit
import SwiftUI
import Testing
import Core
@testable import LecturePlayer

/// Render this application's own NSHostingView tree. This does not capture the
/// desktop and is not evidence that mouse, keyboard or window interactions pass.
@Suite("0.8.8 optional component render", .serialized) @MainActor
struct V088ComponentRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP088_RENDER"] == "1"))
    func renderIsolatedPreferences() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/private/tmp/LP088/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "LP088-component-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = directory.appendingPathComponent("fixture-" + UUID().uuidString)
        let store = AppStore(root: root, preferences: defaults)
        defer { store.playback.close(); defaults.removePersistentDomain(forName: name) }
        try #require(!store.fatal)
        #expect(store.library.lectures.isEmpty)
        let variants: [(PreferencesPage, CGSize, String)] = [
            (.general, CGSize(width: 820, height: 640), "light"),
            (.playback, CGSize(width: 820, height: 820), "light"),
            (.playback, CGSize(width: 760, height: 560), "light"),
            (.playback, CGSize(width: 820, height: 640), "dark"),
            (.library, CGSize(width: 820, height: 640), "light"),
            (.backup, CGSize(width: 820, height: 640), "light")
        ]
        var rendered: [String] = []
        for (page, size, style) in variants {
            defaults.set(style == "dark" ? "深色" : "浅色", forKey: "appearance")
            // The service page is deliberately excluded: it checks credentials.
            let view = PreferencesView(store: store, initialPage: page, refreshCredentials: false)
                .defaultAppStorage(defaults)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
            // No orderFront/activation and no user event is sent.
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 2_000)
            let file = "preferences-\(page.rawValue)-\(Int(size.width))x\(Int(size.height))-\(style).png"
            try png.write(to: directory.appendingPathComponent(file))
            rendered.append(file)
            window.contentView = nil
            window.close()
        }
        let report: [String: Any] = [
            "method": "NSHostingView bitmap rendering; no desktop capture or GUI input",
            "scope": "general, playback, library, backup; services excluded to avoid Keychain access",
            "files": rendered,
            "dataRoot": root.path,
            "guiInteractionAccepted": false,
            "cloudRequestsSent": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("component-render.json"))
    }
}
