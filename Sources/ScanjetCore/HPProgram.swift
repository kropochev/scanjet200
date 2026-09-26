import Foundation

/// Init sequences captured from the Windows driver.
/// Replayed byte for byte: the ASIC reaches status 0x33 and starts writing the frame to DRAM.
enum HPProgram {
    enum Op {
        case controlOut(request: UInt8, value: UInt16, index: UInt16, offset: Int, length: Int)
        case controlIn(request: UInt8, value: UInt16, index: UInt16, length: Int)
        case bulkOut(offset: Int, length: Int)
        case bulkIn(length: Int)
    }

    struct Program {
        var ops: [Op]
        var blobs: [UInt8]
        /// Index of the 0x0F=0xFF write — after it the ASIC starts capturing.
        var startIndex: Int
        /// Index of the last LINCNT write before start.
        var lineCountIndex: Int
        /// Index of the last FEEDL write before start.
        var feedIndex: Int
    }

    private static func resource(_ name: String, _ ext: String) throws -> Data {
        if let url = Bundle.module.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let local = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).\(ext)")
        guard let data = try? Data(contentsOf: local) else {
            throw ScanjetError.io("missing resource \(name).\(ext)")
        }
        return data
    }

    static func load(_ mode: ScanMode) throws -> Program {
        let text = String(decoding: try resource(mode.resource, "txt"), as: UTF8.self)
        let blobs = [UInt8](try resource(mode.resource, "bin"))

        var ops: [Op] = []
        var startIndex = -1
        var lineCountIndex = -1
        var feedIndex = -1

        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard let kind = f.first else { continue }
            switch kind {
            case "CO":
                guard f.count >= 6, let req = UInt8(f[1]), let value = UInt16(f[2]),
                      let index = UInt16(f[3]), let off = Int(f[4]), let len = Int(f[5]) else { continue }
                if req == 0x04, value == 0x83, startIndex < 0 {
                    var i = off
                    while i + 1 < off + len {
                        if blobs[i] == 0x0f && blobs[i + 1] == 0xff && len == 2 {
                            startIndex = ops.count
                        }
                        if blobs[i] == 0x25 {
                            lineCountIndex = ops.count
                        }
                        if blobs[i] == 0x3d {
                            feedIndex = ops.count
                        }
                        i += 2
                    }
                }
                ops.append(.controlOut(request: req, value: value, index: index, offset: off, length: len))
            case "CI":
                guard f.count >= 5, let req = UInt8(f[1]), let value = UInt16(f[2]),
                      let index = UInt16(f[3]), let len = Int(f[4]) else { continue }
                ops.append(.controlIn(request: req, value: value, index: index, length: len))
            case "BO":
                guard f.count >= 3, let off = Int(f[1]), let len = Int(f[2]) else { continue }
                ops.append(.bulkOut(offset: off, length: len))
            case "BI":
                guard f.count >= 2, let len = Int(f[1]) else { continue }
                ops.append(.bulkIn(length: len))
            default:
                continue
            }
        }

        guard startIndex >= 0 else {
            throw ScanjetError.io("program \(mode.resource) has no 0x0F=0xFF write")
        }
        return Program(ops: ops, blobs: blobs, startIndex: startIndex,
                       lineCountIndex: lineCountIndex, feedIndex: feedIndex)
    }

    /// Run init up to capture start, patching frame height (LINCNT)
    /// and feed to the top of the frame (FEEDL).
    static func runInit(_ device: GenesysDevice, mode: ScanMode,
                        lineCount: UInt32, feedLines: UInt32, lampOff: Bool = false,
                        verbose: Bool = true) throws {
        let program = try load(mode)
        var patched = program.blobs

        func patch(_ index: Int, _ registers: [UInt8: UInt8]) {
            guard index >= 0, index < program.startIndex,
                  case .controlOut(_, _, _, let off, let len) = program.ops[index] else { return }
            var i = off
            while i + 1 < off + len {
                if let value = registers[patched[i]] {
                    patched[i + 1] = value
                }
                i += 2
            }
        }

        patch(program.lineCountIndex, [
            0x25: UInt8((lineCount >> 16) & 0xff),
            0x26: UInt8((lineCount >> 8) & 0xff),
            0x27: UInt8(lineCount & 0xff)
        ])
        patch(program.feedIndex, [
            0x3d: UInt8((feedLines >> 16) & 0xff),
            0x3e: UInt8((feedLines >> 8) & 0xff),
            0x3f: UInt8(feedLines & 0xff)
        ])

        // LAMPPWR (0x03 bit 4) off keeps the CIS LEDs dark for the whole pass:
        // the frame is then the per-column black level used by calibration.
        if lampOff {
            for index in 0..<program.startIndex {
                guard case .controlOut(let request, let value, _, let off, let len) = program.ops[index],
                      request == 0x04, value == 0x83 else { continue }
                var i = off
                while i + 1 < off + len {
                    if patched[i] == 0x03 { patched[i + 1] &= ~0x10 }
                    i += 2
                }
            }
        }

        if verbose {
            print("  init \(mode.resource): \(program.startIndex + 1) ops, "
                  + "LINCNT=\(lineCount) FEEDL=\(feedLines)" + (lampOff ? ", lamp off" : ""))
        }

        for op in program.ops[0...program.startIndex] {
            switch op {
            case .controlOut(let request, let value, let index, let offset, let length):
                guard request == 0x04 || request == 0x0c else { continue }
                let data = length > 0 ? Array(patched[offset..<(offset + length)]) : []
                try device.controlOut(request: request, value: value, index: index, data: data)
            case .controlIn(let request, let value, let index, let length):
                guard request == 0x04 || request == 0x0c else { continue }
                _ = try? device.controlIn(request: request, value: value, index: index, length: length)
            case .bulkOut(let offset, let length):
                try device.bulkWrite(Array(patched[offset..<(offset + length)]))
            case .bulkIn(let length):
                // The driver drains these AHB replies; leaving them in the pipe
                // would prepend them to the start of the frame.
                _ = try? device.bulkRead(length: length, timeoutMS: 2000)
            }
        }
    }
}
