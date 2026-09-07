import XCTest
@testable import ScanjetCore

final class LivePreviewTests: XCTestCase {
    func testLivePreviewSamplesRedCISRow() {
        let mode = ScanMode.all[0]
        let live = LiveCISPreview(mode: mode, scale: 1, color: true, shading: nil,
                                  lut: highByteLUT(),
                                  skipRaw: 0, cropStart: 0, cropEnd: mode.samplesPerLine,
                                  expectedOut: 8, maxDimension: 1600)
        var row = [UInt8](repeating: 0, count: mode.bytesPerLine * 3)
        for x in 0..<mode.samplesPerLine {
            let i = (mode.samplesPerLine - 1 - x) * 2
            row[i] = 0xff
            row[i + 1] = 0x00
        }
        var band = live.ingest(row)
        if band == nil {
            band = live.flush()
        }
        guard let band else {
            return XCTFail("live preview produced no rows")
        }
        XCTAssertEqual(band.y, 0)
        XCTAssertGreaterThanOrEqual(band.rows, 1)
        XCTAssertEqual(band.rgba.count, band.rows * band.width * 4)
        XCTAssertEqual(band.rgba[0], 255)
        XCTAssertEqual(band.rgba[1], 0)
        XCTAssertEqual(band.rgba[2], 0)
        XCTAssertEqual(band.rgba[3], 255)
    }

    func testLivePreviewSplitsChunks() {
        let mode = ScanMode.all[0]
        let live = LiveCISPreview(mode: mode, scale: 1, color: true, shading: nil,
                                  lut: highByteLUT(),
                                  skipRaw: 0, cropStart: 0, cropEnd: mode.samplesPerLine,
                                  expectedOut: 4, maxDimension: 800)
        var row = [UInt8](repeating: 0, count: mode.bytesPerLine * 3)
        for x in 0..<mode.samplesPerLine {
            let i = x * 2
            row[i] = 0x40
            row[i + 1] = 0x00
        }
        let mid = row.count / 2
        XCTAssertNil(live.ingest(Array(row[..<mid])))
        var band = live.ingest(Array(row[mid...]))
        if band == nil { band = live.flush() }
        XCTAssertNotNil(band)
        XCTAssertEqual(band?.y, 0)
    }

    func testLivePreviewAppliesShadingThenToneCurve() {
        let mode = ScanMode.all[0]
        let width = mode.samplesPerLine
        let target: UInt16 = 40_000
        var reference = [
            [UInt16](repeating: target, count: width),
            [UInt16](repeating: target, count: width),
            [UInt16](repeating: target, count: width)
        ]
        // Sensor is mirrored in the live sampler (column 0 is the last CIS sample).
        reference[0][width - 1] = 50_000
        reference[1][width - 1] = 25_000
        reference[2][width - 1] = target
        let shading = Shading(reference: reference, target: target)
        let lut = ToneCurve.previewLUT(shading: shading, gamma: nil)
        let live = LiveCISPreview(mode: mode, scale: 1, color: true, shading: shading,
                                  lut: lut,
                                  skipRaw: 0, cropStart: 0, cropEnd: width,
                                  expectedOut: 4, maxDimension: 1600)

        var row = [UInt8](repeating: 0, count: mode.bytesPerLine * 3)
        func write(_ channel: Int, sample: Int, value: UInt16) {
            let i = channel * mode.bytesPerLine + sample * 2
            row[i] = UInt8(value >> 8)
            row[i + 1] = UInt8(value & 0xff)
        }
        write(0, sample: width - 1, value: 30_000)
        write(1, sample: width - 1, value: 30_000)
        write(2, sample: width - 1, value: 30_000)

        var band = live.ingest(row)
        if band == nil { band = live.flush() }
        guard let band else {
            return XCTFail("live preview produced no rows")
        }

        let r = Int(band.rgba[0])
        let g = Int(band.rgba[1])
        let b = Int(band.rgba[2])
        XCTAssertLessThan(r, b, "hot red column should be pulled down")
        XCTAssertGreaterThan(g, b, "dim green column should be lifted")
        XCTAssertEqual(band.rgba[3], 255)
    }

    private func highByteLUT() -> [UInt8] {
        (0..<65536).map { UInt8($0 >> 8) }
    }
}
