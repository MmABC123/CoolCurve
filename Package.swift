// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fanline",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .executable(name: "mm-smc-helper", targets: ["mm-smc-helper"]),
        .executable(name: "Fanline", targets: ["Fanline"])
    ],
    targets: [
        .target(
            name: "CSMCKit",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "SMCKit",
            dependencies: ["CSMCKit"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "mm-smc-helper",
            dependencies: ["SMCKit"]
        ),
        .executableTarget(
            name: "Fanline",
            dependencies: ["SMCKit", "CSMCKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
