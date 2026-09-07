import XCTest
@testable import ScanjetCore

final class FrameDecoderTests: XCTestCase {
    func testDecodeProgressUsesExpectedRows() throws {
        let dir = try TestSupport.makeTempDir("scanjet-decode-progress")
        defer { try? FileManager.default.removeItem(at: dir) }

        let samples = 4
        let rgbRows = 4
        let raw = dir.appendingPathComponent("frame.raw")
        try writeCISFrame(to: raw, samplesPerLine: samples, rgbRows: rgbRows)

        let mode = ScanMode(dpi: 300, resource: "test", samplesPerLine: samples,
                            pageLines: UInt32(rgbRows * 3), feedLines: 0,
                            chunkBytes: samples * 2, secondsPerPage: 1)
        let lut = (0..<65536).map { UInt8($0 >> 8) }
        let lut16 = (0..<65536).map { UInt16($0) }
        let decoder = FrameDecoder(mode: mode, scale: 1, color: true, shading: nil,
                                   colorDepth: .millions, black: 0, white: 65535,
                                   lut: lut, lut16: lut16)
        let writer = CountingWriter()
        let expectedRows = 8
        var fractions = [Double]()
        let written = try decoder.run(from: raw, to: writer, expectedRows: expectedRows) { fraction in
            fractions.append(fraction)
        }

        XCTAssertEqual(written, rgbRows)
        XCTAssertEqual(writer.rows, rgbRows)
        XCTAssertEqual(fractions.count, rgbRows)
        for (i, fraction) in fractions.enumerated() {
            XCTAssertEqual(fraction, Double(i + 1) / Double(expectedRows), accuracy: 1e-9)
        }
        XCTAssertLessThan(fractions[0], 1)
        XCTAssertLessThan(fractions.last!, 1)
    }
}

private final class CountingWriter: PixelRowWriter {
    var rows = 0

    func write(row: [UInt8]) throws { rows += 1 }
    func write(row16: [UInt16]) throws { rows += 1 }
    func finish() throws -> Int { rows }
}

private func writeCISFrame(to url: URL, samplesPerLine: Int, rgbRows: Int, fill: UInt16 = 0x8000) throws {
    var data = Data()
    data.reserveCapacity(rgbRows * 3 * samplesPerLine * 2)
    let hi = UInt8(fill >> 8)
    let lo = UInt8(truncatingIfNeeded: fill)
    for _ in 0..<rgbRows {
        for _ in 0..<3 {
            for _ in 0..<samplesPerLine {
                data.append(hi)
                data.append(lo)
            }
        }
    }
    try data.write(to: url)
}
