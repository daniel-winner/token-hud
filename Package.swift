// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenHUD",
            path: "Sources/TokenHUD"
        )
    ]
)
