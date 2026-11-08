// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Knock",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Sparkle 2 auto-updates (KNOCK-21). Sparkle's SwiftPM package is a
        // binary target that fetches the prebuilt Sparkle.xcframework; the
        // framework is embedded into Knock.app by scripts/bundle-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        // The single geometry source for the "door knocker" mark (contract:
        // HAIL-23): plain Core Graphics, so both the app (menu bar, in-app
        // lockup) and the standalone icon renderer below can draw from it.
        .target(
            name: "KnockMark",
            path: "Sources/KnockMark"
        ),
        .executableTarget(
            name: "Knock",
            dependencies: ["Sparkle", "KnockMark"],
            path: "Sources/Knock",
            resources: [.copy("Resources/Fonts"), .copy("Resources/Mermaid")]
        ),
        // Renders the app-icon PNGs from KnockMark; see scripts/make-app-icon.sh.
        .executableTarget(
            name: "make-app-icon",
            dependencies: ["KnockMark"],
            path: "Sources/MakeAppIcon"
        ),
        .testTarget(
            name: "KnockTests",
            dependencies: ["Knock", "KnockMark"],
            path: "Tests/KnockTests"
        )
    ]
)
