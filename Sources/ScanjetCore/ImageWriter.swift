import Foundation

protocol PixelRowWriter: AnyObject {
    func write(row: [UInt8]) throws
    func write(row16: [UInt16]) throws
    func writePackedLE16(_ bytes: [UInt8]) throws
    @discardableResult
    func finish() throws -> Int
}

extension PixelRowWriter {
    func writePackedLE16(_ bytes: [UInt8]) throws {
        var row16 = [UInt16](repeating: 0, count: bytes.count / 2)
        for i in 0..<row16.count {
            row16[i] = UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8
        }
        try write(row16: row16)
    }
}

/// Streaming TIFF writer for large scans. Supports 8-bit (Millions) and 16-bit (Billions).
final class TIFFWriter: PixelRowWriter {
    private let handle: FileHandle
    private let url: URL
    private let width: Int
    private let samplesPerPixel: Int
    private let dpi: Int
    private let bitsPerSample: Int
    private var rows = 0
    private var pending = Data()

    init(path: String, width: Int, samplesPerPixel: Int, dpi: Int, bitsPerSample: Int = 8) throws {
        precondition(bitsPerSample == 8 || bitsPerSample == 16)
        self.url = URL(fileURLWithPath: path)
        self.width = width
        self.samplesPerPixel = samplesPerPixel
        self.dpi = dpi
        self.bitsPerSample = bitsPerSample

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw ScanjetError.io("cannot open for writing: \(url.path)")
        }
        handle.disableSystemCache()
        self.handle = handle

        var header = Data([0x49, 0x49, 42, 0])
        header.append(contentsOf: [0, 0, 0, 0])
        try handle.write(contentsOf: header)
    }

    func write(row: [UInt8]) throws {
        precondition(bitsPerSample == 8)
        pending.append(contentsOf: row)
        rows += 1
        try flushIfNeeded()
    }

    func write(row16: [UInt16]) throws {
        precondition(bitsPerSample == 16)
        pending.reserveCapacity(pending.count + row16.count * 2)
        for value in row16 {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { pending.append(contentsOf: $0) }
        }
        rows += 1
        try flushIfNeeded()
    }

    func writePackedLE16(_ bytes: [UInt8]) throws {
        precondition(bitsPerSample == 16)
        pending.append(contentsOf: bytes)
        rows += 1
        try flushIfNeeded()
    }

    private func flushIfNeeded() throws {
        if pending.count >= 4 << 20 {
            try handle.write(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    @discardableResult
    func finish() throws -> Int {
        if !pending.isEmpty {
            try handle.write(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }
        let bytesPerPixel = samplesPerPixel * (bitsPerSample / 8)
        let stripBytes = UInt32(width * bytesPerPixel * rows)
        let ifdOffset = UInt32(8 + Int(stripBytes))
        try Self.writeIFD(handle: handle, width: width, height: rows, samplesPerPixel: samplesPerPixel,
                          bitsPerSample: bitsPerSample, dpi: dpi, stripOffset: 8, stripBytes: stripBytes,
                          ifdOffset: ifdOffset)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: ifdOffset.littleEndian) { Data($0) })
        try handle.synchronize()
        try handle.close()
        return rows
    }

    static func writeIFD(to url: URL, width: Int, height: Int, samplesPerPixel: Int,
                         bitsPerSample: Int, dpi: Int, stripBytes: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let ifdOffset = UInt32(8 + stripBytes)
        try handle.seek(toOffset: UInt64(ifdOffset))
        try writeIFD(handle: handle, width: width, height: height, samplesPerPixel: samplesPerPixel,
                     bitsPerSample: bitsPerSample, dpi: dpi, stripOffset: 8, stripBytes: UInt32(stripBytes),
                     ifdOffset: ifdOffset)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: ifdOffset.littleEndian) { Data($0) })
        try handle.synchronize()
    }

    static func writeIFD(handle: FileHandle, width: Int, height: Int, samplesPerPixel: Int,
                         bitsPerSample: Int, dpi: Int, stripOffset: UInt32, stripBytes: UInt32,
                         ifdOffset: UInt32) throws {
        let entryCount: UInt16 = 12
        let ifdSize = 2 + Int(entryCount) * 12 + 4
        var bitsPerSampleData = Data()
        let bitsTagValue: UInt32
        if samplesPerPixel == 1 {
            bitsTagValue = UInt32(bitsPerSample)
        } else {
            bitsTagValue = ifdOffset + UInt32(ifdSize)
            for _ in 0..<samplesPerPixel {
                var sample = UInt16(bitsPerSample).littleEndian
                bitsPerSampleData.append(Data(bytes: &sample, count: 2))
            }
        }
        let rationalsOffset = ifdOffset + UInt32(ifdSize + bitsPerSampleData.count)
        var ifd = Data()
        func u16(_ v: UInt16, into data: inout Data) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32, into data: inout Data) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        let bitsCount = UInt32(samplesPerPixel > 1 ? samplesPerPixel : 1)
        let entries: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 3, 1, UInt32(width)),
            (257, 3, 1, UInt32(height)),
            (258, 3, bitsCount, bitsTagValue),
            (259, 3, 1, 1),
            (262, 3, 1, samplesPerPixel == 1 ? 1 : 2),
            (273, 4, 1, stripOffset),
            (277, 3, 1, UInt32(samplesPerPixel)),
            (278, 4, 1, UInt32(height)),
            (279, 4, 1, stripBytes),
            (282, 5, 1, rationalsOffset),
            (283, 5, 1, rationalsOffset + 8),
            (296, 3, 1, 2)
        ]
        u16(entryCount, into: &ifd)
        for (tag, type, count, value) in entries {
            u16(tag, into: &ifd); u16(type, into: &ifd); u32(count, into: &ifd); u32(value, into: &ifd)
        }
        u32(0, into: &ifd)
        var rationals = Data()
        u32(UInt32(dpi), into: &rationals); u32(1, into: &rationals)
        u32(UInt32(dpi), into: &rationals); u32(1, into: &rationals)
        try handle.write(contentsOf: ifd)
        if !bitsPerSampleData.isEmpty {
            try handle.write(contentsOf: bitsPerSampleData)
        }
        try handle.write(contentsOf: rationals)
    }
}
