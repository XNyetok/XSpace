// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "XSpace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XSpace", targets: ["XSpace"])
    ],
    targets: [
        .executableTarget(
            name: "XSpace",
            path: "Sources/XSpace",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        )
    ]
)
