import Foundation

/// Hardware CIS mode. Taken from Windows logs: the HP driver has exactly
/// four optical modes, each twice as dense as the previous one.
public struct ScanMode: Sendable {
    /// Optical resolution of the pass.
    public let dpi: Int
    public let resource: String
    public let samplesPerLine: Int
    public let pageLines: UInt32
    public let feedLines: UInt32
    public let chunkBytes: Int
    public let secondsPerPage: Double

    public var bytesPerLine: Int { samplesPerLine * 2 }
    public var pageRows: Int { Int(pageLines) / 3 }
    public var pageBytes: Int { Int(pageLines) * bytesPerLine }

    /// User-facing dpi values that downsample from this hardware pass.
    public var coveredOutputDPI: [Int] {
        Self.userOutputDPI.filter { dpi in
            (try? Self.choose(outputDPI: dpi))?.mode.dpi == self.dpi
        }
    }

    public static let all: [ScanMode] = [
        ScanMode(dpi: 300, resource: "hp_300", samplesPerLine: 2580,
                 pageLines: 10524, feedLines: 543, chunkBytes: 196080, secondsPerPage: 13),
        ScanMode(dpi: 600, resource: "hp_600", samplesPerLine: 5160,
                 pageLines: 21048, feedLines: 489, chunkBytes: 1042320, secondsPerPage: 47),
        ScanMode(dpi: 1200, resource: "hp_1200", samplesPerLine: 10320,
                 pageLines: 42096, feedLines: 552, chunkBytes: 1032000, secondsPerPage: 180),
        ScanMode(dpi: 2400, resource: "hp_2400", samplesPerLine: 20640,
                 pageLines: 84168, feedLines: 552, chunkBytes: 1032000, secondsPerPage: 707)
    ]

    /// User-facing output resolutions (matches the Windows driver).
    public static let userOutputDPI: [Int] = [75, 100, 150, 200, 300, 600, 1200, 2400]

    public static var supportedOutputDPI: [Int] { userOutputDPI }

    /// Pick the cheapest pass from which the target dpi is an integer downsample:
    /// 150 dpi is 300 dpi averaged 2×2.
    public static func choose(outputDPI: Int) throws -> (mode: ScanMode, scale: Int) {
        guard outputDPI > 0 else {
            throw ScanjetError.usage("dpi must be greater than zero")
        }
        guard userOutputDPI.contains(outputDPI) else {
            let list = userOutputDPI.map(String.init).joined(separator: ", ")
            throw ScanjetError.usage("dpi \(outputDPI) is not supported, available: \(list)")
        }
        for mode in all where mode.dpi % outputDPI == 0 {
            let scale = mode.dpi / outputDPI
            if scale <= 8 {
                return (mode, scale)
            }
        }
        let list = userOutputDPI.map(String.init).joined(separator: ", ")
        throw ScanjetError.usage("dpi \(outputDPI) is not supported, available: \(list)")
    }
}
