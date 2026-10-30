// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypoFix",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TypoFix", targets: ["TypoFix"]),
        .executable(name: "TypoFixApp", targets: ["TypoFixApp"]),
    ],
    targets: [
        .target(name: "TypoFix", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TypoFixApp", dependencies: ["TypoFix"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
