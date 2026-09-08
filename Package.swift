// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VisionStack",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VisionStack", targets: ["VisionStack"])],
    targets: [
        .executableTarget(
            name: "VisionStack",
            resources: [
                .process("Resources/AppIcon.png"),
                .copy("Resources/ManagedSkills")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(name: "VisionStackTests", dependencies: ["VisionStack"])
    ]
)
