import Foundation
import ScanjetCore

enum Command: String {
    case list
    case scan
    case calibrate
    case version
    case help
}

@main
struct ScanjetCLI {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        ScanLogger.handler = { progress in
            if !progress.message.isEmpty {
                if progress.phase == .capturing && progress.fraction > 0 && progress.fraction < 1 {
                    fputs("  \(progress.message)\n", stderr)
                } else {
                    print("  \(progress.message)")
                }
            }
        }

        let args = Array(CommandLine.arguments.dropFirst())

        do {
            let (command, rest) = try parseInvocation(args)
            try run(command, args: rest)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func parseInvocation(_ args: [String]) throws -> (Command, [String]) {
        guard let first = args.first else { return (.help, []) }
        switch first {
        case "--version", "-V", "version":
            return (.version, [])
        case "--help", "-h", "help":
            return (.help, [])
        default:
            guard let command = Command(rawValue: first) else {
                throw ScanjetError.usage("Unknown command: \(first)\n\n\(usageText)")
            }
            return (command, Array(args.dropFirst()))
        }
    }

    static let usageText = """
scanjet — CLI for HP Scanjet 200 (macOS, no official drivers)

Commands:
  list                 Find the scanner on USB
  scan [options]       Scan to a file
  calibrate [options]  Capture a white A4 shading reference
  version              Print the version (also --version / -V)
  help                 Show this help (also --help / -h)

scan and calibrate options:
  -o, --output PATH    File or folder (default scan.tiff in the current directory)
  --name NAME          File name without extension (default scan)
  --dpi N              Resolution: 75 100 150 200 300 600 1200 2400 (default 300)
  --kind KIND          colour | gray | text | photo (default colour)
  --mode MODE          color | gray (same as --kind colour | gray)
  --photo-subject SRC  colour-print | bw-print | colour-negative | bw-negative
  --photo-layout LAY   prints | strip
  --photo-format FMT   auto | 35mm | half-frame | 6x4.5 | 6x6 | 6x9 | 16mm | 110 | 127
  --colours DEPTH      millions (8-bit) | billions (16-bit, TIFF and PNG only)
  --size SIZE          a4 | letter (default a4)
  --orientation DEG    0 | 90 | 180 | 270 (default 0)
  --format FMT         jpeg | heic | tiff | png | jp2 | gif | bmp | pdf (default tiff)
  --combine            Append to an existing PDF or multi-page TIFF of the same name
  --height MM          Height from the top of the glass, mm (overrides --size height)
  --gamma N            Tone curve: 2.2 brighter, 1 linear (default sRGB)
  --shading PATH       Calibration file (default in Application Support)
  --no-shading         Skip calibration
  --raw                Keep the raw 16-bit frame next to the result
  --feed N             FEEDL steps from park (default from the HP log)

Use Custom Size and Image Correction are GUI-only.

Full page: 300 dpi ≈ 13 s, 600 ≈ 47 s, 1200 ≈ 3 min, 2400 ≈ 12 min.
"""

    static func run(_ command: Command, args: [String]) throws {
        switch command {
        case .help:
            print(usageText)
        case .version:
            print(AppVersion.cliLine)
        case .list:
            try commandList()
        case .scan:
            let request = try ScanRequest.parseCLI(args)
            try commandScan(request: request)
        case .calibrate:
            let options = try ScanOptions.parse(args)
            try DeviceSession.withOpenDevice { device in
                try commandCalibrate(device, options: options)
            }
        }
    }
}
