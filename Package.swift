// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "scanjet200",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "scanjet", targets: ["scanjet"]),
        .executable(name: "Scanjet200", targets: ["Scanjet200"])
    ],
    targets: [
        .target(
            name: "Clibusb",
            path: ".",
            sources: [
                "Vendor/libusb/libusb/core.c",
                "Vendor/libusb/libusb/descriptor.c",
                "Vendor/libusb/libusb/hotplug.c",
                "Vendor/libusb/libusb/io.c",
                "Vendor/libusb/libusb/strerror.c",
                "Vendor/libusb/libusb/sync.c",
                "Vendor/libusb/libusb/os/darwin_usb.c",
                "Vendor/libusb/libusb/os/events_posix.c",
                "Vendor/libusb/libusb/os/threads_posix.c"
            ],
            publicHeadersPath: "Sources/Clibusb/include",
            cSettings: [
                .headerSearchPath("Sources/Clibusb/include"),
                .headerSearchPath("Sources/Clibusb/private"),
                .headerSearchPath("Vendor/libusb/libusb"),
                .headerSearchPath("Vendor/libusb/libusb/os"),
                .headerSearchPath("Vendor/libusb/Xcode")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("objc")
            ]
        ),
        .target(
            name: "CScanjetUSB",
            dependencies: ["Clibusb"],
            path: "Sources/CScanjetUSB",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "ScanjetCore",
            dependencies: ["CScanjetUSB"],
            path: "Sources/ScanjetCore",
            resources: [
                .copy("hp_300.txt"), .copy("hp_300.bin"),
                .copy("hp_600.txt"), .copy("hp_600.bin"),
                .copy("hp_1200.txt"), .copy("hp_1200.bin"),
                .copy("hp_2400.txt"), .copy("hp_2400.bin")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit")
            ]
        ),
        .executableTarget(
            name: "scanjet",
            dependencies: ["ScanjetCore"],
            path: "Sources/scanjet"
        ),
        .executableTarget(
            name: "Scanjet200",
            dependencies: ["ScanjetCore"],
            path: "Sources/Scanjet200",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "ScanjetTests",
            dependencies: ["ScanjetCore"],
            path: "Tests/ScanjetTests",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
