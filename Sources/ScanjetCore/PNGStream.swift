import Foundation
import CScanjetUSB

final class PNGRowWriter: PixelRowWriter {
    private var writer: OpaquePointer?
    private let bitsPerSample: Int
    private var packed = [UInt8]()

    init(path: String, width: Int, height: Int, samplesPerPixel: Int, bitsPerSample: Int, dpi: Int) throws {
        precondition(bitsPerSample == 8 || bitsPerSample == 16)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        let ppm = UInt32((Double(max(dpi, 1)) / 0.0254).rounded())
        guard let opened = scanjet_png_open(path, UInt32(width), UInt32(height),
                                            Int32(samplesPerPixel), Int32(bitsPerSample), ppm) else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
        self.writer = opened
        self.bitsPerSample = bitsPerSample
    }

    deinit {
        if let writer {
            _ = scanjet_png_close(writer)
        }
    }

    func write(row: [UInt8]) throws {
        try writeBytes(row)
    }

    func writePackedLE16(_ bytes: [UInt8]) throws {
        try writeBytes(bytes)
    }

    func write(row16: [UInt16]) throws {
        packed.removeAll(keepingCapacity: true)
        packed.reserveCapacity(row16.count * 2)
        for value in row16 {
            let le = value.littleEndian
            packed.append(UInt8(truncatingIfNeeded: le))
            packed.append(UInt8(truncatingIfNeeded: le >> 8))
        }
        try writeBytes(packed)
    }

    func finish() throws -> Int {
        guard let current = writer else { return 0 }
        writer = nil
        guard scanjet_png_close(current) == 0 else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
        return 0
    }

    private func writeBytes(_ row: [UInt8]) throws {
        guard let writer else {
            throw ScanjetError.io("PNG writer already closed")
        }
        let rc = row.withUnsafeBytes { ptr in
            scanjet_png_write_row(writer, ptr.bindMemory(to: UInt8.self).baseAddress, ptr.count)
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
    }
}

enum PNGStream {
    static func write(fromTIFF tiff: URL, to output: URL, dpi: Int) throws {
        guard let info = TIFFPreview.info(of: tiff) else {
            throw ScanjetError.io("cannot stream PNG: TIFF is not an uncompressed strip")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let ppm = UInt32((Double(max(dpi, 1)) / 0.0254).rounded())
        guard let writer = scanjet_png_open(output.path, UInt32(info.width), UInt32(info.height),
                                            Int32(info.samplesPerPixel), Int32(info.bitsPerSample), ppm) else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
        var closed = false
        defer {
            if !closed {
                _ = scanjet_png_close(writer)
            }
        }

        let cb: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { fraction, _ in
            ScanLogger.log(.exporting, fraction, "")
        }
        let rc = tiff.path.withCString { path in
            scanjet_png_write_strip(writer, path, UInt64(info.stripOffset),
                                    UInt32(info.height), UInt32(info.bytesPerRow), cb, nil)
        }
        guard rc == 0 else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
        closed = true
        guard scanjet_png_close(writer) == 0 else {
            throw ScanjetError.io(String(cString: scanjet_png_last_error()))
        }
    }
}
