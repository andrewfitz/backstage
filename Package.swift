// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "backstage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVirtualDisplay", path: "Sources/CVirtualDisplay"),
        .executableTarget(
            name: "backstage",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/backstage",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
    ]
)
