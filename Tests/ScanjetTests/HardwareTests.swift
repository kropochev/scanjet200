import XCTest
import UniformTypeIdentifiers
import ScanjetCore

/// Live USB tests. Skipped when the scanner is unplugged.
/// Set `SCANJET_HARDWARE=1` to fail instead of skip if the device is missing.
final class HardwareTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        let available = DeviceSession.isScannerAvailable()
        if !available {
            if TestSupport.hardwareRequired {
                throw NSError(
                    domain: "ScanjetTests",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                               "SCANJET_HARDWARE=1 but HP Scanjet 200 (03f0:1c05) was not found"]
                )
            }
            throw XCTSkip("HP Scanjet 200 not connected. Plug it in, or set SCANJET_HARDWARE=1 to require it.")
        }
        dir = try TestSupport.makeTempDir("scanjet-hw")
    }

    override func tearDownWithError() throws {
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testListFindsScanjet200() throws {
        let result = try TestSupport.runCLI(["list"], timeout: 20)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("scanner found"), result.stdout)
        XCTAssertTrue(result.stdout.localizedCaseInsensitiveContains("scanjet")
                      || result.stdout.contains("03f0"), result.stdout)
    }

    func testColourTIFFMatchesExpectedSize() throws {
        let output = dir.appendingPathComponent("colour.tiff")
        let heightMM = 30.0
        let expected = try TestSupport.expectedPixelSize(dpi: 75, paper: .a4, heightMM: heightMM)
        let result = try scan(to: output, extra: ["--dpi", "75", "--height", "30", "--format", "tiff"])
        XCTAssertEqual(result.status, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("done:"), result.stdout)

        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, expected.width)
        XCTAssertEqual(info.height, expected.height)
        XCTAssertEqual(info.uti, "public.tiff")
        XCTAssertFalse(info.isMonochrome)
        XCTAssertEqual(info.bitsPerComponent, 8)
        XCTAssertGreaterThan(fileSize(output), 1_000)
    }

    func testGrayPNGAndJPEG() throws {
        let png = dir.appendingPathComponent("gray.png")
        let pngRun = try scan(to: png, extra: [
            "--dpi", "75", "--height", "30", "--kind", "gray", "--format", "png"
        ])
        XCTAssertEqual(pngRun.status, 0, pngRun.stderr)
        let pngInfo = try TestSupport.inspectRaster(png)
        XCTAssertTrue(pngInfo.isMonochrome)
        XCTAssertEqual(pngInfo.uti, "public.png")
        XCTAssertEqual(pngInfo.width, try TestSupport.expectedPixelSize(dpi: 75, heightMM: 30).width)

        let jpeg = dir.appendingPathComponent("photo.jpg")
        let jpegRun = try scan(to: jpeg, extra: [
            "--dpi", "75", "--height", "30", "--format", "jpeg"
        ])
        XCTAssertEqual(jpegRun.status, 0, jpegRun.stderr)
        let jpegInfo = try TestSupport.inspectRaster(jpeg)
        XCTAssertEqual(jpegInfo.uti, "public.jpeg")
        XCTAssertFalse(jpegInfo.isMonochrome)
        XCTAssertEqual(jpegInfo.width, pngInfo.width)
        XCTAssertEqual(jpegInfo.height, pngInfo.height)
    }

    func testOrientation90SwapsAxes() throws {
        let output = dir.appendingPathComponent("rotated.png")
        let expected = try TestSupport.expectedPixelSize(dpi: 75, heightMM: 30, orientation: .deg90)
        let result = try scan(to: output, extra: [
            "--dpi", "75", "--height", "30", "--orientation", "90", "--format", "png"
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let info = try TestSupport.inspectRaster(output)
        XCTAssertEqual(info.width, expected.width)
        XCTAssertEqual(info.height, expected.height)
        XCTAssertLessThan(info.width, info.height)
    }

    func testLetterIsWiderThanA4() throws {
        let a4 = dir.appendingPathComponent("a4.tiff")
        let letter = dir.appendingPathComponent("letter.tiff")
        XCTAssertEqual(try scan(to: a4, extra: [
            "--dpi", "75", "--height", "30", "--size", "a4"
        ]).status, 0)
        XCTAssertEqual(try scan(to: letter, extra: [
            "--dpi", "75", "--height", "30", "--size", "letter"
        ]).status, 0)

        let a4Info = try TestSupport.inspectRaster(a4)
        let letterInfo = try TestSupport.inspectRaster(letter)
        XCTAssertEqual(a4Info.width, try TestSupport.expectedPixelSize(dpi: 75, paper: .a4, heightMM: 30).width)
        XCTAssertEqual(letterInfo.width, try TestSupport.expectedPixelSize(dpi: 75, paper: .usLetter, heightMM: 30).width)
        XCTAssertGreaterThan(letterInfo.width, a4Info.width)
        XCTAssertEqual(letterInfo.height, a4Info.height)
    }

    func testCombinePDFAppendsPages() throws {
        let output = dir.appendingPathComponent("report.pdf")
        let first = try scan(to: output, extra: [
            "--dpi", "75", "--height", "25", "--format", "pdf", "--name", "report"
        ])
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(try TestSupport.pdfPageCount(output), 1)

        let second = try scan(to: output, extra: [
            "--dpi", "75", "--height", "25", "--format", "pdf", "--combine", "--name", "report"
        ])
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertEqual(try TestSupport.pdfPageCount(output), 2)

        let size = try TestSupport.pdfPageSize(output)
        let expected = try TestSupport.expectedPixelSize(dpi: 75, heightMM: 25)
        XCTAssertEqual(Int(size.width.rounded()), expected.width)
        XCTAssertEqual(Int(size.height.rounded()), expected.height)
    }

    func testRawDumpIsKeptBesideOutput() throws {
        let output = dir.appendingPathComponent("keep.tiff")
        let raw = dir.appendingPathComponent("keep.raw16")
        let result = try scan(to: output, extra: [
            "--dpi", "75", "--height", "25", "--raw", "--no-shading"
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), result.stdout)
        XCTAssertGreaterThan(fileSize(raw), fileSize(output))
        XCTAssertTrue(result.stdout.contains("raw 16-bit") || result.stderr.contains("raw 16-bit")
                      || FileManager.default.fileExists(atPath: raw.path))
    }

    func testTextPDFIsSinglePage() throws {
        let output = dir.appendingPathComponent("ocr.pdf")
        let result = try scan(to: output, extra: [
            "--dpi", "75", "--height", "25", "--kind", "text", "--format", "pdf"
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try TestSupport.pdfPageCount(output), 1)
        XCTAssertGreaterThan(fileSize(output), 500)
    }

    private func scan(to output: URL, extra: [String]) throws -> TestSupport.CLIResult {
        var args = ["scan", "--no-shading", "-o", output.path]
        args.append(contentsOf: extra)
        return try TestSupport.runCLI(args, timeout: 90)
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
