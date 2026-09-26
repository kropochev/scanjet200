import Foundation
import ScanjetCore
import CScanjetUSB

func commandList() throws {
    let rc = scanjet_usb_init()
    guard rc == 0 else {
        throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
    }
    defer { scanjet_usb_exit() }

    var info = ScanjetDeviceInfo()
    let found = scanjet_usb_find(&info)
    guard found == 0 else {
        throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
    }

    let manufacturer = String(cString: scanjet_usb_info_manufacturer(&info))
    let product = String(cString: scanjet_usb_info_product(&info))
    let serial = String(cString: scanjet_usb_info_serial(&info))
    print("scanner found")
    print("  \(manufacturer) \(product)")
    print("  USB \(hex(info.vendor_id, width: 4)):\(hex(info.product_id, width: 4))  bcdDevice=\(hex(info.bcd_device, width: 4))")
    print("  bus \(info.bus) addr \(info.address)  serial \(serial.isEmpty ? "—" : serial)")
}

func commandScan(request: ScanRequest) throws {
    let (mode, _) = try ScanMode.choose(outputDPI: request.dpi)
    let dest = request.outputURL(combineExisting: request.combine && request.format.supportsCombine)
    let region = request.effectiveRegion
    let kindLabel: String = {
        switch request.kind {
        case .colour: return "colour"
        case .blackAndWhite: return "gray"
        case .text: return "text"
        case .photo: return "photo"
        }
    }()
    let sizeLabel = request.paperSize == .a4 ? "A4" : "US Letter"
    let depthLabel = request.resolvedColorDepth == .billions ? "billions" : "millions"
    print("scanning → \(dest.path)")
    print("  \(request.dpi) dpi, \(kindLabel), \(depthLabel), \(sizeLabel) "
          + "\(Int(region.widthMM))×\(Int(region.heightMM)) mm, "
          + "\(request.orientation.rawValue)°, \(request.format.rawValue)"
          + (request.combine ? ", combine" : ""))

    if request.useShading {
        let url = request.shadingPath.map { URL(fileURLWithPath: $0) } ?? Shading.defaultURL(for: mode)
        if Shading.load(from: url) != nil {
            print("  calibration: \(url.path)")
        } else {
            print("  no calibration for \(mode.dpi) dpi — expect vertical bands, "
                  + "run `scanjet calibrate --dpi \(request.dpi)`")
        }
    }

    let image = try ScanService.scan(request: request)
    if image.outputURLs.count > 1 {
        print("done: \(image.outputURLs.count) files")
        for url in image.outputURLs {
            print("  \(url.path)")
        }
    } else {
        print("done: \(image.outputURL.path)  \(image.width)×\(image.height)")
    }
}

func commandCalibrate(_ device: GenesysDevice, options: ScanOptions) throws {
    var options = options
    let (mode, _) = try ScanMode.choose(outputDPI: options.dpi)
    print("calibrating on a clean white sheet, \(mode.dpi) dpi pass")
    print("  put a white A4 sheet over the whole glass and do not move it until the pass ends")

    options.useShading = false
    options.shading = nil
    options.heightMM = 297.0
    options.keepRaw = false
    options.outputPath = "scanjet-calibrate.tiff"

    let engine = ScanEngine(device: device)
    let image = try engine.scan(options: options)
    let shading = try Shading.measure(rawURL: image.rawURL, mode: mode)
    let url = options.shadingURL(for: mode)
    try shading.save(to: url)
    try options.finishRaw(image.rawURL)
    try? FileManager.default.removeItem(atPath: options.outputPath)

    let green = shading.reference[1]
    let spread = 100.0 * Double(green.max()! - green.min()!) / Double(shading.target)
    print(String(format: "  column spread was %.0f%%, white target %d", spread, shading.target))
    print("  saved: \(url.path)")
}
