// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "media-view",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MediaView", targets: ["MediaView"])],
    targets: [
        .executableTarget(name: "MediaView"),
        .testTarget(
            name: "MediaViewTests",
            dependencies: ["MediaView"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
