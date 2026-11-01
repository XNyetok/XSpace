// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "XSpace",
    platforms: [.macOS("26.0")],
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
        ),
        // Unit tests for logic that needs no web page, window or sandbox (`swift test`).
        // Everything else is covered by the self-tests built into the app (`XSpace --selftest`).
        .testTarget(
            name: "XSpaceTests",
            dependencies: ["XSpace"],
            path: "Tests/XSpaceTests"
        ),
    ]
)
