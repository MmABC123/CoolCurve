// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CoolCurve",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .executable(name: "mm-smc-helper", targets: ["mm-smc-helper"]),
        .executable(name: "CoolCurve", targets: ["CoolCurve"])
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
            name: "CoolCurve",
            dependencies: ["SMCKit", "CSMCKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
