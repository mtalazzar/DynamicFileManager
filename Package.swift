// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DynamicFileConverter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DynamicFileConverter", targets: ["DynamicFileConverter"]),
        .executable(name: "dfc", targets: ["dfc"]),
        .library(name: "ConverterCore", targets: ["ConverterCore"]),
    ],
    targets: [
        .target(name: "ConverterCore"),
        .executableTarget(name: "dfc", dependencies: ["ConverterCore"]),
        .executableTarget(name: "DynamicFileConverter", dependencies: ["ConverterCore"]),
        .testTarget(name: "ConverterCoreTests", dependencies: ["ConverterCore"]),
    ]
)
