// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DICOMSwift",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "DicomCore", targets: ["DicomCore"]),
        .executable(name: "dicomtool", targets: ["dicomtool"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/Raster-Lab/J2KSwift.git", exact: "11.0.2"),
        .package(url: "https://github.com/Raster-Lab/JLSwift.git", exact: "0.9.0"),
        .package(url: "https://github.com/Raster-Lab/JXLSwift.git", exact: "1.4.0")
    ],
    targets: [
        .target(
            name: "DicomCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "J2KCore", package: "J2KSwift"),
                .product(name: "J2KCodec", package: "J2KSwift"),
                .product(name: "JPEGLS", package: "JLSwift"),
                .product(name: "JXLSwift", package: "JXLSwift")
            ],
            path: "Sources/DicomCore",
            exclude: [
                "JPEGLossless_ALGORITHM.md"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Metal", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "dicomtool",
            dependencies: [
                "DicomCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/dicomtool"
        ),
        .testTarget(
            name: "DicomTestSupport",
            dependencies: ["DicomCore"],
            // Shared test support target that owns MockDicomDecoder for all test targets.
            path: "Tests/DicomTestSupport"
        ),
        .testTarget(
            name: "DicomCoreTests",
            dependencies: [
                "DicomCore",
                "DicomTestSupport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "J2KCore", package: "J2KSwift"),
                .product(name: "J2KCodec", package: "J2KSwift"),
                .product(name: "JPEGLS", package: "JLSwift"),
                .product(name: "JXLSwift", package: "JXLSwift")
            ],
            path: "Tests/DicomCoreTests",
            exclude: [
                "Fixtures"
            ],
            resources: [
                .process("PerformanceBenchmarks/Baselines"),
                .process("Resources")
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "dicomtoolTests",
            dependencies: [
                "dicomtool",
                "DicomCore",
                "DicomTestSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Tests/dicomtoolTests"
        ),
        .testTarget(
            name: "dicomtoolIntegrationTests",
            dependencies: [
                "dicomtool",
                "DicomCore",
                "DicomTestSupport"
            ],
            path: "Tests/dicomtoolIntegrationTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
