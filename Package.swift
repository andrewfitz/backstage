// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "backstage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "backstage", targets: ["backstage"]),
        // Injected into dev builds and test runners `launch` starts, to make them inaudible
        // everywhere (Inaudible.swift). Installed next to the binary; `make build` rebuilds it
        // universal (arm64 + x86_64) and ad-hoc signs it.
        .library(name: "backstage-inaudible", type: .dynamic, targets: ["BackstageInaudible"]),
    ],
    targets: [
        .target(name: "BackstageInaudible", path: "Sources/BackstageInaudible",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay"),
        .target(name: "CBackstageAudio", path: "Sources/CBackstageAudio",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(
            name: "backstage",
            dependencies: ["CVirtualDisplay", "CBackstageAudio"],
            path: "Sources/backstage",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ColorSync"),
            ]
        ),
    ]
)
