import XCTest
import ScanjetCore

final class CLIParseTests: XCTestCase {
    func testDefaultsAreA4ColourTIFF() throws {
        let request = try ScanRequest.parseCLI([])
        XCTAssertEqual(request.kind, .colour)
        XCTAssertEqual(request.colorDepth, .millions)
        XCTAssertEqual(request.dpi, 300)
        XCTAssertEqual(request.paperSize, .a4)
        XCTAssertEqual(request.orientation, .deg0)
        XCTAssertEqual(request.format, .tiff)
        XCTAssertFalse(request.combine)
        XCTAssertTrue(request.useShading)
        XCTAssertFalse(request.keepRaw)
        XCTAssertFalse(request.useCustomSize)
        XCTAssertEqual(request.name, "scan")
        XCTAssertEqual(request.imageCorrection.mode, .none)
        XCTAssertFalse(request.imageCorrection.shouldApply)
        XCTAssertNil(request.explicitOutputURL)
        XCTAssertEqual(request.effectiveRegion, ScanRegion.paper(.a4))
    }

    func testKindAliases() throws {
        XCTAssertEqual(try ScanRequest.parseCLI(["--kind", "colour"]).kind, .colour)
        XCTAssertEqual(try ScanRequest.parseCLI(["--kind", "color"]).kind, .colour)
        XCTAssertEqual(try ScanRequest.parseCLI(["--kind", "gray"]).kind, .blackAndWhite)
        XCTAssertEqual(try ScanRequest.parseCLI(["--kind", "bw"]).kind, .blackAndWhite)
        XCTAssertEqual(try ScanRequest.parseCLI(["--kind", "text"]).kind, .text)
    }

    func testModeIsKindAliasAndKindWins() throws {
        XCTAssertEqual(try ScanRequest.parseCLI(["--mode", "gray"]).kind, .blackAndWhite)
        XCTAssertEqual(try ScanRequest.parseCLI(["--mode", "color"]).kind, .colour)
        let kindFirst = try ScanRequest.parseCLI(["--kind", "text", "--mode", "gray"])
        XCTAssertEqual(kindFirst.kind, .text)
        let modeFirst = try ScanRequest.parseCLI(["--mode", "gray", "--kind", "text"])
        XCTAssertEqual(modeFirst.kind, .text)
    }

    func testColoursAndSizeAndOrientation() throws {
        let request = try ScanRequest.parseCLI([
            "--colours", "billions",
            "--size", "letter",
            "--orientation", "90",
            "--format", "png"
        ])
        XCTAssertEqual(request.colorDepth, .billions)
        XCTAssertEqual(request.paperSize, .usLetter)
        XCTAssertEqual(request.orientation, .deg90)
        XCTAssertEqual(request.format, .png)
        XCTAssertEqual(request.effectiveRegion, ScanRegion.paper(.usLetter))
    }

    func testAmericanColorsAlias() throws {
        XCTAssertEqual(try ScanRequest.parseCLI(["--colors", "16-bit"]).colorDepth, .billions)
        XCTAssertEqual(try ScanRequest.parseCLI(["--depth", "8"]).colorDepth, .millions)
    }

    func testOutputPathInfersFormatAndOverwrites() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("page.jpg").path
        let request = try ScanRequest.parseCLI(["-o", path])
        XCTAssertEqual(request.format, .jpeg)
        XCTAssertEqual(request.name, "page")
        XCTAssertEqual(request.explicitOutputURL?.path, path)
        XCTAssertEqual(request.outputURL(combineExisting: false).path, path)
    }

    func testOutputDirectoryUsesNameAndUniqueFiles() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = try ScanRequest.parseCLI([
            "-o", dir.path,
            "--name", "Invoice",
            "--format", "pdf"
        ])
        XCTAssertNil(request.explicitOutputURL)
        XCTAssertEqual(request.name, "Invoice")
        XCTAssertEqual(request.format, .pdf)
        XCTAssertEqual(request.outputDirectory.path, dir.path)

        let first = request.outputURL(combineExisting: false)
        XCTAssertEqual(first.lastPathComponent, "Invoice.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = request.outputURL(combineExisting: false)
        XCTAssertEqual(second.lastPathComponent, "Invoice-2.pdf")
    }

    func testCombineReusesExistingPDF() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = try ScanRequest.parseCLI([
            "-o", dir.path,
            "--name", "Report",
            "--format", "pdf",
            "--combine"
        ])
        let first = request.outputURL(combineExisting: true)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let again = request.outputURL(combineExisting: true)
        XCTAssertEqual(again.path, first.path)
    }

    func testHeightKeepsPaperWidth() throws {
        let request = try ScanRequest.parseCLI(["--size", "letter", "--height", "40"])
        XCTAssertTrue(request.useCustomSize)
        XCTAssertEqual(request.effectiveRegion.widthMM, PaperSize.usLetter.widthMM, accuracy: 0.01)
        XCTAssertEqual(request.effectiveRegion.heightMM, 40, accuracy: 0.01)
        XCTAssertEqual(request.effectiveRegion.xMM, ScanRegion.paper(.usLetter).xMM, accuracy: 0.01)
    }

    func testFlagsForRawGammaFeedShading() throws {
        let request = try ScanRequest.parseCLI([
            "--raw",
            "--gamma", "1.8",
            "--feed", "500",
            "--shading", "/tmp/shade.bin",
            "--dpi", "150"
        ])
        XCTAssertTrue(request.keepRaw)
        XCTAssertEqual(request.gamma, 1.8)
        XCTAssertEqual(request.feed, 500)
        XCTAssertEqual(request.shadingPath, "/tmp/shade.bin")
        XCTAssertEqual(request.dpi, 150)
        XCTAssertTrue(request.useShading)

        let plain = try ScanRequest.parseCLI(["--no-shading"])
        XCTAssertFalse(plain.useShading)
    }

    func testToScanOptionsMapsRegionAndKind() throws {
        let request = try ScanRequest.parseCLI([
            "--kind", "gray",
            "--size", "a4",
            "--colours", "billions",
            "--format", "tiff",
            "--dpi", "75"
        ])
        let options = try request.toScanOptions(outputPath: "/tmp/out.tiff")
        XCTAssertEqual(options.mode, .gray)
        XCTAssertEqual(options.colorDepth, .billions)
        XCTAssertEqual(options.dpi, 75)
        XCTAssertEqual(options.cropXMM, ScanRegion.paper(.a4).xMM, accuracy: 0.01)
        XCTAssertEqual(options.cropWidthMM, PaperSize.a4.widthMM, accuracy: 0.01)
        XCTAssertEqual(options.heightMM, PaperSize.a4.heightMM, accuracy: 0.01)
    }

    func testRejectedCombinations() {
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--kind", "sepia"])) { XCTAssertUsage($0, contains: "kind") }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--mode", "text"])) { XCTAssertUsage($0, contains: "mode") }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--dpi", "72"])) { XCTAssertUsage($0, contains: "dpi") }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--format", "webp"])) { XCTAssertUsage($0, contains: "format") }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--combine", "--format", "jpeg"])) {
            XCTAssertUsage($0, contains: "combine")
        }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--colours", "billions", "--format", "jpeg"])) {
            XCTAssertUsage($0, contains: "billions")
        }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--kind", "text", "--colours", "billions", "--format", "tiff"])) {
            XCTAssertUsage($0, contains: "text")
        }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["-o", "page.tiff", "--format", "png"])) {
            XCTAssertUsage($0, contains: "extension")
        }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--unknown"])) { XCTAssertUsage($0, contains: "unknown") }
        XCTAssertThrowsError(try ScanRequest.parseCLI(["--dpi"])) { XCTAssertUsage($0, contains: "needs a value") }
    }

    func testScanOptionsParseForCalibrate() throws {
        let options = try ScanOptions.parse([
            "--dpi", "600", "--no-shading", "--feed", "489", "--gamma", "2.2"
        ])
        XCTAssertEqual(options.dpi, 600)
        XCTAssertFalse(options.useShading)
        XCTAssertEqual(options.feed, 489)
        XCTAssertEqual(options.gamma, 2.2)
        XCTAssertThrowsError(try ScanOptions.parse(["--kind", "gray"])) { XCTAssertUsage($0, contains: "unknown") }
    }
}
