// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Halftone",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Halftone",
            path: "Sources/Halftone",
            swiftSettings: [
                .swiftLanguageMode(.v5) // relax strict concurrency for AppKit interop; tighten later
            ]
        )
    ]
)
