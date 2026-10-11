// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-redact-kit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "RedactKit", targets: ["RedactKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-credit-card-validator.git", from: "1.0.1"),
        .package(url: "https://github.com/arraypress/swift-secret-scanner.git", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "RedactKit",
            dependencies: [
                .product(name: "CreditCardValidator", package: "swift-credit-card-validator"),
                .product(name: "SecretScanner", package: "swift-secret-scanner"),
            ]
        ),
        .testTarget(name: "RedactKitTests", dependencies: ["RedactKit"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
