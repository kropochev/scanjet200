import XCTest
@testable import ScanjetCore

final class ShadingTests: XCTestCase {
    private func flat(_ value: UInt16, width: Int) -> [[UInt16]] {
        [[UInt16]](repeating: [UInt16](repeating: value, count: width), count: 3)
    }

    func testDarkProfileRoundTrips() throws {
        let dir = try TestSupport.makeTempDir("scanjet-shading-roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shading.bin")

        var white = flat(42_000, width: 8)
        white[2][5] = 39_000
        var dark = flat(5_200, width: 8)
        dark[1][3] = 5_900
        try Shading(reference: white, target: 42_000, dark: dark, darkLevel: 5_200).save(to: url)

        let loaded = try XCTUnwrap(Shading.load(from: url))
        XCTAssertEqual(loaded.reference, white)
        XCTAssertEqual(loaded.target, 42_000)
        XCTAssertEqual(loaded.dark, dark)
        XCTAssertEqual(loaded.darkLevel, 5_200)
    }

    func testWhiteOnlyProfileStillLoads() throws {
        let dir = try TestSupport.makeTempDir("scanjet-shading-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shading.bin")

        try Shading(reference: flat(40_000, width: 4), target: 40_000).save(to: url)
        let loaded = try XCTUnwrap(Shading.load(from: url))
        XCTAssertNil(loaded.dark)
        XCTAssertEqual(loaded.darkLevel, 0)

        let correction = ShadingCorrection(loaded)
        XCTAssertEqual(correction.apply(20_000, channel: 0, x: 1), 20_000)
    }

    /// Two columns with the same gain but a 700-count black offset (the CIS
    /// even/odd pattern) must come out equal at every grey level.
    func testDarkOffsetIsRemovedAtAllLevels() {
        let base: UInt16 = 5_000
        let target: UInt16 = 42_000
        var white = flat(target, width: 2)
        var dark = flat(base, width: 2)
        for channel in 0..<3 {
            dark[channel][1] = base + 700
            white[channel][1] = target + 700
        }
        let correction = ShadingCorrection(Shading(reference: white, target: target, dark: dark, darkLevel: base))

        for reflectance in [0.0, 0.05, 0.2, 0.5, 1.0] {
            let signal = Int(reflectance * Double(target - base))
            let even = correction.apply(Int(base) + signal, channel: 1, x: 0)
            let odd = correction.apply(Int(base) + 700 + signal, channel: 1, x: 1)
            XCTAssertEqual(Int(even), Int(odd), accuracy: 1, "reflectance \(reflectance)")
        }
        XCTAssertEqual(correction.apply(Int(base) + 700, channel: 0, x: 1), base)
        XCTAssertEqual(correction.apply(Int(target), channel: 0, x: 0), target)
    }

    func testDeadColumnPassesThrough() {
        var white = flat(42_000, width: 2)
        white[0][1] = 5_100
        let correction = ShadingCorrection(Shading(reference: white, target: 42_000,
                                                   dark: flat(5_000, width: 2), darkLevel: 5_000))
        XCTAssertEqual(correction.apply(12_345, channel: 0, x: 1), 12_345)
    }
}
