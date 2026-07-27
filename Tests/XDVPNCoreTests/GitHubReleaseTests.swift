import XCTest
@testable import XDVPNCore

final class GitHubReleaseTests: XCTestCase {
    func test_parsesVersionZipAndUpdateSection() throws {
        let data = try jsonData([
            "tag_name": "v1.5.8",
            "body": """
            # XDVPN v1.5.8

            ## 更新了什么

            - 支持 Wi-Fi 按需连接。
            - 修复全局模式重连循环。

            ## 安装

            下载并解压安装包。
            """,
            "assets": [
                [
                    "name": "XDVPN-v1.5.8.zip",
                    "browser_download_url": "https://example.com/XDVPN-v1.5.8.zip",
                ],
            ],
        ])

        XCTAssertEqual(
            GitHubReleaseMetadata.parse(data),
            GitHubReleaseMetadata(
                version: "1.5.8",
                downloadURL: URL(string: "https://example.com/XDVPN-v1.5.8.zip"),
                notes: """
                - 支持 Wi-Fi 按需连接。
                - 修复全局模式重连循环。
                """
            )
        )
    }

    func test_fallsBackToWholeBodyForOlderReleaseFormat() throws {
        let data = try jsonData([
            "tag_name": "1.5.7",
            "body": "修复干净系统上的证书验证。",
            "assets": [],
        ])

        XCTAssertEqual(
            GitHubReleaseMetadata.parse(data)?.notes,
            "修复干净系统上的证书验证。"
        )
    }

    func test_emptyBodyProducesNoNotes() throws {
        let data = try jsonData([
            "tag_name": "v1.5.8",
            "body": "  \n",
            "assets": [],
        ])

        XCTAssertNil(GitHubReleaseMetadata.parse(data)?.notes)
    }

    func test_missingTagIsRejected() throws {
        let data = try jsonData([
            "body": "更新内容",
            "assets": [],
        ])

        XCTAssertNil(GitHubReleaseMetadata.parse(data))
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
