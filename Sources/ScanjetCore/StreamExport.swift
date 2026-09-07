import Foundation
import Darwin
import CScanjetUSB

enum StreamExport {
    static func write(fromTIFF tiff: URL, request: ScanRequest, output: URL, append: Bool) throws {
        if append && request.format == .tiff {
            try TIFFCombine.append(page: tiff, onto: output)
            return
        }
        guard let info = TIFFPreview.info(of: tiff) else {
            throw ScanjetError.io("cannot stream \(request.format.rawValue): TIFF is not an uncompressed strip")
        }
        if ImageExporter.canStreamPNG(request, append: append) {
            try PNGStream.write(fromTIFF: tiff, to: output, dpi: request.dpi)
            return
        }
        if (request.orientation == .deg90 || request.orientation == .deg270)
            && request.format == .tiff && request.kind != .text
            && !request.imageCorrection.shouldApply {
            try transpose(from: tiff, info: info, to: output, clockwise: request.orientation == .deg90,
                          dpi: request.dpi)
            return
        }

        if request.orientation == .deg90 || request.orientation == .deg270 {
            let tmp = output.deletingLastPathComponent()
                .appendingPathComponent(".scanjet-rot-\(UUID().uuidString).tiff")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try transpose(from: tiff, info: info, to: tmp, clockwise: request.orientation == .deg90,
                          dpi: request.dpi)
            if request.format == .png && request.kind != .text {
                try PNGStream.write(fromTIFF: tmp, to: output, dpi: request.dpi)
                return
            }
            guard let rotated = TIFFPreview.info(of: tmp) else {
                throw ScanjetError.io("rotated TIFF is unreadable")
            }
            var export = request
            export.orientation = .deg0
            try writeRows(from: tmp, info: rotated, request: export, output: output, append: append)
            return
        }

        try writeRows(from: tiff, info: info, request: request, output: output, append: append)
    }

    private static func writeRows(from tiff: URL, info: TIFFPreview.Info, request: ScanRequest,
                                  output: URL, append: Bool) throws {
        let spp = request.kind == .text ? 1 : info.samplesPerPixel
        let (outW, outH) = rotatedSize(width: info.width, height: info.height, orientation: request.orientation)
        let bps = request.format.supportsBillions ? info.bitsPerSample : min(info.bitsPerSample, 8)
        var writer: PixelRowWriter = try RasterWriter.make(
            format: request.format, path: output.path, width: outW, height: outH,
            samplesPerPixel: spp, bitsPerSample: bps, dpi: request.dpi, append: append
        )
        if !request.format.supportsBillions {
            writer = EightBitWriter(writer)
        }
        if request.kind == .text {
            writer = ThresholdWriter(writer, samplesPerPixel: info.samplesPerPixel)
        }
        if request.imageCorrection.shouldApply {
            writer = CorrectionWriter(writer, correction: request.imageCorrection,
                                      samplesPerPixel: info.samplesPerPixel)
        }
        switch request.orientation {
        case .deg0:
            try copyRows(from: tiff, info: info, reversed: false, reversePixels: false, into: writer)
        case .deg180:
            try copyRows(from: tiff, info: info, reversed: true, reversePixels: true, into: writer)
        case .deg90, .deg270:
            throw ScanjetError.io("rotated rows should be flattened before writeRows")
        }
        _ = try writer.finish()
    }

    private static func rotatedSize(width: Int, height: Int, orientation: ScanOrientation) -> (Int, Int) {
        switch orientation {
        case .deg0, .deg180: return (width, height)
        case .deg90, .deg270: return (height, width)
        }
    }

    private static func copyRows(from tiff: URL, info: TIFFPreview.Info, reversed: Bool,
                                 reversePixels: Bool, into writer: PixelRowWriter) throws {
        let handle = try FileHandle(forReadingFrom: tiff)
        handle.disableSystemCache()
        defer { try? handle.close() }
        var row = [UInt8](repeating: 0, count: info.bytesPerRow)
        let ys: [Int] = reversed
            ? Array(stride(from: info.height - 1, through: 0, by: -1))
            : Array(0..<info.height)
        for (n, y) in ys.enumerated() {
            try handle.seek(toOffset: UInt64(info.stripOffset + y * info.bytesPerRow))
            let got = try autoreleasepool { try handle.read(upToCount: info.bytesPerRow) } ?? Data()
            guard got.count == info.bytesPerRow else {
                throw ScanjetError.io("TIFF ended on row \(y)")
            }
            row.replaceSubrange(0..<info.bytesPerRow, with: got)
            if reversePixels {
                reverseRow(&row, info: info)
            }
            try writeRow(row, info: info, to: writer)
            if n % 64 == 0 || n + 1 == info.height {
                ScanLogger.log(.exporting, Double(n + 1) / Double(info.height), "")
            }
        }
    }

    private static func writeRow(_ row: [UInt8], info: TIFFPreview.Info, to writer: PixelRowWriter) throws {
        if info.bitsPerSample == 8 {
            try writer.write(row: row)
            return
        }
        try writer.writePackedLE16(row)
    }

    private static func reverseRow(_ row: inout [UInt8], info: TIFFPreview.Info) {
        let bpp = info.samplesPerPixel * (info.bitsPerSample / 8)
        var x0 = 0
        var x1 = info.width - 1
        var tmp = [UInt8](repeating: 0, count: bpp)
        while x0 < x1 {
            let a = x0 * bpp
            let b = x1 * bpp
            tmp.replaceSubrange(0..<bpp, with: row[a..<(a + bpp)])
            row.replaceSubrange(a..<(a + bpp), with: row[b..<(b + bpp)])
            row.replaceSubrange(b..<(b + bpp), with: tmp)
            x0 += 1
            x1 -= 1
        }
    }

    static func transpose(from tiff: URL, info: TIFFPreview.Info, to output: URL, clockwise: Bool,
                          dpi: Int) throws {
        let srcW = info.width
        let srcH = info.height
        let bpp = info.bytesPerRow / max(srcW, 1)
        let outW = srcH
        let outH = srcW
        let stripBytes = outH * outW * bpp

        FileManager.default.createFile(atPath: output.path, contents: nil)
        let fd = Darwin.open(output.path, O_RDWR)
        guard fd >= 0 else { throw ScanjetError.io("cannot create rotated TIFF") }
        defer { Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_NOCACHE, 1)
        let header: [UInt8] = [0x49, 0x49, 42, 0, 0, 0, 0, 0]
        guard Darwin.write(fd, header, 8) == 8 else {
            throw ScanjetError.io("cannot write rotated TIFF header")
        }
        guard Darwin.ftruncate(fd, off_t(8 + stripBytes)) == 0 else {
            throw ScanjetError.io("cannot resize rotated TIFF")
        }

        let cb: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { fraction, _ in
            ScanLogger.log(.exporting, fraction, "rotating")
        }
        let rc = tiff.path.withCString { srcPath in
            output.path.withCString { dstPath in
                scanjet_transpose_strip(srcPath, UInt64(info.stripOffset),
                                        UInt32(srcW), UInt32(srcH), Int32(bpp),
                                        clockwise ? 1 : 0,
                                        dstPath, 8, cb, nil)
            }
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_transpose_last_error()))
        }
        try TIFFWriter.writeIFD(to: output, width: outW, height: outH, samplesPerPixel: info.samplesPerPixel,
                                bitsPerSample: info.bitsPerSample, dpi: dpi, stripBytes: stripBytes)
    }
}

enum TIFFCombine {
    static func append(page: URL, onto existing: URL) throws {
        guard let info = TIFFPreview.info(of: page) else {
            throw ScanjetError.io("cannot append TIFF: page is not an uncompressed strip")
        }
        if !FileManager.default.fileExists(atPath: existing.path) {
            try FileManager.default.copyItem(at: page, to: existing)
            return
        }
        let dest = try FileHandle(forUpdating: existing)
        dest.disableSystemCache()
        defer { try? dest.close() }
        guard let header = try dest.read(upToCount: 8), header.count == 8,
              header[0] == 0x49, header[1] == 0x49 else {
            throw ScanjetError.io("cannot append to a non-little-endian TIFF")
        }
        var ifd = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
        var lastNextOffset = 4
        while ifd != 0 {
            try dest.seek(toOffset: UInt64(ifd))
            guard let countBytes = try dest.read(upToCount: 2), countBytes.count == 2 else {
                throw ScanjetError.io("truncated TIFF IFD")
            }
            let count = Int(UInt16(countBytes[0]) | UInt16(countBytes[1]) << 8)
            lastNextOffset = ifd + 2 + count * 12
            try dest.seek(toOffset: UInt64(lastNextOffset))
            guard let nextBytes = try dest.read(upToCount: 4), nextBytes.count == 4 else {
                throw ScanjetError.io("truncated TIFF IFD link")
            }
            ifd = Int(UInt32(nextBytes[0]) | UInt32(nextBytes[1]) << 8
                      | UInt32(nextBytes[2]) << 16 | UInt32(nextBytes[3]) << 24)
        }
        let pageBytes = info.bytesPerRow * info.height
        let newStrip = try dest.seekToEnd()
        let src = try FileHandle(forReadingFrom: page)
        src.disableSystemCache()
        defer { try? src.close() }
        try src.seek(toOffset: UInt64(info.stripOffset))
        var remaining = pageBytes
        while remaining > 0 {
            let chunk = try src.read(upToCount: min(remaining, 4 << 20)) ?? Data()
            if chunk.isEmpty { break }
            try dest.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        let ifdOffset = try dest.seekToEnd()
        try TIFFWriter.writeIFD(handle: dest, width: info.width, height: info.height,
                                samplesPerPixel: info.samplesPerPixel, bitsPerSample: info.bitsPerSample,
                                dpi: 75, stripOffset: UInt32(newStrip), stripBytes: UInt32(pageBytes),
                                ifdOffset: UInt32(ifdOffset))
        try dest.seek(toOffset: UInt64(lastNextOffset))
        var next = UInt32(ifdOffset).littleEndian
        try dest.write(contentsOf: Data(bytes: &next, count: 4))
        try dest.synchronize()
    }
}
