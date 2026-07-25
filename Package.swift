// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EvoControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EvoControl", targets: ["EvoControl"])
    ],
    targets: [
        .executableTarget(
            name: "EvoControl",
            dependencies: ["CEvoAudioTap", "CEvoUsb"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .unsafeFlags([
                    "-L/opt/homebrew/lib", "-lusb-1.0",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .target(
            name: "CEvoUsb",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0"])
            ]
        ),
        .target(
            name: "CEvoAudioTap",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "EvoControlTests"
        )
    ]
)
