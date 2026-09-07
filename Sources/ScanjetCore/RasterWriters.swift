import Foundation
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import CScanjetUSB

enum RasterWriter {
    static func make(format: OutputFormat, path: String, width: Int, height: Int,
                     samplesPerPixel: Int, bitsPerSample: Int, dpi: Int,
                     append: Bool = false) throws -> PixelRowWriter {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !append, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        switch format {
        case .tiff:
            return try TIFFWriter(path: path, width: width, samplesPerPixel: samplesPerPixel,
                                  dpi: dpi, bitsPerSample: bitsPerSample)
        case .png:
            return try PNGRowWriter(path: path, width: width, height: height,
                                    samplesPerPixel: samplesPerPixel, bitsPerSample: bitsPerSample, dpi: dpi)
        case .jpeg:
            return try JPEGRowWriter(path: path, width: width, height: height,
                                     samplesPerPixel: samplesPerPixel, dpi: dpi)
        case .bmp:
            return try BMPRowWriter(path: path, width: width, height: height,
                                    samplesPerPixel: samplesPerPixel)
        case .gif:
            return try GIFRowWriter(path: path, width: width, height: height,
                                    samplesPerPixel: samplesPerPixel)
        case .pdf:
            return try PDFRowWriter(path: path, width: width, height: height,
                                    samplesPerPixel: samplesPerPixel, dpi: dpi, append: append)
        case .heic, .jpeg2000:
            return try ImageIORowWriter(path: path, format: format, width: width, height: height,
                                        samplesPerPixel: samplesPerPixel, dpi: dpi)
        }
    }
}

final class EightBitWriter: PixelRowWriter {
    private let inner: PixelRowWriter
    private var scratch = [UInt8]()

    init(_ inner: PixelRowWriter) {
        self.inner = inner
    }

    func write(row: [UInt8]) throws {
        try inner.write(row: row)
    }

    func write(row16: [UInt16]) throws {
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(row16.count)
        for value in row16 {
            scratch.append(UInt8(value >> 8))
        }
        try inner.write(row: scratch)
    }

    func finish() throws -> Int {
        try inner.finish()
    }
}

final class ThresholdWriter: PixelRowWriter {
    private let inner: PixelRowWriter
    private let samplesPerPixel: Int
    private var scratch = [UInt8]()
    private let cutoff: UInt8

    init(_ inner: PixelRowWriter, samplesPerPixel: Int, cutoff: UInt8 = 180) {
        self.inner = inner
        self.samplesPerPixel = samplesPerPixel
        self.cutoff = cutoff
    }

    func write(row: [UInt8]) throws {
        try inner.write(row: threshold(row))
    }

    func write(row16: [UInt16]) throws {
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(row16.count)
        for value in row16 {
            scratch.append(UInt8(value >> 8))
        }
        try inner.write(row: threshold(scratch))
    }

    func finish() throws -> Int {
        try inner.finish()
    }

    private func threshold(_ row: [UInt8]) -> [UInt8] {
        if samplesPerPixel == 1 {
            return row.map { $0 >= cutoff ? 255 : 0 }
        }
        var out = [UInt8](repeating: 0, count: row.count / 3)
        var i = 0
        var o = 0
        while i + 2 < row.count {
            let y = (77 * Int(row[i]) + 150 * Int(row[i + 1]) + 29 * Int(row[i + 2])) >> 8
            out[o] = y >= Int(cutoff) ? 255 : 0
            i += 3
            o += 1
        }
        return out
    }
}

final class JPEGRowWriter: PixelRowWriter {
    private var writer: OpaquePointer?
    private let width: Int
    private let samplesPerPixel: Int

    init(path: String, width: Int, height: Int, samplesPerPixel: Int, dpi: Int) throws {
        guard let opened = scanjet_jpeg_open(path, UInt32(width), UInt32(height),
                                             Int32(samplesPerPixel), UInt32(max(dpi, 1)), 92) else {
            throw ScanjetError.io(String(cString: scanjet_jpeg_last_error()))
        }
        self.writer = opened
        self.width = width
        self.samplesPerPixel = samplesPerPixel
    }

    deinit {
        if let writer { _ = scanjet_jpeg_close(writer) }
    }

    func write(row: [UInt8]) throws {
        guard let writer else { throw ScanjetError.io("JPEG writer already closed") }
        let rc = row.withUnsafeBytes { ptr in
            scanjet_jpeg_write_row(writer, ptr.bindMemory(to: UInt8.self).baseAddress, ptr.count)
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_jpeg_last_error()))
        }
    }

    func write(row16: [UInt16]) throws {
        var row = [UInt8](repeating: 0, count: row16.count)
        for i in 0..<row16.count { row[i] = UInt8(row16[i] >> 8) }
        try write(row: row)
    }

    func finish() throws -> Int {
        guard let current = writer else { return 0 }
        writer = nil
        guard scanjet_jpeg_close(current) == 0 else {
            throw ScanjetError.io(String(cString: scanjet_jpeg_last_error()))
        }
        return 0
    }
}

final class BMPRowWriter: PixelRowWriter {
    private let handle: FileHandle
    private let width: Int
    private let height: Int
    private let samplesPerPixel: Int
    private let rowStride: Int
    private var y = 0

    init(path: String, width: Int, height: Int, samplesPerPixel: Int) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw ScanjetError.io("cannot create \(path)")
        }
        handle.disableSystemCache()
        self.handle = handle
        self.width = width
        self.height = height
        self.samplesPerPixel = samplesPerPixel
        let bpp = samplesPerPixel == 1 ? 1 : 3
        self.rowStride = (width * bpp + 3) & ~3

        let palette = samplesPerPixel == 1 ? 256 * 4 : 0
        let pixelBytes = rowStride * height
        let offBits = 14 + 40 + palette
        var hdr = Data()
        hdr.append(contentsOf: [0x42, 0x4d])
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        u32(UInt32(offBits + pixelBytes))
        u32(0)
        u32(UInt32(offBits))
        u32(40)
        i32(Int32(width))
        i32(-Int32(height))
        u16(1)
        u16(UInt16(bpp * 8))
        u32(0)
        u32(UInt32(pixelBytes))
        i32(2835)
        i32(2835)
        u32(UInt32(samplesPerPixel == 1 ? 256 : 0))
        u32(0)
        try handle.write(contentsOf: hdr)
        if samplesPerPixel == 1 {
            var pal = Data(count: 1024)
            for i in 0..<256 {
                pal[i * 4] = UInt8(i)
                pal[i * 4 + 1] = UInt8(i)
                pal[i * 4 + 2] = UInt8(i)
            }
            try handle.write(contentsOf: pal)
        }
    }

    func write(row: [UInt8]) throws {
        var out = [UInt8](repeating: 0, count: rowStride)
        if samplesPerPixel == 1 {
            for x in 0..<width { out[x] = row[x] }
        } else {
            for x in 0..<width {
                out[x * 3] = row[x * 3 + 2]
                out[x * 3 + 1] = row[x * 3 + 1]
                out[x * 3 + 2] = row[x * 3]
            }
        }
        try handle.write(contentsOf: Data(out))
        y += 1
    }

    func write(row16: [UInt16]) throws {
        var row = [UInt8](repeating: 0, count: row16.count)
        for i in 0..<row16.count { row[i] = UInt8(row16[i] >> 8) }
        try write(row: row)
    }

    func finish() throws -> Int {
        try handle.synchronize()
        try handle.close()
        return y
    }
}

final class GIFRowWriter: PixelRowWriter {
    private let handle: FileHandle
    private let width: Int
    private let height: Int
    private let samplesPerPixel: Int
    private var y = 0
    private var bitBuf: UInt32 = 0
    private var bitCount = 0
    private var block = Data()

    init(path: String, width: Int, height: Int, samplesPerPixel: Int) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw ScanjetError.io("cannot create \(path)")
        }
        handle.disableSystemCache()
        self.handle = handle
        self.width = width
        self.height = height
        self.samplesPerPixel = samplesPerPixel

        var hdr = Data("GIF89a".utf8)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        u16(UInt16(width))
        u16(UInt16(height))
        hdr.append(0xf7)
        hdr.append(0)
        hdr.append(0)
        for i in 0..<256 {
            if samplesPerPixel == 1 {
                hdr.append(contentsOf: [UInt8(i), UInt8(i), UInt8(i)])
            } else if i < 216 {
                let r = UInt8((i / 36) * 51)
                let g = UInt8(((i / 6) % 6) * 51)
                let b = UInt8((i % 6) * 51)
                hdr.append(contentsOf: [r, g, b])
            } else {
                let g = UInt8((i - 216) * 6)
                hdr.append(contentsOf: [g, g, g])
            }
        }
        hdr.append(0x2c)
        u16(0); u16(0)
        u16(UInt16(width))
        u16(UInt16(height))
        hdr.append(0)
        hdr.append(8)
        try handle.write(contentsOf: hdr)
        try emit(256, bits: 9)
    }

    func write(row: [UInt8]) throws {
        if samplesPerPixel == 1 {
            for x in 0..<width {
                try emit(Int(row[x]), bits: 9)
                if (y * width + x + 1) % 100 == 0 {
                    try emit(256, bits: 9)
                }
            }
        } else {
            for x in 0..<width {
                let r = min(5, Int(row[x * 3]) * 6 / 256)
                let g = min(5, Int(row[x * 3 + 1]) * 6 / 256)
                let b = min(5, Int(row[x * 3 + 2]) * 6 / 256)
                try emit(r * 36 + g * 6 + b, bits: 9)
                if (y * width + x + 1) % 100 == 0 {
                    try emit(256, bits: 9)
                }
            }
        }
        y += 1
    }

    func write(row16: [UInt16]) throws {
        var row = [UInt8](repeating: 0, count: row16.count)
        for i in 0..<row16.count { row[i] = UInt8(row16[i] >> 8) }
        try write(row: row)
    }

    func finish() throws -> Int {
        try emit(257, bits: 9)
        try flushBits()
        try flushBlock()
        try handle.write(contentsOf: Data([0, 0x3b]))
        try handle.synchronize()
        try handle.close()
        return y
    }

    private func emit(_ code: Int, bits: Int) throws {
        bitBuf |= UInt32(code) << bitCount
        bitCount += bits
        while bitCount >= 8 {
            block.append(UInt8(truncatingIfNeeded: bitBuf))
            bitBuf >>= 8
            bitCount -= 8
            if block.count == 255 {
                try flushBlock()
            }
        }
    }

    private func flushBits() throws {
        if bitCount > 0 {
            block.append(UInt8(truncatingIfNeeded: bitBuf))
            bitBuf = 0
            bitCount = 0
        }
        if !block.isEmpty {
            try flushBlock()
        }
    }

    private func flushBlock() throws {
        var packet = Data([UInt8(block.count)])
        packet.append(block)
        try handle.write(contentsOf: packet)
        block.removeAll(keepingCapacity: true)
    }
}

final class PDFRowWriter: PixelRowWriter {
    private let jpeg: JPEGRowWriter
    private let jpegURL: URL
    private let output: URL
    private let width: Int
    private let height: Int
    private let samplesPerPixel: Int
    private let append: Bool

    init(path: String, width: Int, height: Int, samplesPerPixel: Int, dpi: Int, append: Bool = false) throws {
        let jpegURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".scanjet-\(UUID().uuidString).jpg")
        self.jpegURL = jpegURL
        self.output = URL(fileURLWithPath: path)
        self.width = width
        self.height = height
        self.samplesPerPixel = samplesPerPixel
        self.append = append
        self.jpeg = try JPEGRowWriter(path: jpegURL.path, width: width, height: height,
                                      samplesPerPixel: samplesPerPixel, dpi: dpi)
    }

    func write(row: [UInt8]) throws { try jpeg.write(row: row) }
    func write(row16: [UInt16]) throws { try jpeg.write(row16: row16) }

    func finish() throws -> Int {
        _ = try jpeg.finish()
        try PDFPageFile.write(jpeg: jpegURL, to: output, width: width, height: height,
                              gray: samplesPerPixel == 1, append: append)
        try? FileManager.default.removeItem(at: jpegURL)
        return height
    }
}

enum PDFPageFile {
    static func write(jpeg: URL, to output: URL, width: Int, height: Int,
                      gray: Bool, append: Bool) throws {
        if append, FileManager.default.fileExists(atPath: output.path) {
            let page = output.deletingLastPathComponent()
                .appendingPathComponent(".scanjet-page-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: page) }
            try writeSingle(jpeg, to: page, width: width, height: height, gray: gray)
            guard let base = PDFDocument(url: output), let extra = PDFDocument(url: page),
                  let added = extra.page(at: 0) else {
                throw ScanjetError.io("PDF append failed")
            }
            base.insert(added, at: base.pageCount)
            guard base.write(to: output) else {
                throw ScanjetError.io("PDF append failed")
            }
            return
        }
        try writeSingle(jpeg, to: output, width: width, height: height, gray: gray)
    }

    private static func writeSingle(_ jpeg: URL, to url: URL, width: Int, height: Int, gray: Bool) throws {
        let jpegData = try Data(contentsOf: jpeg, options: [.mappedIfSafe])
        let cs = gray ? "/DeviceGray" : "/DeviceRGB"
        let content = "q \(width) 0 0 \(height) 0 0 cm /Im0 Do Q\n"
        var pdf = "%PDF-1.4\n% Scanjet\n"
        func obj(_ n: Int, _ body: String) {
            pdf += "\(n) 0 obj\n\(body)\nendobj\n"
        }
        obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>")
        obj(4, "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
        pdf += "5 0 obj\n<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace \(cs) /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>\nstream\n"
        var data = Data(pdf.utf8)
        data.append(jpegData)
        data.append(contentsOf: "\nendstream\nendobj\n".utf8)
        let startxref = data.count
        data.append(contentsOf: "xref\n0 6\n0000000000 65535 f \ntrailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n".utf8)
        try data.write(to: url)
    }
}

final class ImageIORowWriter: PixelRowWriter {
    private let handle: FileHandle
    private let rawURL: URL
    private let output: URL
    private let format: OutputFormat
    private let width: Int
    private let height: Int
    private let samplesPerPixel: Int
    private let dpi: Int
    private var y = 0

    init(path: String, format: OutputFormat, width: Int, height: Int,
         samplesPerPixel: Int, dpi: Int) throws {
        let rawURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".scanjet-\(UUID().uuidString).rgb")
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: rawURL.path) else {
            throw ScanjetError.io("cannot create \(rawURL.path)")
        }
        handle.disableSystemCache()
        self.handle = handle
        self.rawURL = rawURL
        self.output = URL(fileURLWithPath: path)
        self.format = format
        self.width = width
        self.height = height
        self.samplesPerPixel = samplesPerPixel
        self.dpi = dpi
    }

    func write(row: [UInt8]) throws {
        try handle.write(contentsOf: Data(row))
        y += 1
    }

    func write(row16: [UInt16]) throws {
        var row = [UInt8](repeating: 0, count: row16.count)
        for i in 0..<row16.count { row[i] = UInt8(row16[i] >> 8) }
        try write(row: row)
    }

    func finish() throws -> Int {
        try handle.synchronize()
        try handle.close()
        defer { try? FileManager.default.removeItem(at: rawURL) }

        let cs: CGColorSpace = samplesPerPixel == 1
            ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bpp = samplesPerPixel * 8
        let bpr = width * samplesPerPixel
        guard let provider = CGDataProvider(url: rawURL as CFURL) else {
            throw ScanjetError.io("cannot map scan for \(format.rawValue)")
        }
        guard let image = CGImage(width: width, height: y, bitsPerComponent: 8, bitsPerPixel: bpp,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ScanjetError.io("cannot wrap scan for \(format.rawValue)")
        }
        let type = try format.imageIOType()
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ScanjetError.io("cannot write \(format.rawValue) to \(output.path)")
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScanjetError.io("failed to write \(output.path)")
        }
        return y
    }
}
