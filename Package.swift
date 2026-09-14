// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "minimalWM",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "minimalWM",
            path: "Sources/MinimalWM",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
