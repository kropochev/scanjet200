import Foundation
import CScanjetUSB

public enum GenesysUSB {
    public static let requestRegister: UInt8 = 0x0c
    public static let requestBuffer: UInt8 = 0x04
    public static let valueBuffer: UInt16 = 0x82
    public static let valueSetRegister: UInt16 = 0x83
    public static let valueReadRegister: UInt16 = 0x84
    public static let valueWriteRegister: UInt16 = 0x85
    public static let valueInit: UInt16 = 0x87
    public static let valueBufEndAccess: UInt16 = 0x8c
    public static let valueGetRegister: UInt16 = 0x8e
    public static let timeoutMS: Int32 = 5000

    public static let bulkIn: UInt8 = 0x81
    public static let bulkOut: UInt8 = 0x02
}

public final class GenesysDevice: @unchecked Sendable {
    @discardableResult
    public func controlIn(request: UInt8, value: UInt16, index: UInt16, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max(length, 1))
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            scanjet_usb_control_in(request, value, index, ptr.baseAddress, UInt16(length), GenesysUSB.timeoutMS)
        }
        guard rc >= 0 else {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
        return Array(buffer.prefix(Int(rc)))
    }

    public func controlOut(request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws {
        let rc = data.withUnsafeBufferPointer { ptr in
            scanjet_usb_control_out(request, value, index, ptr.baseAddress, UInt16(data.count), GenesysUSB.timeoutMS)
        }
        guard rc >= 0 else {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
    }

    /// GL847/GL848 register read: vendor IN, request 0x04, value 0x8e, index 0x22+(addr<<8), 2 bytes, second must be 0x55.
    public func readRegister(_ address: UInt16) throws -> UInt8 {
        var usbValue = GenesysUSB.valueGetRegister
        if address > 0xff {
            usbValue |= 0x100
        }
        let index = UInt16(0x22) + (address << 8)
        let data = try controlIn(request: GenesysUSB.requestBuffer, value: usbValue, index: index, length: 2)
        guard data.count == 2 else {
            throw ScanjetError.protocolMismatch("short reply reading register 0x\(hex(address))")
        }
        guard data[1] == 0x55 else {
            throw ScanjetError.protocolMismatch(
                "register 0x\(hex(address)): USB status 0x\(hex(data[1])), expected 0x55"
            )
        }
        return data[0]
    }

    public func writeRegister(_ address: UInt16, _ value: UInt8) throws {
        var usbValue = GenesysUSB.valueSetRegister
        if address > 0xff {
            usbValue |= 0x100
        }
        try controlOut(
            request: GenesysUSB.requestBuffer,
            value: usbValue,
            index: 0,
            data: [UInt8(address & 0xff), value]
        )
    }

    public func write0x8c(index: UInt8, value: UInt8) throws {
        try write0x8c(index: index, data: [value])
    }

    public func write0x8c(index: UInt8, data: [UInt8]) throws {
        try controlOut(
            request: GenesysUSB.requestRegister,
            value: GenesysUSB.valueBufEndAccess,
            index: UInt16(index),
            data: data
        )
    }

    /// URB from SANE asic_init: control 0xc0 0x0c 0x8e 0x00 len 1
    public func probeUSBSpeedByte() throws -> UInt8 {
        let data = try controlIn(
            request: GenesysUSB.requestRegister,
            value: GenesysUSB.valueGetRegister,
            index: 0,
            length: 1
        )
        guard let value = data.first else {
            throw ScanjetError.protocolMismatch("no reply to USB speed probe")
        }
        return value
    }

    public func bulkRead(length: Int, timeoutMS: Int32 = 8000) throws -> [UInt8] {
        let result = try bulkReadAllowingTimeout(length: length, timeoutMS: timeoutMS)
        if result.timedOut {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
        return result.data
    }

    /// Like `bulkRead`, but a USB timeout returns the bytes so far instead of throwing.
    public func bulkReadAllowingTimeout(length: Int, timeoutMS: Int32) throws -> (data: [UInt8], timedOut: Bool) {
        var buffer = [UInt8](repeating: 0, count: length)
        var transferred: Int32 = 0
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            scanjet_usb_bulk_in(GenesysUSB.bulkIn, ptr.baseAddress, Int32(length), &transferred, timeoutMS)
        }
        if rc != 0 && scanjet_usb_is_timeout(rc) == 0 {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
        return (Array(buffer.prefix(Int(max(0, transferred)))), rc != 0)
    }

    public func bulkWrite(_ data: [UInt8], timeoutMS: Int32 = 4000) throws {
        var transferred: Int32 = 0
        let rc = data.withUnsafeBufferPointer { ptr in
            scanjet_usb_bulk_out(GenesysUSB.bulkOut, ptr.baseAddress, Int32(data.count), &transferred, timeoutMS)
        }
        guard rc == 0 else {
            throw ScanjetError.usb(String(cString: scanjet_usb_last_error()))
        }
    }

    public func writeAHB(address: UInt32, data: [UInt8]) throws {
        let header: [UInt8] = [
            UInt8(address & 0xff),
            UInt8((address >> 8) & 0xff),
            UInt8((address >> 16) & 0xff),
            UInt8((address >> 24) & 0xff),
            UInt8(UInt32(data.count) & 0xff),
            UInt8((UInt32(data.count) >> 8) & 0xff),
            UInt8((UInt32(data.count) >> 16) & 0xff),
            UInt8((UInt32(data.count) >> 24) & 0xff)
        ]
        try controlOut(request: GenesysUSB.requestBuffer, value: GenesysUSB.valueBuffer, index: 0x01, data: header)
        try bulkWrite(data)
    }

    public func sendSlopeTable(number: Int, bytes: [UInt8]) throws {
        // HP writes only DRAM 0x10000000 + 0x4000*n, no 0x4000 mirror.
        let address: UInt32 = 0x1000_0000 + 0x4000 * UInt32(number)
        try writeAHB(address: address, data: bytes)
    }

    public func beginBulkRead(size: Int) throws {
        let header: [UInt8] = [
            0x00, 0x00, 0x00, 0x10,
            UInt8(UInt32(size) & 0xff),
            UInt8((UInt32(size) >> 8) & 0xff),
            UInt8((UInt32(size) >> 16) & 0xff),
            UInt8((UInt32(size) >> 24) & 0xff)
        ]
        try controlOut(request: GenesysUSB.requestBuffer, value: GenesysUSB.valueBuffer, index: 0, data: header)
    }
}
