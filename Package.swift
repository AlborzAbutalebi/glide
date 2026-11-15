// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure scroll physics, shared by the app and the offline simulator.
        .target(name: "GlideCore", path: "Sources/GlideCore"),
        .executableTarget(
            name: "Glide",
            dependencies: ["GlideCore"],
            path: "Sources/Glide",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "glide-sim", dependencies: ["GlideCore"], path: "Sources/glide-sim"),
    ],
    swiftLanguageModes: [.v5]
)
