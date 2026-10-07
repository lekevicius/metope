// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if arch(arm64)
let usbDirectory = root + "/Vendor/libusb/arm64"
#else
let usbDirectory = root + "/Vendor/libusb/x86_64"
#endif
let package = Package(
    name: "Metope", platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Metope", targets: ["Metope"]),
        .library(name: "MetopeEngine", targets: ["MetopeEngine"]),
        .executable(name: "MetopeEngineHost", targets: ["MetopeEngineHost"])
    ],
    targets: [
        .target(name: "MetopeCore"),
        .systemLibrary(name: "CLibUSB"),
        .target(name: "MetopeEngine", dependencies: ["MetopeCore", "CLibUSB"], linkerSettings: [
            .unsafeFlags(["-L" + usbDirectory, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", usbDirectory])
        ]),
        .executableTarget(name: "MetopeEngineHost", dependencies: ["MetopeEngine", "MetopeCore"]),
        .executableTarget(name: "Metope", dependencies: ["MetopeCore"], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("QuickLookUI"), .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "26.0", "-Xlinker", "27.0"])]),
        .testTarget(name: "MetopeCoreTests", dependencies: ["MetopeCore"]),
        .testTarget(name: "MetopeEngineTests", dependencies: ["MetopeEngine", "MetopeCore"])
    ], swiftLanguageModes: [.v5]
)
