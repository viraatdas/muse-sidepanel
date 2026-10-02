// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuseSidepanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MuseSidepanel", path: "Sources/MuseSidepanel"),
        .testTarget(name: "MuseSidepanelTests", dependencies: ["MuseSidepanel"], path: "Tests/MuseSidepanelTests"),
    ]
)
