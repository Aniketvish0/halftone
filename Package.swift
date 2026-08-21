// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Halftone",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "HalftoneKit",
            path: "Sources/Halftone",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Halftone",
            dependencies: ["HalftoneKit"],
            path: "Sources/HalftoneMain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HalftoneKitTests",
            dependencies: ["HalftoneKit"],
            path: "Tests/HalftoneKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
