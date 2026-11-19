// swift-tools-version: 5.9
import Foundation
import PackageDescription

// CLT 16 ships Testing.framework outside Swift's default framework search path.
let cltTestingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingSearchFlags: [String] = FileManager.default.fileExists(
    atPath: "\(cltTestingFrameworks)/Testing.framework"
) ? ["-F", cltTestingFrameworks] : []

let package = Package(
    name: "HowManyUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "HowManyUsage", path: "Sources/HowManyUsage"),
        .testTarget(
            name: "HowManyUsageTests",
            dependencies: ["HowManyUsage"],
            path: "Tests/HowManyUsageTests",
            swiftSettings: testingSearchFlags.isEmpty ? [] : [.unsafeFlags(testingSearchFlags)],
            linkerSettings: testingSearchFlags.isEmpty ? [] : [.unsafeFlags(testingSearchFlags)]
        )
    ]
)
