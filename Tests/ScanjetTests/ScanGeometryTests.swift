import XCTest
import ScanjetCore

final class ScanGeometryTests: XCTestCase {
    func testHardwarePassesMatchWindowsModes() throws {
        XCTAssertEqual(try ScanMode.choose(outputDPI: 75).mode.dpi, 300)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 75).scale, 4)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 100).scale, 3)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 150).scale, 2)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 200).mode.dpi, 600)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 200).scale, 3)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 300).scale, 1)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 600).mode.dpi, 600)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 1200).mode.dpi, 1200)
        XCTAssertEqual(try ScanMode.choose(outputDPI: 2400).mode.dpi, 2400)
    }

    func testCoveredOutputDPIGroupsByHardwarePass() {
        XCTAssertEqual(ScanMode.all[0].coveredOutputDPI, [75, 100, 150, 300])
        XCTAssertEqual(ScanMode.all[1].coveredOutputDPI, [200, 600])
        XCTAssertEqual(ScanMode.all[2].coveredOutputDPI, [1200])
        XCTAssertEqual(ScanMode.all[3].coveredOutputDPI, [2400])
    }

    func testShadingDefaultURLIsPerHardwareDPI() {
        for mode in ScanMode.all {
            XCTAssertEqual(Shading.defaultURL(for: mode).lastPathComponent, "shading-\(mode.dpi).bin")
            XCTAssertTrue(Shading.defaultURL(for: mode).path.contains("/scanjet/"))
        }
    }

    func testA4PixelSizesMatchReadme() throws {
        let expected: [(Int, Int, Int)] = [
            (75, 621, 877),
            (100, 828, 1169),
            (150, 1243, 1754),
            (200, 1656, 2338),
            (300, 2486, 3508),
            (600, 4970, 7016),
            (1200, 9942, 14032),
            (2400, 19882, 28056)
        ]
        for (dpi, width, height) in expected {
            let size = try TestSupport.expectedPixelSize(dpi: dpi, paper: .a4)
            XCTAssertEqual(size.width, width, "width at \(dpi) dpi")
            XCTAssertEqual(size.height, height, "height at \(dpi) dpi")
        }
    }

    func testLetterIsWiderAndShorterThanA4() throws {
        let a4 = try TestSupport.expectedPixelSize(dpi: 75, paper: .a4)
        let letter = try TestSupport.expectedPixelSize(dpi: 75, paper: .usLetter)
        XCTAssertGreaterThan(letter.width, a4.width)
        XCTAssertLessThan(letter.height, a4.height)
    }

    func testShortStripAndRotation() throws {
        let strip = try TestSupport.expectedPixelSize(dpi: 75, paper: .a4, heightMM: 30)
        XCTAssertEqual(strip.width, 621)
        XCTAssertLessThan(strip.height, 200)
        XCTAssertGreaterThan(strip.height, 20)

        let rotated = try TestSupport.expectedPixelSize(dpi: 75, paper: .a4, heightMM: 30, orientation: .deg90)
        XCTAssertEqual(rotated.width, strip.height)
        XCTAssertEqual(rotated.height, strip.width)
    }

    func testPaperRegionIsCenteredOnTheBed() {
        let a4 = ScanRegion.paper(.a4)
        XCTAssertEqual(a4.widthMM, 210, accuracy: 0.01)
        XCTAssertEqual(a4.heightMM, 297, accuracy: 0.01)
        XCTAssertEqual(a4.xMM, (ScanBed.widthMM - 210) / 2, accuracy: 0.01)
        XCTAssertEqual(a4.yMM, 0, accuracy: 0.01)

        let letter = ScanRegion.paper(.usLetter)
        XCTAssertEqual(letter.widthMM, 215.9, accuracy: 0.01)
        XCTAssertEqual(letter.heightMM, 279.4, accuracy: 0.01)
        XCTAssertLessThan(letter.xMM, a4.xMM)
    }

    func testFullBedCoversTheGlass() {
        let bed = ScanRegion.fullBed
        XCTAssertEqual(bed.xMM, 0, accuracy: 0.01)
        XCTAssertEqual(bed.yMM, 0, accuracy: 0.01)
        XCTAssertEqual(bed.widthMM, ScanBed.widthMM, accuracy: 0.01)
        XCTAssertEqual(bed.heightMM, ScanBed.heightMM, accuracy: 0.01)
    }

    func testOverviewIgnoresCustomCropAndPaperSize() throws {
        var request = ScanRequest()
        request.dpi = 1200
        request.kind = .text
        request.colorDepth = .billions
        request.format = .jpeg
        request.paperSize = .usLetter
        request.useCustomSize = true
        request.orientation = .deg90
        request.region = ScanRegion(xMM: 20, yMM: 30, widthMM: 80, heightMM: 50)
        request.imageCorrection = ImageCorrection(mode: .manual, brightness: 0.4)

        let overview = request.preparedForOverview()
        XCTAssertEqual(overview.dpi, 75)
        XCTAssertEqual(overview.kind, .colour)
        XCTAssertEqual(overview.colorDepth, .millions)
        XCTAssertEqual(overview.format, .tiff)
        XCTAssertFalse(overview.combine)
        XCTAssertEqual(overview.orientation, .deg0)
        XCTAssertEqual(overview.effectiveRegion, ScanRegion.fullBed)
        XCTAssertEqual(overview.imageCorrection.mode, .none)

        let options = try overview.toScanOptions(outputPath: "/tmp/overview.tiff")
        XCTAssertEqual(options.dpi, 75)
        XCTAssertEqual(options.cropXMM, 0, accuracy: 0.01)
        XCTAssertEqual(options.cropYMM, 0, accuracy: 0.01)
        XCTAssertEqual(options.cropWidthMM, ScanBed.widthMM, accuracy: 0.01)
        XCTAssertEqual(options.heightMM, ScanBed.heightMM, accuracy: 0.01)
    }
}
