import Foundation
import XCTest

/// xdvpn-openconnect 是 sudoers 放行的 root 入口，脚本文本内嵌在 App 目标里。
/// 这里取出真实脚本，换上假的 openconnect 后实际执行，核对它交给 openconnect 的参数。
final class OpenConnectWrapperTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdvpn-wrapper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func test_withoutAuthGroupArgumentsAreUnchanged() throws {
        let result = try runWrapper([
            "--protocol", "anyconnect", "--user", "alice", "--server", "vpn.example.com",
        ])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.arguments, [
            "--background",
            "--cafile=\(caFile.path)",
            "--pid-file=/tmp/xdvpn.pid",
            "--script=\(routeScript.path)",
            "--protocol=anyconnect",
            "--passwd-on-stdin",
            "--user=alice",
            "--non-inter",
            "--",
            "vpn.example.com",
        ])
    }

    func test_authGroupIsPassedAsOneArgument() throws {
        let result = try runWrapper([
            "--protocol", "anyconnect", "--user", "alice",
            "--authgroup", "Staff VPN", "--server", "vpn.example.com",
        ])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.arguments.count, 11)
        XCTAssertEqual(result.arguments[7], "--authgroup=Staff VPN")
        XCTAssertEqual(Array(result.arguments.suffix(3)), ["--non-inter", "--", "vpn.example.com"])
    }

    func test_authGroupCannotSmuggleOpenConnectOptions() throws {
        let marker = workDir.appendingPathComponent("smuggled")
        for group in [
            "x --script=/usr/bin/true",
            "--script=/usr/bin/true",
            "$(touch \(marker.path))",
            "`touch \(marker.path)`",
            "a\" --script=\"/usr/bin/true",
        ] {
            let result = try runWrapper([
                "--protocol", "anyconnect", "--user", "alice",
                "--authgroup", group, "--server", "vpn.example.com",
            ])

            XCTAssertEqual(result.status, 0, group)
            XCTAssertEqual(result.arguments.count, 11, group)
            XCTAssertEqual(result.arguments[7], "--authgroup=\(group)", group)
            XCTAssertEqual(
                result.arguments.filter { $0.hasPrefix("--script") },
                ["--script=\(routeScript.path)"],
                group
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_emptyOrMissingAuthGroupValueIsRejected() throws {
        let empty = try runWrapper([
            "--protocol", "anyconnect", "--user", "alice",
            "--authgroup", "", "--server", "vpn.example.com",
        ])
        XCTAssertEqual(empty.status, 64)
        XCTAssertEqual(empty.arguments, [])

        let missing = try runWrapper([
            "--protocol", "anyconnect", "--user", "alice",
            "--server", "vpn.example.com", "--authgroup",
        ])
        XCTAssertEqual(missing.status, 64)
        XCTAssertEqual(missing.arguments, [])
    }

    func test_unknownOptionsAreStillRejected() throws {
        let result = try runWrapper([
            "--protocol", "anyconnect", "--user", "alice",
            "--server", "vpn.example.com", "--script", "/usr/bin/true",
        ])
        XCTAssertEqual(result.status, 64)
        XCTAssertEqual(result.arguments, [])
    }

    func test_helperVersionWasBumpedWithTheWrapperChange() throws {
        let installer = try source("Sources/XDVPN/SudoersInstaller.swift")
        XCTAssertTrue(installer.contains("static let helperVersion = 15"))
    }

    // MARK: - Harness

    private var fakeOpenConnect: URL { workDir.appendingPathComponent("openconnect") }
    private var routeScript: URL { workDir.appendingPathComponent("route-script") }
    private var caFile: URL { workDir.appendingPathComponent("ca.pem") }
    private var argumentLog: URL { workDir.appendingPathComponent("argv") }

    private func runWrapper(_ arguments: [String]) throws -> (status: Int32, arguments: [String]) {
        try? FileManager.default.removeItem(at: argumentLog)
        // 每个参数后面写一个 NUL，这样带空格或换行的参数也能原样还原。
        try writeExecutable(fakeOpenConnect, "#!/bin/bash\nprintf '%s\\0' \"$@\" > '\(argumentLog.path)'\n")
        try writeExecutable(routeScript, "#!/bin/bash\n")
        try Data().write(to: caFile)

        let wrapper = workDir.appendingPathComponent("xdvpn-openconnect")
        try wrapperScript().write(to: wrapper, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [wrapper.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let logged = (try? Data(contentsOf: argumentLog)) ?? Data()
        let parsed = logged.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
        return (process.terminationStatus, parsed)
    }

    private func wrapperScript() throws -> String {
        let installer = try source("Sources/XDVPN/SudoersInstaller.swift")
        let start = try XCTUnwrap(installer.range(of: "openconnectWrapperContent() -> String {"))
        let open = try XCTUnwrap(installer.range(of: "#\"\"\"\n", range: start.upperBound..<installer.endIndex))
        let close = try XCTUnwrap(installer.range(of: "\n        \"\"\"#", range: open.upperBound..<installer.endIndex))

        // Swift 按结束定界符的缩进（8 个空格）去掉每行的前导空白。
        var script = installer[open.upperBound..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("        ") ? String($0.dropFirst(8)) : String($0) }
            .joined(separator: "\n") + "\n"

        for (placeholder, value) in [
            ("\\#(helperVersion)", "0"),
            ("\\#(installedOpenConnectPath)", fakeOpenConnect.path),
            ("\\#(routeScriptPath)", routeScript.path),
            ("\\#(OpenConnectRunner.caFilePath)", caFile.path),
            ("\\#(protocolPattern)", "anyconnect|nc"),
        ] {
            XCTAssertTrue(script.contains(placeholder), placeholder)
            script = script.replacingOccurrences(of: placeholder, with: value)
        }
        XCTAssertFalse(script.contains("\\#("), "wrapper 里出现了测试不认识的插值")
        return script
    }

    private func writeExecutable(_ url: URL, _ content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
