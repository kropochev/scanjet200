import Foundation

/// Per-column CIS calibration (plain flat field).
/// Sensor segments differ in sensitivity by 8–9%, which shows as vertical
/// bands; dividing by a white reference reduces that to noise.
public struct Shading: Sendable {
    /// White reference for each channel: [channel][column].
    public var reference: [[UInt16]]
    /// Level white is mapped to after correction.
    public var target: UInt16

    public var width: Int { reference.first?.count ?? 0 }

    /// Each hardware pass has its own sensor width, so each has its own reference.
    public static func defaultURL(for mode: ScanMode) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("scanjet/shading-\(mode.dpi).bin")
    }

    public static func profileExists(for mode: ScanMode) -> Bool {
        FileManager.default.fileExists(atPath: defaultURL(for: mode).path)
    }

    /// Hardware dpi values that already have a shading file on this Mac.
    public static func installedDPI() -> Set<Int> {
        Set(ScanMode.all.filter(profileExists(for:)).map(\.dpi))
    }

    /// Build a reference from a scan of a clean white sheet.
    /// Glass edges and the bottom of the bed are dropped — the sheet has already ended there.
    public static func measure(rawURL: URL, mode: ScanMode) throws -> Shading {
        let width = mode.samplesPerLine
        let attributes = try? FileManager.default.attributesOfItem(atPath: rawURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let rows = size / (mode.bytesPerLine * 3)
        guard rows > 100 else {
            throw ScanjetError.io("calibration needs a full page")
        }

        let first = rows * 15 / 100
        let last = rows * 85 / 100
        var sums = [[UInt64]](repeating: [UInt64](repeating: 0, count: width), count: 3)
        var count: UInt64 = 0

        let reader = try BlockReader(url: rawURL)
        for row in 0..<last {
            // Every third row is enough; averaging the whole page is unnecessary.
            let use = row >= first && row % 3 == 0
            for channel in 0..<3 {
                guard let bytes = try reader.read(mode.bytesPerLine) else {
                    throw ScanjetError.io("raw frame ended on row \(row)")
                }
                guard use else { continue }
                let base = bytes.startIndex
                for x in 0..<width {
                    let i = base + x * 2
                    sums[channel][x] += UInt64(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                }
            }
            if use { count += 1 }
        }

        var reference = [[UInt16]](repeating: [UInt16](repeating: 0, count: width), count: 3)
        for channel in 0..<3 {
            for x in 0..<width {
                reference[channel][x] = UInt16(min(65535, sums[channel][x] / max(1, count)))
            }
        }

        let green = reference[1].sorted()
        let target = green[green.count / 2]
        guard target > 4096 else {
            throw ScanjetError.io("sheet is too dark — white reference failed")
        }

        let low = reference[1].filter { $0 < target / 2 }.count
        if low > width / 10 {
            print("  warning: \(low) columns have almost no signal, the sheet does not cover the full width")
        }
        return Shading(reference: reference, target: target)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8]("SJSH".utf8)
        bytes.reserveCapacity(8 + width * 3 * 2)
        func append(_ value: UInt16) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8(value >> 8))
        }
        append(UInt16(width))
        append(target)
        for channel in reference {
            for value in channel {
                append(value)
            }
        }
        try Data(bytes).write(to: url)
    }

    public static func load(from url: URL) -> Shading? {
        guard let data = try? Data(contentsOf: url), data.count > 8,
              data.prefix(4) == Data("SJSH".utf8) else {
            return nil
        }
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        let width = Int(word(4))
        let target = word(6)
        guard width > 0, bytes.count >= 8 + width * 3 * 2 else { return nil }
        var reference = [[UInt16]]()
        for channel in 0..<3 {
            var row = [UInt16](repeating: 0, count: width)
            for x in 0..<width {
                row[x] = word(8 + (channel * width + x) * 2)
            }
            reference.append(row)
        }
        return Shading(reference: reference, target: target)
    }
}
