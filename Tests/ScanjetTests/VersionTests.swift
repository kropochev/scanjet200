import XCTest
import ScanjetCore

final class VersionTests: XCTestCase {
    func testVersionFileMatchesConstant() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("VERSION")
        let file = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(AppVersion.marketing, file)
    }

    func testCLIVersion() throws {
        for args in [["--version"], ["-V"], ["version"]] {
            let result = try TestSupport.runCLI(args)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                           AppVersion.cliLine)
        }
    }

    func testHelpMentionsVersion() throws {
        let result = try TestSupport.runCLI(["--help"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("--version"))
        XCTAssertTrue(result.stdout.contains("version"))
    }
}
