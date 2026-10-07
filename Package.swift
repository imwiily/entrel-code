// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.2.0"..<"1.12.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeApp",
            dependencies: ["SwiftTerm"]
        )
    ]
)
