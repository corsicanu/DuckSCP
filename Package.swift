// swift-tools-version:5.9
import Foundation
import PackageDescription

// libssh2 and OpenSSL's libcrypto are linked statically so the app has no Homebrew
// runtime dependency. Override the prefix with HOMEBREW_PREFIX if needed.
let brew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
let staticSSH: [LinkerSetting] = [
    .unsafeFlags(["\(brew)/opt/libssh2/lib/libssh2.a", "\(brew)/opt/openssl@4/lib/libcrypto.a"]),
    .linkedLibrary("z"),
]

let package = Package(
    name: "DuckSCP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DuckSCP", targets: ["DuckSCP"]),
        .library(name: "SCPCore", targets: ["SCPCore"]),
    ],
    targets: [
        .target(name: "CLibSSH2", path: "Sources/CLibSSH2", linkerSettings: staticSSH),
        // System libcurl (SecureTransport TLS, macOS trust store) for FTP/FTPS.
        .target(name: "CCurl", path: "Sources/CCurl", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "SCPCore", dependencies: ["CLibSSH2", "CCurl"], path: "Sources/SCPCore"),
        .executableTarget(name: "DuckSCP", dependencies: ["SCPCore"], path: "Sources/DuckSCP"),
        .testTarget(name: "SCPCoreTests", dependencies: ["SCPCore"], path: "Tests/SCPCoreTests",
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
