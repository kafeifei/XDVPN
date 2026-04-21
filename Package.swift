// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XDVPN",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XDVPN",
            path: "Sources/XDVPN"
        )
    ]
)
