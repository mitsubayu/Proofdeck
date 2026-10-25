// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Proofdeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "proofdeck-mcp", path: "Sources/proofdeck-mcp"),
        .executableTarget(
            name: "Proofdeck",
            path: "Sources/Proofdeck",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        )
    ]
)
