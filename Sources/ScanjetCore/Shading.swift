import Foundation

/// Per-column CIS calibration (two-point flat field).
/// Sensor segments differ in sensitivity by 8–9%, and each column also has its
/// own black level: about 420 counts of spread, with even and odd pixels ~700
/// apart. Dividing by white alone fixes white but leaves bands in midtones and
/// shadows; subtracting a lamp-off frame first removes them.
public struct Shading: Sendable {
    /// White reference for each channel: [channel][column].
    public var reference: [[UInt16]]
    /// Level white is mapped to after correction.
    public var target: UInt16
    /// Lamp-off reference for each channel: [channel][column]. Profiles made
    /// before dark calibration have none and fall back to white-only correction.
    public var dark: [[UInt16]]?
    /// Level black is mapped to after correction (median of `dark`), so the
    /// tone curve keeps the same 16-bit scale as uncorrected data.
    public var darkLevel: UInt16

    public var width: Int { reference.first?.count ?? 0 }

    public init(reference: [[UInt16]], target: UInt16, dark: [[UInt16]]? = nil, darkLevel: UInt16 = 0) {
        self.reference = reference
        self.target = target
        self.dark = dark
        self.darkLevel = dark == nil ? 0 : darkLevel
    }

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

    /// Mean of every `step`-th RGB row in `rows`, per channel and column.
    private static func columnMeans(rawURL: URL, mode: ScanMode, rows: Range<Int>, step: Int) throws -> [[UInt16]] {
        let width = mode.samplesPerLine
        var sums = [[UInt64]](repeating: [UInt64](repeating: 0, count: width), count: 3)
        var count: UInt64 = 0

        let reader = try BlockReader(url: rawURL)
        for row in 0..<rows.upperBound {
            let use = row >= rows.lowerBound && row % step == 0
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

        return sums.map { channel in
            channel.map { UInt16(min(65535, $0 / max(1, count))) }
        }
    }

    private static func rawRows(_ rawURL: URL, mode: ScanMode) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: rawURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return size / (mode.bytesPerLine * 3)
    }

    /// Black level from a pass with the lamp off. The first rows are skipped
    /// while the AFE settles.
    public static func measureDark(rawURL: URL, mode: ScanMode) throws -> (dark: [[UInt16]], level: UInt16) {
        let rows = rawRows(rawURL, mode: mode)
        guard rows > 60 else {
            throw ScanjetError.io("dark pass is too short: \(rows) rows")
        }
        let dark = try columnMeans(rawURL: rawURL, mode: mode, rows: 20..<rows, step: 1)
        let sorted = dark[1].sorted()
        let level = sorted[sorted.count / 2]
        guard level < 16384 else {
            throw ScanjetError.io("dark pass is bright (median \(level)) — the lamp did not switch off")
        }
        return (dark, level)
    }

    /// Build a reference from a scan of a clean white sheet.
    /// Glass edges and the bottom of the bed are dropped — the sheet has already ended there.
    public static func measure(rawURL: URL, mode: ScanMode,
                               dark: (dark: [[UInt16]], level: UInt16)? = nil) throws -> Shading {
        let width = mode.samplesPerLine
        let rows = rawRows(rawURL, mode: mode)
        guard rows > 100 else {
            throw ScanjetError.io("calibration needs a full page")
        }

        // Every third row is enough; averaging the whole page is unnecessary.
        let reference = try columnMeans(rawURL: rawURL, mode: mode,
                                        rows: (rows * 15 / 100)..<(rows * 85 / 100), step: 3)

        let green = reference[1].sorted()
        let target = green[green.count / 2]
        guard target > max(4096, UInt16(min(65535, 2 * UInt32(dark?.level ?? 0)))) else {
            throw ScanjetError.io("sheet is too dark — white reference failed")
        }

        let low = reference[1].filter { $0 < target / 2 }.count
        if low > width / 10 {
            print("  warning: \(low) columns have almost no signal, the sheet does not cover the full width")
        }
        return Shading(reference: reference, target: target, dark: dark?.dark, darkLevel: dark?.level ?? 0)
    }

    /// Layout: "SJSH", width, target, white[3][width], then optionally
    /// "DARK", darkLevel, dark[3][width]. Older readers stop after white.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8]("SJSH".utf8)
        bytes.reserveCapacity(14 + width * 6 * 2)
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
        if let dark {
            bytes.append(contentsOf: Array("DARK".utf8))
            append(darkLevel)
            for channel in dark {
                for value in channel {
                    append(value)
                }
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
        func planes(at start: Int) -> [[UInt16]] {
            (0..<3).map { channel in
                (0..<width).map { x in word(start + (channel * width + x) * 2) }
            }
        }
        let reference = planes(at: 8)

        let darkStart = 8 + width * 3 * 2
        var dark: [[UInt16]]?
        var darkLevel: UInt16 = 0
        if bytes.count >= darkStart + 6 + width * 3 * 2,
           Array(bytes[darkStart..<(darkStart + 4)]) == Array("DARK".utf8) {
            darkLevel = word(darkStart + 4)
            dark = planes(at: darkStart + 6)
        }
        return Shading(reference: reference, target: target, dark: dark, darkLevel: darkLevel)
    }
}

/// Shading reduced to one multiply per sample:
/// out = darkLevel + (raw − dark) · (target − darkLevel) / (white − dark), in 16.16 fixed point.
/// Without a dark profile this is the plain raw · target / white.
struct ShadingCorrection {
    let dark: [[Int]]
    let gain: [[Int]]
    let base: Int

    init(_ shading: Shading) {
        let width = shading.width
        let base = Int(shading.darkLevel)
        let span = Int(shading.target) - base
        // A dead column has no usable reference: dark = base, gain = 1 passes it through unchanged.
        var dark = [[Int]](repeating: [Int](repeating: base, count: width), count: 3)
        var gain = [[Int]](repeating: [Int](repeating: 1 << 16, count: width), count: 3)
        for channel in 0..<3 {
            for x in 0..<width {
                let black = Int(shading.dark?[channel][x] ?? 0)
                let white = Int(shading.reference[channel][x]) - black
                guard white > 256, span > 0 else { continue }
                dark[channel][x] = black
                gain[channel][x] = (span << 16) / white
            }
        }
        self.dark = dark
        self.gain = gain
        self.base = base
    }

    /// Correct one raw sample of `channel` at sensor column `x`.
    @inline(__always)
    func apply(_ raw: Int, channel: Int, x: Int) -> UInt16 {
        UInt16(clamping: base + ((raw - dark[channel][x]) * gain[channel][x]) >> 16)
    }
}
