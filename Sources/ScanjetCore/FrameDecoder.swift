import Foundation

/// CIS data is linear reflectance; displays expect sRGB (or a custom gamma).
enum ToneCurve {
    static func make(black: UInt16, white: UInt16, gamma: Double?) -> (lut8: [UInt8], lut16: [UInt16]) {
        let lo = Double(black)
        let span = max(1.0, Double(white) - lo)
        var lut8 = [UInt8](repeating: 0, count: 65536)
        var lut16 = [UInt16](repeating: 0, count: 65536)
        for v in (Int(black) + 1)..<65536 {
            let linear = min(1.0, (Double(v) - lo) / span)
            let encoded: Double
            if let gamma, gamma > 0 {
                encoded = pow(linear, 1.0 / gamma)
            } else {
                encoded = linear <= 0.0031308
                    ? 12.92 * linear
                    : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
            }
            lut8[v] = UInt8(max(0, min(255, (encoded * 255).rounded())))
            lut16[v] = UInt16(max(0, min(65535, (encoded * 65535).rounded())))
        }
        return (lut8, lut16)
    }

    /// Live view cannot wait for frame percentiles. With a profile, white is the
    /// calibration target and black is the same 10% floor as decode. Without one,
    /// use the full 16-bit range so the preview is still sRGB, not linear.
    static func previewLUT(shading: Shading?, gamma: Double?) -> [UInt8] {
        if let shading {
            let white = max(shading.target, 1)
            let black = UInt16(UInt32(white) / 10)
            return make(black: black, white: white, gamma: gamma).lut8
        }
        return make(black: 6554, white: 65535, gamma: gamma).lut8
    }
}

/// Buffered read of the raw frame from disk: at 2400 dpi that is 3.5 GB,
/// so the decoder walks the file line by line instead of loading it whole.
final class BlockReader {
    private let handle: FileHandle
    private var buffer = [UInt8]()
    private var offset = 0
    private let blockSize: Int

    init(url: URL, blockSize: Int = 8 << 20) throws {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ScanjetError.io("cannot open for reading: \(url.path)")
        }
        handle.disableSystemCache()
        self.handle = handle
        self.blockSize = blockSize
    }

    deinit {
        try? handle.close()
    }

    func read(_ count: Int) throws -> ArraySlice<UInt8>? {
        while buffer.count - offset < count {
            let next: Data? = try autoreleasepool {
                try handle.read(upToCount: max(blockSize, count))
            }
            guard let next, !next.isEmpty else {
                return nil
            }
            if offset > 0 {
                buffer.removeFirst(offset)
                offset = 0
            }
            buffer.append(contentsOf: next)
        }
        let slice = buffer[offset..<(offset + count)]
        offset += count
        return slice
    }
}

/// Turns raw CIS lines into pixels: un-mirror, shading, downsample, then 8- or 16-bit output.
public struct FrameDecoder {
    public let mode: ScanMode
    public let scale: Int
    public let color: Bool
    public let shading: Shading?
    public let colorDepth: ColorDepth
    public let black: UInt16
    public let white: UInt16
    public let lut: [UInt8]
    public let lut16: [UInt16]
    public let cropStart: Int
    public let cropEnd: Int
    public let skipRows: Int

    public init(mode: ScanMode, scale: Int, color: Bool, shading: Shading?,
                colorDepth: ColorDepth, black: UInt16, white: UInt16,
                lut: [UInt8], lut16: [UInt16],
                cropStart: Int = 0, cropEnd: Int? = nil, skipRows: Int = 0) {
        self.mode = mode
        self.scale = scale
        self.color = color
        self.shading = shading
        self.colorDepth = colorDepth
        self.black = black
        self.white = white
        self.lut = lut
        self.lut16 = lut16
        self.cropStart = max(0, min(mode.samplesPerLine, cropStart))
        self.cropEnd = min(mode.samplesPerLine, cropEnd ?? mode.samplesPerLine)
        self.skipRows = max(0, skipRows)
    }

    public var croppedWidth: Int { max(0, cropEnd - cropStart) }
    public var outputWidth: Int { max(1, croppedWidth / scale) }
    public var samplesPerPixel: Int { color ? 3 : 1 }

    private func loadRGB(_ reader: BlockReader, into planes: inout [[UInt16]]) throws -> Bool {
        let width = mode.samplesPerLine
        for channel in 0..<3 {
            guard let bytes = try reader.read(mode.bytesPerLine) else { return false }
            let base = bytes.startIndex
            let reference = shading?.reference[channel]
            let target = UInt32(shading?.target ?? 0)
            for x in 0..<width {
                let i = base + (width - 1 - x) * 2
                var value = UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
                if let reference {
                    let ref = UInt32(reference[width - 1 - x])
                    if ref > 256 {
                        value = min(65535, value * target / ref)
                    }
                }
                planes[channel][x] = UInt16(value)
            }
        }
        return true
    }

    private func linear16(_ averaged: UInt32) -> UInt16 {
        lut16[Int(min(65535, averaged))]
    }

    func run(from url: URL, to writer: PixelRowWriter, expectedRows: Int,
             progress: (Double) throws -> Void) throws -> Int {
        let reader = try BlockReader(url: url)
        let width = mode.samplesPerLine
        let outW = outputWidth
        let channels = samplesPerPixel
        let c0 = cropStart
        let c1 = cropEnd

        var planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width), count: 3)
        var accum = [UInt32](repeating: 0, count: outW * channels)
        var out8 = [UInt8](repeating: 0, count: outW * channels)
        var out16 = [UInt16](repeating: 0, count: outW * channels)
        var rowsInAccum = 0
        var skipped = 0
        var written = 0
        let expected = max(expectedRows, 1)
        let divisor = UInt32(scale * scale)
        let billions = colorDepth == .billions

        while try loadRGB(reader, into: &planes) {
            for ox in 0..<outW {
                let from = c0 + ox * scale
                if color {
                    for channel in 0..<3 {
                        var sum: UInt32 = 0
                        for k in 0..<scale {
                            let x = from + k
                            if x < c1 { sum += UInt32(planes[channel][x]) }
                        }
                        accum[ox * 3 + channel] += sum
                    }
                } else {
                    var sum: UInt32 = 0
                    for k in 0..<scale {
                        let x = from + k
                        if x < c1 {
                            let r = UInt32(planes[0][x])
                            let g = UInt32(planes[1][x])
                            let b = UInt32(planes[2][x])
                            sum += (r * 77 + g * 150 + b * 29) >> 8
                        }
                    }
                    accum[ox] += sum
                }
            }
            rowsInAccum += 1

            if rowsInAccum == scale {
                if skipped < skipRows {
                    skipped += 1
                } else if billions {
                    for i in 0..<accum.count {
                        out16[i] = linear16(accum[i] / divisor)
                    }
                    try writer.write(row16: out16)
                    written += 1
                    try progress(Double(written) / Double(expected))
                } else {
                    for i in 0..<accum.count {
                        out8[i] = lut[Int(min(65535, accum[i] / divisor))]
                    }
                    try writer.write(row: out8)
                    written += 1
                    try progress(Double(written) / Double(expected))
                }
                accum.replaceSubrange(0..<accum.count, with: repeatElement(0, count: accum.count))
                rowsInAccum = 0
            }
        }
        return written
    }
}
