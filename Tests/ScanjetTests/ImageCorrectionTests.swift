import XCTest
import ImageIO
@testable import ScanjetCore

final class ImageCorrectionTests: XCTestCase {
    func testIdentityDoesNotChangeRGB() {
        let correction = ImageCorrection(mode: .manual)
        let (r, g, b) = correction.apply(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertEqual(r, 0.2, accuracy: 1e-9)
        XCTAssertEqual(g, 0.4, accuracy: 1e-9)
        XCTAssertEqual(b, 0.6, accuracy: 1e-9)
        XCTAssertFalse(correction.shouldApply)
        XCTAssertTrue(correction.isAtDefaults)
    }

    func testNoneIgnoresSliderValues() {
        let correction = ImageCorrection(mode: .none, brightness: 1, saturation: -1)
        let (r, g, b) = correction.apply(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertEqual(r, 0.2, accuracy: 1e-9)
        XCTAssertEqual(g, 0.4, accuracy: 1e-9)
        XCTAssertEqual(b, 0.6, accuracy: 1e-9)
        XCTAssertFalse(correction.shouldApply)
    }

    func testBrightnessRaisesMidGrey() {
        let correction = ImageCorrection(mode: .manual, brightness: 1)
        let (r, g, b) = correction.apply(r: 0, g: 0, b: 0)
        XCTAssertEqual(r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b, 0.5, accuracy: 1e-9)
    }

    func testSaturationMinusOneIsLuma() {
        let correction = ImageCorrection(mode: .manual, saturation: -1)
        let (r, g, b) = correction.apply(r: 1, g: 0, b: 0)
        XCTAssertEqual(r, 0.2126, accuracy: 1e-9)
        XCTAssertEqual(g, 0.2126, accuracy: 1e-9)
        XCTAssertEqual(b, 0.2126, accuracy: 1e-9)
    }

    func testWarmTemperatureRaisesRedOverBlue() {
        let correction = ImageCorrection(mode: .manual, temperature: 1)
        let (r, g, b) = correction.apply(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertGreaterThan(r, g)
        XCTAssertGreaterThan(g, b)
        XCTAssertGreaterThan(r, b)
    }

    func testGreenTintRaisesGreen() {
        let correction = ImageCorrection(mode: .manual, tint: 1)
        let (r, g, b) = correction.apply(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertGreaterThan(g, r)
        XCTAssertGreaterThan(g, b)
    }

    func testRestoreDefaultsClearsSlidersButKeepsManual() {
        var correction = ImageCorrection(mode: .manual, brightness: 0.4, tint: -0.2,
                                         temperature: 0.8, saturation: -1)
        correction.restoreDefaults()
        XCTAssertEqual(correction.mode, .manual)
        XCTAssertTrue(correction.isAtDefaults)
        XCTAssertFalse(correction.shouldApply)
    }

    func testOverviewCaptureDropsCorrection() {
        var request = ScanRequest()
        request.imageCorrection = ImageCorrection(mode: .manual, brightness: 0.5)
        let overview = request.preparedForOverview()
        XCTAssertEqual(overview.imageCorrection.mode, .none)
        XCTAssertFalse(overview.imageCorrection.shouldApply)
        XCTAssertEqual(request.imageCorrection.mode, .manual)
    }

    func testPassthroughDisabledWhenCorrectionIsOn() {
        var request = ScanRequest(format: .tiff)
        XCTAssertTrue(ImageExporter.canPassThrough(request, append: false))
        request.imageCorrection = ImageCorrection(mode: .manual, brightness: 0.25)
        XCTAssertFalse(ImageExporter.canPassThrough(request, append: false))
        request.format = .png
        XCTAssertFalse(ImageExporter.canStreamPNG(request, append: false))
    }

    func testExportAppliesBrightness() throws {
        let dir = try TestSupport.makeTempDir("scanjet-correction")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.tiff")
        let writer = try TIFFWriter(path: source.path, width: 8, samplesPerPixel: 3, dpi: 75, bitsPerSample: 8)
        for _ in 0..<4 {
            var row = [UInt8](repeating: 0, count: 8 * 3)
            for x in 0..<8 {
                row[x * 3] = 128
                row[x * 3 + 1] = 128
                row[x * 3 + 2] = 128
            }
            try writer.write(row: row)
        }
        try writer.finish()

        var request = ScanRequest(format: .png)
        request.imageCorrection = ImageCorrection(mode: .manual, brightness: 1)
        let output = dir.appendingPathComponent("out.png")
        try ImageExporter.export(sourceTIFF: source, request: request, outputURL: output)

        guard let image = CGImageSourceCreateWithURL(output as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("cannot read corrected PNG")
        }
        let pixels = TestSupport.rgbPixels(image)
        XCTAssertFalse(pixels.isEmpty)
        XCTAssertEqual(pixels[0].0, 255)
        XCTAssertEqual(pixels[0].1, 255)
        XCTAssertEqual(pixels[0].2, 255)
    }

    func testCorrectionWriterMapsEightBitRow() throws {
        let inner = CollectingWriter()
        let correction = ImageCorrection(mode: .manual, saturation: -1)
        let writer = CorrectionWriter(inner, correction: correction, samplesPerPixel: 3)
        try writer.write(row: [255, 0, 0])
        _ = try writer.finish()
        XCTAssertEqual(inner.rows.count, 1)
        XCTAssertEqual(inner.rows[0][0], inner.rows[0][1])
        XCTAssertEqual(inner.rows[0][1], inner.rows[0][2])
        XCTAssertEqual(Int(inner.rows[0][0]), 54) // 0.2126 * 255
    }

    func testApplyToRGBA8OnlyTouchesLeadingRows() {
        let correction = ImageCorrection(mode: .manual, brightness: 1)
        var pixels: [UInt8] = [
            0, 0, 0, 255,
            0, 0, 0, 255
        ]
        pixels.withUnsafeMutableBytes { raw in
            correction.applyToRGBA8(raw.baseAddress!, width: 1, rowCount: 1, bytesPerRow: 4)
        }
        XCTAssertEqual(pixels[0], 128)
        XCTAssertEqual(pixels[1], 128)
        XCTAssertEqual(pixels[2], 128)
        XCTAssertEqual(pixels[4], 0)
        XCTAssertEqual(pixels[5], 0)
        XCTAssertEqual(pixels[6], 0)
    }
}

private final class CollectingWriter: PixelRowWriter {
    var rows = [[UInt8]]()

    func write(row: [UInt8]) throws {
        rows.append(row)
    }

    func write(row16: [UInt16]) throws {}

    func finish() throws -> Int {
        rows.count
    }
}
