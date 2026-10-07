// swift-tools-version:5.9
import PackageDescription
import Foundation

// libusb and keystone are linked statically (brew install libusb keystone) so the .app has no
// extra dylib dependencies beyond system frameworks.
let libusbPrefix = ProcessInfo.processInfo.environment["LIBUSB_PREFIX"] ?? "/opt/homebrew"
let keystonePrefix = ProcessInfo.processInfo.environment["KEYSTONE_PREFIX"] ?? "/opt/homebrew/opt/keystone"

let cIncludes: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(libusbPrefix)/include", "-Xcc", "-I\(keystonePrefix)/include"])]

let package = Package(
    name: "MDKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NetMDKit", targets: ["NetMDKit"]),
        .executable(name: "MDKit", targets: ["MDKit"]),
    ],
    targets: [
        .systemLibrary(name: "CLibUSB", path: "Sources/CLibUSB"),
        .systemLibrary(name: "CKeystone", path: "Sources/CKeystone"),
        .target(
            name: "NetMDKit",
            dependencies: ["CLibUSB", "CKeystone"],
            path: "Sources/NetMDKit",
            swiftSettings: cIncludes,
            linkerSettings: [
                .unsafeFlags([
                    "\(libusbPrefix)/lib/libusb-1.0.a",
                    "\(keystonePrefix)/lib/libkeystone.a",
                ]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "MDKit",
            dependencies: ["NetMDKit"],
            path: "Sources/MDKit",
            swiftSettings: cIncludes
        ),
        .testTarget(name: "NetMDKitTests", dependencies: ["NetMDKit"], path: "Tests/NetMDKitTests", swiftSettings: cIncludes),
    ]
)
