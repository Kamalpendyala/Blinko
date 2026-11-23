// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Blinko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Blinko", targets: ["Blinko"]),
        .library(name: "BlinkoCore", targets: ["BlinkoCore"]),
    ],
    dependencies: [
        // Test-only. Swift Testing normally ships inside Xcode's toolchain;
        // this machine only has the Command Line Tools, so it is built from source.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.0.0"),
    ],
    targets: [
        .target(name: "BlinkoCore"),
        .executableTarget(name: "Blinko", dependencies: ["BlinkoCore"]),
        .testTarget(
            name: "BlinkoCoreTests",
            dependencies: [
                "BlinkoCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: [
                // Command Line Tools keeps lib_TestingInterop here. Xcode's
                // toolchain already has this directory on its search path.
                .unsafeFlags(["-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib"]),
            ]
        ),
    ]
)
