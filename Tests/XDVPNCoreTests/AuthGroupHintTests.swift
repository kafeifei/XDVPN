import XCTest
@testable import XDVPNCore

/// 样本是 OpenConnect v9.21 对带组下拉框的 AnyConnect 登录页的真实输出。
final class AuthGroupHintTests: XCTestCase {
    func test_missingGroupListsTheChoices() {
        let output = """
        Please enter your username and password.
        GROUP: [Default-Group|Staff VPN|Contractors]:***
        User input required in non-interactive mode
        Failed to complete authentication
        """
        XCTAssertEqual(
            authGroupHint(fromOpenConnectOutput: output),
            "服务器要求选择认证组。请在「认证组」里填写其中一个：Default-Group、Staff VPN、Contractors"
        )
    }

    func test_unknownGroupSaysTheValueIsWrong() {
        let output = """
        Please enter your username and password.
        Auth choice "NoSuchGroup" not available
        GROUP: [Default-Group|Staff VPN|Contractors]:***
        User input required in non-interactive mode
        Failed to complete authentication
        """
        XCTAssertEqual(
            authGroupHint(fromOpenConnectOutput: output),
            "认证组填写有误。服务器上可选的认证组：Default-Group、Staff VPN、Contractors"
        )
    }

    func test_serverChosenLabelIsNotAssumed() {
        let output = "领域 [研发|运维]:\nUser input required in non-interactive mode"
        XCTAssertEqual(
            authGroupHint(fromOpenConnectOutput: output),
            "服务器要求选择认证组。请在「认证组」里填写其中一个：研发、运维"
        )
    }

    func test_unrelatedFailuresAreLeftAlone() {
        for output in [
            "",
            "Login failed.\nFailed to complete authentication",
            "Failed to connect to host vpn.example.com",
            "Server certificate verify failed: signer not found",
            "Unexpected 404 result from server [details]: not found",
            "GROUP: [OnlyOne]:",
        ] {
            XCTAssertNil(authGroupHint(fromOpenConnectOutput: output), output)
        }
    }
}
