import Foundation
import Darwin
import CScanjetUSB

public enum ProcessMemory {
    /// Ask malloc to return unused arenas to the OS after a large scan.
    public static func releaseToOS() {
        scanjet_release_memory()
    }
}

extension FileHandle {
    /// Do not keep a multi-gigabyte raw/TIFF/PNG in the unified buffer cache.
    /// Without this, writing the 16-bit frame plus the decoded TIFF is charged
    /// to the process as ~7 GB of dirty file pages.
    func disableSystemCache() {
        _ = Darwin.fcntl(fileDescriptor, Darwin.F_NOCACHE, 1)
    }
}
