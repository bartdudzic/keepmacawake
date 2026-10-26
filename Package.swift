// swift-tools-version: 5.9

import PackageDescription

// The Keep Mac Awake core: everything that runs as root or at install time.
let package = Package(
    name: "KeepMacAwakeCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KeepMacAwakeCore", targets: ["KeepMacAwakeCore"]),
        .library(name: "KeepMacAwakeControlProtocol", targets: ["KeepMacAwakeControlProtocol"]),
        .library(name: "KeepMacAwakeControlCore", targets: ["KeepMacAwakeControlCore"]),
        .library(name: "KeepMacAwakeServiceSupport", targets: ["KeepMacAwakeServiceSupport"]),
        .executable(name: "KeepMacAwakeHelper", targets: ["KeepMacAwakeHelper"]),
    ],
    targets: [
        .target(name: "KeepMacAwakeCore"),
        .target(name: "KeepMacAwakeControlProtocol"),
        .target(name: "KeepMacAwakeControlCore", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "KeepMacAwakeServiceSupport", dependencies: ["KeepMacAwakeControlCore", "KeepMacAwakeControlProtocol"]),
        .executableTarget(name: "KeepMacAwakeHelper", dependencies: ["KeepMacAwakeCore", "KeepMacAwakeControlCore", "KeepMacAwakeControlProtocol", "KeepMacAwakeServiceSupport"], linkerSettings: [.linkedFramework("SystemConfiguration")]),
        .testTarget(name: "KeepMacAwakeCoreTests", dependencies: ["KeepMacAwakeCore"]),
        .testTarget(name: "KeepMacAwakeControlCoreTests", dependencies: ["KeepMacAwakeControlCore"]),
        .testTarget(name: "KeepMacAwakeHelperTests", dependencies: ["KeepMacAwakeServiceSupport", "KeepMacAwakeControlProtocol"]),
    ]
)
