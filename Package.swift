// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XDVPN",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯决策逻辑（无 AppKit/系统副作用），可用 swift test 单测。
        // 所有重连/健康判定的"大脑"放这里，VPNController 只做事件翻译与副作用。
        .target(
            name: "XDVPNCore",
            path: "Sources/XDVPNCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "XDVPN",
            dependencies: ["XDVPNCore"],
            path: "Sources/XDVPN",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "xdvpn-dns-proxy",
            path: "Sources/xdvpn-dns-proxy"
        ),
        .testTarget(
            name: "XDVPNCoreTests",
            dependencies: ["XDVPNCore"],
            path: "Tests/XDVPNCoreTests"
        ),
    ]
)
