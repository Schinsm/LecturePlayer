// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LecturePlayer", platforms: [.macOS(.v14)], products: [.executable(name: "LecturePlayer", targets: ["LecturePlayer"])], targets: [.target(name: "Core"), .executableTarget(name: "LecturePlayer", dependencies: ["Core"]), .testTarget(name: "CoreTests", dependencies: ["Core"]), .testTarget(name: "AppTests", dependencies: ["LecturePlayer", "Core"])], swiftLanguageModes: [.v5])
