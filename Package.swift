// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacSCP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacSCP", targets: ["MacSCP"]),
        .library(name: "SCPCore", targets: ["SCPCore"]),
    ],
    targets: [
        .target(name: "SCPCore", path: "Sources/SCPCore"),
        .executableTarget(name: "MacSCP", dependencies: ["SCPCore"], path: "Sources/MacSCP"),
        .testTarget(name: "SCPCoreTests", dependencies: ["SCPCore"], path: "Tests/SCPCoreTests",
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
