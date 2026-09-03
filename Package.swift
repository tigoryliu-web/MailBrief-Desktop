// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MailDigestDesktop",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MailDigestDesktop", targets: ["MailDigestDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "MailDigestDesktop",
            path: "Sources/MailDigestDesktop"
        ),
        .testTarget(
            name: "MailDigestDesktopTests",
            dependencies: ["MailDigestDesktop"],
            path: "Tests/MailDigestDesktopTests"
        )
    ]
)
