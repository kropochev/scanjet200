import Foundation
import CoreGraphics

/// Reads the uncompressed packed TIFF that `TIFFWriter` produces, one source
/// row at a time, so a 1600 px preview does not decode a 3 GB frame.
enum TIFFPreview {
    struct Info {
        var width: Int
        var height: Int
        var samplesPerPixel: Int
        var bitsPerSample: Int
        var stripOffset: Int
        var bytesPerRow: Int
    }

    static func info(of url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        handle.disableSystemCache()
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8,
              header[0] == 0x49, header[1] == 0x49,
              u16(header, 2) == 42 else {
            return nil
        }
        let ifd = Int(u32(header, 4))
        guard (try? handle.seek(toOffset: UInt64(ifd))) != nil,
              let countBytes = try? handle.read(upToCount: 2), countBytes.count == 2 else {
            return nil
        }
        let count = Int(u16(countBytes, 0))
        guard count > 0, count < 64,
              let entries = try? handle.read(upToCount: count * 12),
              entries.count == count * 12 else {
            return nil
        }

        var width = 0, height = 0, spp = 0, compression = 0
        var bits = 0, stripOffset = 0, stripCount = 0

        for i in 0..<count {
            let at = i * 12
            let tag = u16(entries, at)
            let type = u16(entries, at + 2)
            let n = u32(entries, at + 4)
            let value = u32(entries, at + 8)
            switch tag {
            case 256: width = Int(value)
            case 257: height = Int(value)
            case 258:
                if n == 1 {
                    bits = Int(value)
                } else if type == 3 {
                    if let b = try? readU16(handle, at: Int(value)) { bits = Int(b) }
                }
            case 259: compression = Int(value)
            case 273:
                stripCount = Int(n)
                stripOffset = Int(value)
            case 277: spp = Int(value)
            default: break
            }
        }

        guard compression == 1, stripCount == 1, width > 0, height > 0,
              spp == 1 || spp == 3, bits == 8 || bits == 16, stripOffset >= 8 else {
            return nil
        }
        let bytesPerRow = width * spp * (bits / 8)
        return Info(width: width, height: height, samplesPerPixel: spp,
                    bitsPerSample: bits, stripOffset: stripOffset, bytesPerRow: bytesPerRow)
    }

    static func subsampledImage(from url: URL, maxDimension: Int) throws -> CGImage? {
        guard let info = info(of: url) else { return nil }
        let factor = max(1, (max(info.width, info.height) + maxDimension - 1) / maxDimension)
        let outW = max(1, info.width / factor)
        let outH = max(1, info.height / factor)

        let handle = try FileHandle(forReadingFrom: url)
        handle.disableSystemCache()
        defer { try? handle.close() }

        var pixels = [UInt8](repeating: 0, count: outW * outH * 4)
        var row = [UInt8](repeating: 0, count: info.bytesPerRow)

        for oy in 0..<outH {
            let sy = min(info.height - 1, oy * factor)
            try handle.seek(toOffset: UInt64(info.stripOffset + sy * info.bytesPerRow))
            let got = try handle.read(upToCount: info.bytesPerRow) ?? Data()
            guard got.count == info.bytesPerRow else { return nil }
            row.replaceSubrange(0..<info.bytesPerRow, with: got)

            for ox in 0..<outW {
                let sx = min(info.width - 1, ox * factor)
                let dst = (oy * outW + ox) * 4
                if info.samplesPerPixel == 3 {
                    let (r, g, b) = sampleRGB(row, x: sx, bits: info.bitsPerSample)
                    pixels[dst] = r
                    pixels[dst + 1] = g
                    pixels[dst + 2] = b
                    pixels[dst + 3] = 255
                } else {
                    let v = sampleGray(row, x: sx, bits: info.bitsPerSample)
                    pixels[dst] = v
                    pixels[dst + 1] = v
                    pixels[dst + 2] = v
                    pixels[dst + 3] = 255
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: outW * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        return ctx.makeImage()
    }

    private static func readU16(_ handle: FileHandle, at offset: Int) throws -> UInt16 {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: 2) ?? Data()
        guard data.count == 2 else { throw ScanjetError.io("short TIFF tag") }
        return u16(data, 0)
    }

    private static func sampleRGB(_ row: [UInt8], x: Int, bits: Int) -> (UInt8, UInt8, UInt8) {
        if bits == 8 {
            let i = x * 3
            return (row[i], row[i + 1], row[i + 2])
        }
        let i = x * 6
        return (u8from16(row, i), u8from16(row, i + 2), u8from16(row, i + 4))
    }

    private static func sampleGray(_ row: [UInt8], x: Int, bits: Int) -> UInt8 {
        if bits == 8 { return row[x] }
        return u8from16(row, x * 2)
    }

    private static func u8from16(_ row: [UInt8], _ offset: Int) -> UInt8 {
        let v = UInt16(row[offset]) | UInt16(row[offset + 1]) << 8
        return UInt8(v >> 8)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
