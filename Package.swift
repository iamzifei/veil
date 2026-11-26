// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Veil",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle: macOS auto-update framework. Ships as a binary XCFramework via SPM;
        // scripts/build.sh copies Sparkle.framework into the .app bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Veil",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Veil",
            // Lets the runtime find Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Unit tests for the measured models (grain, blur calibration, tint presets…).
        .testTarget(name: "VeilTests", dependencies: ["Veil"], path: "Tests/VeilTests")
    ]
)
