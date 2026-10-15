// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageView",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ImageView", targets: ["ImageView"])],
    targets: [
        .executableTarget(name: "ImageView"),
        .testTarget(
            name: "ImageViewTests",
            dependencies: ["ImageView"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
