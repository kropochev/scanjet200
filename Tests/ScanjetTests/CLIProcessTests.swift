import XCTest
import ScanjetCore

final class CLIProcessTests: XCTestCase {
    func testHelpListsScanFlags() throws {
        let result = try TestSupport.runCLI(["help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("scanjet"))
        XCTAssertTrue(result.stdout.contains("--photo-subject"))
        XCTAssertTrue(result.stdout.contains("--photo-layout"))
        XCTAssertTrue(result.stdout.contains("--photo-format"))
        XCTAssertTrue(result.stdout.contains("--format"))
        XCTAssertTrue(result.stdout.contains("--combine"))
        XCTAssertTrue(result.stdout.contains("--orientation"))
        XCTAssertTrue(result.stdout.contains("--colours"))
        XCTAssertTrue(result.stdout.contains("--feed"))
        XCTAssertTrue(result.stdout.contains("Use Custom Size"))
        XCTAssertTrue(result.stdout.contains("list"))
        XCTAssertTrue(result.stdout.contains("scan"))
        XCTAssertTrue(result.stdout.contains("calibrate"))
        XCTAssertTrue(result.stdout.contains("version"))
        XCTAssertTrue(result.stdout.contains("--version"))
        XCTAssertTrue(result.stdout.contains("--help"))
        XCTAssertFalse(result.stdout.contains("dump-regs"))
        XCTAssertFalse(result.stdout.contains("probe"))
    }

    func testUnknownCommandAndBadScanArgsFailWithoutUSB() throws {
        let unknown = try TestSupport.runCLI(["not-a-command"])
        XCTAssertNotEqual(unknown.status, 0)
        XCTAssertTrue(unknown.stderr.contains("error:"))

        let badKind = try TestSupport.runCLI(["scan", "--kind", "sepia", "-o", "/tmp/x.tiff"])
        XCTAssertNotEqual(badKind.status, 0)
        XCTAssertTrue(badKind.stderr.contains("kind"))

        let badCombine = try TestSupport.runCLI(["scan", "--combine", "--format", "jpeg", "-o", "/tmp/x.jpg"])
        XCTAssertNotEqual(badCombine.status, 0)
        XCTAssertTrue(badCombine.stderr.contains("combine"))

        let badDpi = try TestSupport.runCLI(["scan", "--dpi", "72", "-o", "/tmp/x.tiff"])
        XCTAssertNotEqual(badDpi.status, 0)
        XCTAssertTrue(badDpi.stderr.contains("dpi"))
    }

    func testScanWithoutScannerFails() throws {
        try XCTSkipIf(DeviceSession.isScannerAvailable(), "scanner is connected")
        let dir = try TestSupport.makeTempDir("scanjet-offline")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("page.tiff")
        let result = try TestSupport.runCLI([
            "scan", "--dpi", "75", "--height", "20", "--no-shading", "-o", output.path
        ], timeout: 15)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("error:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
