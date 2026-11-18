// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DisplayBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CDisplayPrivate",
            path: "Sources/CDisplayPrivate"
        ),
        .executableTarget(
            name: "DisplayBar",
            dependencies: ["CDisplayPrivate"],
            path: "Sources/DisplayBar",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Size over speed: nothing here is hot, and smaller code means fewer resident pages.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ColorSync"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
