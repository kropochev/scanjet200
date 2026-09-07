import Foundation
import CScanjetUSB

/// USB session lifecycle shared by the CLI and GUI.
public enum DeviceSession {
    public static func isScannerAvailable() -> Bool {
        guard scanjet_usb_init() == 0 else { return false }
        defer { scanjet_usb_exit() }
        var info = ScanjetDeviceInfo()
        return scanjet_usb_find(&info) == 0
    }

    public static func withOpenDevice(_ body: (GenesysDevice) throws -> Void) throws {
        let rc = scanjet_usb_init()
        guard rc == 0 else {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
        defer { scanjet_usb_exit() }

        let openRc = scanjet_usb_open()
        guard openRc == 0 else {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
        let device = GenesysDevice()
        defer {
            if let status = try? device.readRegister(0x101), (status & 0x01) != 0 {
                ScanLogger.log(.homing, 0, "waiting for carriage home...")
                _ = ScanEngine.waitForHome(device, timeout: 60)
            }
            if let capture = try? device.readRegister(0x100), capture == 0x33 {
                _ = try? device.writeRegister(0x0f, 0x00)
                if let r01 = try? device.readRegister(0x01) {
                    _ = try? device.writeRegister(0x01, r01 & ~0x01)
                }
            }
        }
        try body(device)
    }
}
